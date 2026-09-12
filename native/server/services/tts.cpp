// wip/P4/tts.cpp — see tts.h. Ports tts_service.py + tts_store.py + the
// /api/tts/* routes from api.py:1793-1968.
#include "tts.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "sa_core/atomic_io.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/state.h"
#include "env_store_ai.h"
#include "p4_util.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace sa {
namespace {

namespace http = sa_core::http;

constexpr int kTimeoutSynth = 300;
constexpr int kTimeoutVoices = 30;
constexpr int kTimeoutEncode = 120;

const char* kMinimaxBase = "https://api.minimax.io";
const char* kAliyunUrl = "https://dashscope.aliyuncs.com/api/v1/services/aigc/"
                         "multimodal-generation/generation";
const char* kAliyunTtsUrl =
    "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer";

// Truncate a UTF-8 string to at most `n` codepoints (Python s[:n]).
std::string trunc_chars(const std::string& s, size_t n) {
    size_t seen = 0;
    size_t i = 0;
    while (i < s.size() && seen < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
        if (i + len > s.size()) break;
        i += len;
        ++seen;
    }
    return s.substr(0, i);
}

json j_arr(const std::vector<std::array<const char*, 3>>& voices) {
    json out = json::array();
    for (const auto& v : voices) {
        out.push_back(json{{"id", v[0]}, {"name", v[1]}, {"gender", v[2]}});
    }
    return out;
}

// tts_service._MINIMAX_FALLBACK_VOICES.
const json& minimax_fallback_voices() {
    static const json k = j_arr({
        {"female-shaonv", "清甜少女", "女"}, {"female-yujie", "知性御姐", "女"},
        {"female-chengshu", "温柔成熟女声", "女"}, {"male-qn-qingse", "青年男声", "男"},
        {"male-jingpin", "精品男声", "男"}, {"presenter_female", "女播音主持", "女"},
        {"presenter_male", "男播音主持", "男"}, {"audiobook_female_1", "女声图书", "女"},
        {"audiobook_male_1", "男声图书", "男"},
    });
    return k;
}
const json& aliyun_qwen_voices() {
    static const json k = j_arr({
        {"Cherry", "Cherry（清新女声）", "女"}, {"Serena", "Serena（温柔女声）", "女"},
        {"Ethan", "Ethan（沉稳男声）", "男"}, {"June", "June（活泼女声）", "女"},
        {"Belle", "Belle（甜美女声）", "女"}, {"Hannah", "Hannah（飒爽女声）", "女"},
        {"Olivia", "Olivia（英文女声）", "女"}, {"Peyton", "Peyton（英文男声）", "男"},
        {"Quinn", "Quinn（英文男声）", "男"}, {"Kaitlin", "Kaitlin（英文女声）", "女"},
        {"Theo", "Theo（英文男声）", "男"}, {"Dennis", "Dennis（英文男声）", "男"},
        {"XiaoYun", "小云（标准女声）", "女"}, {"XiaoXia", "小夏（亲切女声）", "女"},
        {"XiaoGang", "小刚（阳刚男声）", "男"},
    });
    return k;
}
const json& aliyun_cosy_voices() {
    static const json k = j_arr({
        {"longxiaochun", "龙小淳（高分女声）", "女"}, {"longxiaoxia", "龙小夏（青春女声）", "女"},
        {"longxiaoyan", "龙小炎（阳光男声）", "男"}, {"longjielao", "龙哥（低沉男声）", "男"},
        {"longshushu", "龙叔叔（中年男声）", "男"}, {"longbobo", "龙伯伯（浑厚男声）", "男"},
    });
    return k;
}

}  // namespace

// ===========================================================================
// tts namespace
// ===========================================================================
namespace tts {

std::string extract_error(std::string_view raw) {
    std::string text = sa_core::str::trim(sa_core::decode_utf8_sig_replace(raw));
    if (text.empty()) return "empty response from upstream";
    auto obj = json::parse(text, nullptr, false);
    if (!obj.is_discarded() && obj.is_object()) {
        if (obj.contains("base_resp") && obj.at("base_resp").is_object()) {
            const json& resp = obj.at("base_resp");
            std::string msg;
            if (resp.contains("status_msg") && !resp.at("status_msg").is_null())
                msg = sa_core::py_str(resp.at("status_msg"));
            else if (resp.contains("status_message") && !resp.at("status_message").is_null())
                msg = sa_core::py_str(resp.at("status_message"));
            if (!msg.empty()) {
                std::string code = resp.contains("status_code") ? sa_core::py_str(resp.at("status_code")) : "";
                return "[" + code + "] " + msg;
            }
        }
        if (obj.contains("error")) {
            const json& err = obj.at("error");
            if (err.is_object()) {
                if (err.contains("message") && !err.at("message").is_null()) {
                    std::string code = err.contains("code") ? sa_core::py_str(err.at("code")) : "";
                    return "[" + code + "] " + sa_core::py_str(err.at("message"));
                }
            } else if (err.is_string() && !err.get<std::string>().empty()) {
                return err.get<std::string>();
            }
        }
        std::string msg;
        if (obj.contains("message") && !obj.at("message").is_null())
            msg = sa_core::py_str(obj.at("message"));
        else if (obj.contains("resp_message") && !obj.at("resp_message").is_null())
            msg = sa_core::py_str(obj.at("resp_message"));
        if (!msg.empty()) return msg;
        if (obj.contains("code") && !obj.at("code").is_null() &&
            !(obj.at("code").is_number() && obj.at("code").get<double>() == 0.0)) {
            std::string code = sa_core::py_str(obj.at("code"));
            return "[" + code + "] " + msg;
        }
    }
    return trunc_chars(text, 400);
}

std::string minimax_base(const json& settings) {
    std::string base;
    if (settings.is_object() && settings.contains("ttsBaseUrl") && !settings.at("ttsBaseUrl").is_null())
        base = sa_core::py_str(settings.at("ttsBaseUrl"));
    base = p4::strip(base);
    if (base.empty()) base = kMinimaxBase;
    while (!base.empty() && (base.back() == '/' )) base.pop_back();
    if (base.size() >= 3 && base.compare(base.size() - 3, 3, "/v1") == 0)
        base = base.substr(0, base.size() - 3);
    return base;
}

namespace {

std::string str_field(const json& settings, const char* key) {
    if (!settings.is_object() || !settings.contains(key) || settings.at(key).is_null()) return "";
    const json& v = settings.at(key);
    if (v.is_string()) return v.get<std::string>();
    return sa_core::py_str(v);
}

std::string json_get_str(const json& o, const std::string& key, const std::string& def = "") {
    if (!o.is_object() || !o.contains(key) || o.at(key).is_null()) return def;
    return o.at(key).is_string() ? o.at(key).get<std::string>() : sa_core::py_str(o.at(key));
}

// http_json: shared POST/GET JSON transport mirroring _post_json/_get_json.
struct HttpJson {
    json obj = nullptr;
    std::string err;  // empty == success
};

HttpJson http_json(const std::string& method, const std::string& url, const std::string& body,
                   std::vector<std::pair<std::string, std::string>> headers, int timeout,
                   const std::string& label = "配音") {
    HttpJson res;
    http::Request req;
    req.method = method;
    req.url = url;
    req.headers = std::move(headers);
    req.body = body;
    req.timeout_seconds = timeout;
    http::Response r = http::request(req);
    if (!r.transport_ok()) {
        if (r.error == http::Response::Error::Timeout)
            res.err = "请求" + label + "服务超时（" + std::to_string(timeout) + " 秒）";
        else if (r.error == http::Response::Error::Connection)
            res.err = "无法连接" + label + "服务：" + r.error_message;
        else
            res.err = "请求" + label + "服务失败：" + r.error_message;
        return res;
    }
    if (r.status >= 400) {
        res.err = "HTTP " + std::to_string(r.status) + ": " + extract_error(r.body);
        return res;
    }
    auto parsed = json::parse(r.body, nullptr, false);
    if (parsed.is_discarded()) {
        res.err = label + "服务返回了非 JSON 内容：" + trunc_chars(r.body, 200);
        return res;
    }
    res.obj = parsed;
    return res;
}

std::string urlencoded(const std::string& s) { return http::quote_component(s); }

// _minimax_voice_item.
json minimax_voice_item(const json& v) {
    if (!v.is_object()) return nullptr;
    std::string vid;
    if (v.contains("voice_id") && !v.at("voice_id").is_null()) vid = sa_core::py_str(v.at("voice_id"));
    if (vid.empty()) return nullptr;
    std::string gender;
    if (v.contains("gender") && !v.at("gender").is_null()) {
        const json& g = v.at("gender");
        if (g.is_boolean()) {
            gender = "";
        } else if (g.is_number()) {
            int gi = static_cast<int>(g.get<double>());
            if (gi == 0) gender = "女"; else if (gi == 1) gender = "男"; else gender = "";
        } else {
            gender = sa_core::py_str(g);
        }
    }
    std::string name = json_get_str(v, "name");
    if (name.empty()) name = vid;
    json item;
    item["id"] = vid;
    item["name"] = name;
    item["gender"] = gender;
    item["desc"] = json_get_str(v, "desc");
    return item;
}

// _minimax_voice_list: (voices|null, err).
std::pair<json, std::string> minimax_voice_list(const json& settings) {
    std::string key = sa_core::str::trim(str_field(settings, "ttsApiKey"));
    if (key.empty()) return {nullptr, "缺少 MiniMax API Key"};
    std::string group = sa_core::str::trim(str_field(settings, "ttsGroupId"));
    std::string base = minimax_base(settings);
    std::string url = base + "/v1/t2a_v2/voice_list" +
                      (group.empty() ? "" : "?GroupId=" + urlencoded(group));
    auto res = http_json("GET", url, "", {{"Authorization", "Bearer " + key}}, kTimeoutVoices);
    if (!res.err.empty()) return {nullptr, res.err};
    json voices = json::array();
    static const json kEmptyObj = json::object();
    const json& dd = res.obj.contains("data") && res.obj.at("data").is_object()
                         ? res.obj.at("data")
                         : kEmptyObj;
    for (const auto& field : {"voice_list", "custom_voice_list"}) {
        if (!dd.contains(field) || !dd.at(field).is_array()) continue;
        for (const auto& v : dd.at(field)) {
            json item = minimax_voice_item(v);
            if (item.is_null()) continue;
            if (std::string(field) == "custom_voice_list")
                item["desc"] = "自定义音色：" + json_get_str(item, "desc");
            voices.push_back(item);
        }
    }
    if (voices.empty())
        return {nullptr, "语音列表为空（上游返回 " + trunc_chars(sa_core::py_dumps(res.obj), 200) + "）"};
    return {voices, ""};
}

}  // namespace

// ---- parameter coercion (tts_service._float_param / _int_param) ----------
namespace {
double float_param(const json& val, const json& fallback, double def, double lo, double hi) {
    double f = def;
    const json* src = (!val.is_null()) ? &val : (!fallback.is_null() ? &fallback : nullptr);
    bool parsed = false;
    if (src) {
        if (src->is_number()) { f = src->get<double>(); parsed = true; }
        else if (src->is_boolean()) { f = src->get<bool>() ? 1.0 : 0.0; parsed = true; }
        else if (src->is_string()) {
            std::string s = sa_core::str::trim(src->get<std::string>());
            try {
                size_t pos = 0;
                f = std::stod(s, &pos);
                while (pos < s.size() && std::isspace((unsigned char)s[pos])) pos++;
                parsed = (pos == s.size() && !s.empty());
            } catch (...) {}
        }
    }
    if (!parsed) f = def;
    f = std::min(std::max(f, lo), hi);
    // round(x, 2)
    return std::floor(f * 100.0 + 0.5 + 1e-9) / 100.0;
}
long long int_param(const json& val, const json& fallback, long long def, long long lo, long long hi) {
    long long f = def;
    bool parsed = false;
    const json* src = (!val.is_null()) ? &val : (!fallback.is_null() ? &fallback : nullptr);
    if (src) {
        if (src->is_number_integer() || src->is_number_unsigned()) { f = src->get<long long>(); parsed = true; }
        else if (src->is_number_float()) { f = static_cast<long long>(src->get<double>()); parsed = true; }
        else if (src->is_boolean()) { f = src->get<bool>() ? 1 : 0; parsed = true; }
        else if (src->is_string()) {
            auto iv = sa_core::py_int(sa_core::str::trim(src->get<std::string>()));
            if (iv) { f = *iv; parsed = true; }
        }
    }
    if (!parsed) f = def;
    return std::min(std::max(f, lo), hi);
}
}  // namespace

// ---- provider synthesis --------------------------------------------------
std::pair<std::string, std::string> synthesize(const std::string& provider_in,
                                               const std::string& text_in, const std::string& voice_in,
                                               const json& settings, const json& params) {
    std::string text = p4::strip(text_in);
    if (text.empty()) throw TtsError("配音文本不能为空");
    std::string provider = sa_core::str::lower(p4::strip(provider_in));
    json s = settings.is_object() ? settings : json::object();
    json p = params.is_object() ? params : json::object();
    if (provider != "minimax" && provider != "aliyun")
        throw TtsError("不支持的配音服务商: '" + provider + "'");
    std::string key = sa_core::str::trim(str_field(s, "ttsApiKey"));
    if (key.empty())
        throw TtsError(std::string("未配置 ") + (provider == "minimax" ? "MiniMax" : "阿里云") +
                       " 的 API Key（设置页 → 配音）");

    if (provider == "minimax") {
        std::string base = minimax_base(s);
        std::string group = sa_core::str::trim(str_field(s, "ttsGroupId"));
        std::string url = base + "/v1/t2a_v2" + (group.empty() ? "" : "?GroupId=" + urlencoded(group));
        std::string voice = sa_core::str::trim(voice_in);
        if (voice.empty()) voice = sa_core::str::trim(str_field(s, "ttsVoice"));
        std::string model = sa_core::str::trim(json_get_str(p, "model"));
        if (model.empty()) model = sa_core::str::trim(str_field(s, "ttsModel"));
        if (model.empty()) model = "speech-02-hd";
        double speed = float_param(p.contains("speed") ? p.at("speed") : json(),
                                    s.contains("ttsSpeed") ? s.at("ttsSpeed") : json(), 1.0, 0.5, 2.0);
        double vol = float_param(p.contains("vol") ? p.at("vol") : json(),
                                 s.contains("ttsVolume") ? s.at("ttsVolume") : json(), 1.0, 0.5, 2.0);
        long long pitch = int_param(p.contains("pitch") ? p.at("pitch") : json(),
                                    s.contains("ttsPitch") ? s.at("ttsPitch") : json(), 0, -12, 12);
        json body;
        body["model"] = model;
        body["text"] = text;
        body["stream"] = false;
        body["voice_setting"] = json{{"voice_id", voice.empty() ? "female-shaonv" : voice},
                                      {"speed", speed}, {"vol", vol}, {"pitch", pitch}};
        body["audio_setting"] = json{{"sample_rate", 32000}, {"format", "wav"}, {"channel", 1}};
        body["output_format"] = "hex";
        auto res = http_json("POST", url, sa_core::py_dumps(body),
                             {{"Authorization", "Bearer " + key}, {"Content-Type", "application/json"}},
                             kTimeoutSynth);
        if (!res.err.empty()) throw TtsError("MiniMax 合成失败：" + res.err);
        json resp = res.obj.contains("base_resp") && res.obj.at("base_resp").is_object()
                        ? res.obj.at("base_resp")
                        : json::object();
        if (resp.contains("status_code") && !resp.at("status_code").is_null()) {
            const json& code = resp.at("status_code");
            bool zero = code.is_number() && code.get<double>() == 0.0;
            if (!zero) {
                std::string m = json_get_str(resp, "status_msg");
                if (m.empty()) m = trunc_chars(sa_core::py_dumps(resp), 200);
                throw TtsError("MiniMax 合成失败：" + m);
            }
        }
        json data = res.obj.contains("data") && res.obj.at("data").is_object() ? res.obj.at("data")
                                                                               : json::object();
        std::string audio = json_get_str(data, "audio");
        if (audio.empty()) {
            std::string status_field;
            bool status_bad = false;
            if (data.contains("status") && !data.at("status").is_null()) {
                status_field = sa_core::py_str(data.at("status"));
                if (!(data.at("status").is_number() && data.at("status").get<double>() == 2.0))
                    status_bad = true;
            }
            std::string hint = status_bad ? ("合成未完成（status=" + status_field + "）") : "未包含音频";
            throw TtsError("MiniMax 返回为空（" + hint + "）：" +
                           trunc_chars(sa_core::py_dumps(res.obj), 300));
        }
        // hex first (MiniMax output_format=hex), then base64 fallback.
        std::string bytes;
        if (http::hex_to_bytes(audio, &bytes)) return {bytes, "wav"};
        if (http::b64_decode(audio, &bytes)) return {bytes, "wav"};
        throw TtsError("MiniMax 音频解码失败：无法按 hex 或 base64 解析 data.audio");
    }

    // ---- aliyun ----
    std::string model = sa_core::str::trim(json_get_str(p, "model"));
    if (model.empty()) model = sa_core::str::trim(str_field(s, "ttsModel"));
    if (model.empty()) model = "qwen-tts";
    std::string voice = sa_core::str::trim(voice_in);
    if (voice.empty()) voice = sa_core::str::trim(str_field(s, "ttsVoice"));
    if (voice.empty()) voice = "Cherry";
    json body;
    body["model"] = model;
    body["input"] = json{{"text", text}, {"voice", voice}};
    std::string url = sa_core::str::trim(str_field(s, "ttsBaseUrl"));
    if (url.empty()) {
        std::string lowered = sa_core::str::lower(model);
        bool cosy = sa_core::str::starts_with(lowered, "cosyvoice") ||
                    sa_core::str::starts_with(lowered, "qwen-audio");
        url = cosy ? kAliyunTtsUrl : kAliyunUrl;
    }
    http::Request req;
    req.method = "POST";
    req.url = url;
    req.body = sa_core::py_dumps(body);
    req.timeout_seconds = kTimeoutSynth;
    req.headers = {{"Authorization", "Bearer " + key},
                   {"Content-Type", "application/json"},
                   {"X-DashScope-SSE", "enable"}};
    http::Response r = http::request(req);
    if (!r.transport_ok()) {
        if (r.error == http::Response::Error::Timeout)
            throw TtsError("请求阿里云 TTS 超时（" + std::to_string(kTimeoutSynth) + " 秒）");
        if (r.error == http::Response::Error::Connection)
            throw TtsError("无法连接阿里云 TTS：" + r.error_message);
        throw TtsError("请求阿里云 TTS 失败：" + r.error_message);
    }
    if (r.status >= 400)
        throw TtsError("阿里云 TTS 请求失败：HTTP " + std::to_string(r.status) + " " + extract_error(r.body));
    std::string body_text = sa_core::decode_utf8_sig_replace(r.body);

    // SSE: each data: chunk carries independent base64 -> decode-per-chunk then
    // concatenate the BYTE streams (concatenating base64 first truncates at '=').
    std::vector<std::string> chunks;
    bool saw_data = false;
    auto b64_payload = [](const json& audio) -> std::string {
        if (audio.is_object() && audio.contains("data") && !audio.at("data").is_null())
            return sa_core::py_str(audio.at("data"));
        if (audio.is_string()) return audio.get<std::string>();
        return "";
    };
    {
        size_t pos = 0;
        std::istringstream lines(body_text);
        std::string line;
        while (std::getline(lines, line)) {
            std::string sline = p4::strip(line);
            if (!sa_core::str::starts_with(sline, "data:")) continue;
            saw_data = true;
            std::string payload = p4::strip(sline.substr(5));
            if (payload.empty() || payload == "[DONE]") continue;
            auto ev = json::parse(payload, nullptr, false);
            if (ev.is_discarded() || !ev.is_object()) continue;
            bool failed = json_get_str(ev, "result") == "failed";
            bool has_err = ev.contains("error") && !ev.at("error").is_null();
            if (failed || has_err)
                throw TtsError("阿里云 TTS 合成失败：" + trunc_chars(sa_core::py_dumps(ev), 200));
            if (ev.contains("output") && ev.at("output").is_object()) {
                const json& out = ev.at("output");
                std::string piece;
                if (out.contains("audio") && !out.at("audio").is_null())
                    piece = b64_payload(out.at("audio"));
                if (piece.empty() && out.contains("audio_frame") && !out.at("audio_frame").is_null())
                    piece = b64_payload(out.at("audio_frame"));
                if (!piece.empty()) chunks.push_back(piece);
            }
            (void)pos;
        }
    }
    if (!chunks.empty()) {
        std::string audio;
        for (const auto& c : chunks) {
            std::string dec;
            if (!http::b64_decode(c, &dec)) throw TtsError("阿里云 TTS 音频解码失败：base64 分块无效");
            audio += dec;
        }
        return {audio, "wav"};
    }
    if (!saw_data) {
        // Non-streaming fallback: output.audio.url download / .data decode.
        auto obj = json::parse(p4::strip(body_text), nullptr, false);
        if (!obj.is_discarded() && obj.is_object()) {
            json out = obj.contains("output") && obj.at("output").is_object() ? obj.at("output")
                                                                              : json::object();
            std::string audio;
            bool got = false;
            if (out.contains("audio") && out.at("audio").is_object()) {
                const json& a = out.at("audio");
                std::string data = json_get_str(a, "data");
                std::string dl = json_get_str(a, "url");
                if (!data.empty()) {
                    got = http::b64_decode(data, &audio);
                } else if (!dl.empty()) {
                    http::Request dr;
                    dr.method = "GET";
                    dr.url = dl;
                    dr.timeout_seconds = 60;
                    dr.headers = {{"User-Agent", "student-age-editor"}};
                    http::Response d = http::request(dr);
                    if (d.transport_ok() && d.status < 400) {
                        audio = d.body;
                        got = true;
                    } else {
                        throw TtsError("下载阿里云 TTS 音频失败：" + d.error_message);
                    }
                }
            } else if (out.contains("audio") && out.at("audio").is_string()) {
                got = http::b64_decode(out.at("audio").get<std::string>(), &audio);
            }
            if (got) return {audio, "wav"};
            bool errish = (obj.contains("code") && !obj.at("code").is_null()) ||
                          (obj.contains("message") && !obj.at("message").is_null()) ||
                          (obj.contains("error") && !obj.at("error").is_null());
            if (errish) throw TtsError("阿里云 TTS 请求失败：" + extract_error(body_text));
        }
    }
    throw TtsError("阿里云 TTS 未返回音频数据（请检查 model/voice 是否有效）");
}

json voices_list(const std::string& provider_in, const json& settings) {
    std::string provider = sa_core::str::lower(p4::strip(provider_in));
    json s = settings.is_object() ? settings : json::object();
    if (provider == "minimax") {
        auto [voices, err] = minimax_voice_list(s);
        if (!voices.is_null()) return json{{"voices", voices}, {"source", "live"}};
        return json{{"voices", minimax_fallback_voices()}, {"source", "preset"}};
    }
    if (provider == "aliyun") {
        std::string model = sa_core::str::lower(sa_core::str::trim(str_field(s, "ttsModel")));
        if (model.empty()) model = "qwen-tts";
        const json& table = sa_core::str::starts_with(model, "cosyvoice") ? aliyun_cosy_voices()
                                                                          : aliyun_qwen_voices();
        return json{{"voices", table}, {"source", "preset"}};
    }
    throw TtsError("不支持的配音服务商: '" + provider + "'");
}

json test_connection(const std::string& provider_in, const json& settings, const json& params) {
    std::string provider = sa_core::str::lower(p4::strip(provider_in));
    try {
        if (provider == "minimax") {
            auto [voices, err] = minimax_voice_list(settings.is_object() ? settings : json::object());
            if (!err.empty()) return json{{"ok", false}, {"error", err}};
            return json{{"ok", true},
                        {"detail", "连接成功，共 " + std::to_string(voices.size()) + " 个音色"}};
        }
        if (provider == "aliyun") {
            auto [bytes, ext] = synthesize("aliyun", "你好，我是测试语音。", "", settings, params);
            return json{{"ok", true},
                        {"detail", "连接成功，合成 " + std::to_string(bytes.size()) + "B " + ext}};
        }
        return json{{"ok", false}, {"error", "不支持的配音服务商: '" + provider + "'"}};
    } catch (const TtsError& e) {
        return json{{"ok", false}, {"error", e.what()}};
    } catch (const std::exception& e) {
        return json{{"ok", false}, {"error", std::string(e.what())}};
    }
}

// ---- encoder detection + wav->ogg ----------------------------------------
#ifdef _WIN32
namespace {
std::wstring utf8_to_wide_tts(std::string_view s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

// Quote one argument for the Win32 command line (CommandLineToArgvW rules):
// wrap in double quotes and double any backslash run that precedes a quote or
// the closing quote. Without the backslash doubling, a path whose final
// component ends in '\' (or an arg containing '"') would parse as extra args.
std::wstring quote_win_arg(const std::string& arg) {
    std::wstring a = utf8_to_wide_tts(arg);
    std::wstring out;
    out.push_back(L'"');
    size_t backslashes = 0;
    for (wchar_t c : a) {
        if (c == L'\\') {
            ++backslashes;
            continue;
        }
        if (c == L'"') {
            out.append(backslashes * 2 + 1, L'\\');  // escape the quote
            out.push_back(L'"');
        } else {
            out.append(backslashes, L'\\');
            out.push_back(c);
        }
        backslashes = 0;
    }
    out.append(backslashes * 2, L'\\');  // double trailing backslashes
    out.push_back(L'"');
    return out;
}
}  // namespace
#endif

std::optional<std::string> run_capture(const std::vector<std::string>& argv,
                                       const std::string& input) {
    if (argv.empty()) return std::nullopt;
#ifdef _WIN32
    auto make_pipe = [](HANDLE& rd, HANDLE& wr) {
        SECURITY_ATTRIBUTES sa{};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;
        return CreatePipe(&rd, &wr, &sa, 0);
    };
    HANDLE c_in_r = nullptr, c_in_w = nullptr, c_out_r = nullptr, c_out_w = nullptr;
    HANDLE nul_w = nullptr;
    if (!make_pipe(c_in_r, c_in_w) || !make_pipe(c_out_r, c_out_w)) {
        if (c_in_r) CloseHandle(c_in_r);
        if (c_in_w) CloseHandle(c_in_w);
        if (c_out_r) CloseHandle(c_out_r);
        if (c_out_w) CloseHandle(c_out_w);
        return std::nullopt;
    }
    SetHandleInformation(c_in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(c_out_r, HANDLE_FLAG_INHERIT, 0);
    nul_w = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                        OPEN_EXISTING, 0, nullptr);
    std::wstring cmdline;
    for (size_t i = 0; i < argv.size(); ++i) {
        if (i) cmdline.push_back(L' ');
        cmdline += quote_win_arg(argv[i]);
    }
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = c_in_r;
    si.hStdOutput = c_out_w;
    si.hStdError = nul_w ? nul_w : c_out_w;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> cbuf(cmdline.begin(), cmdline.end());
    cbuf.push_back(L'\0');
    // CreateProcessW: the command line is UTF-16, so a temp dir under a CJK
    // %TEMP% (the oggenc scratch path) is passed intact instead of being
    // interpreted as ANSI bytes by CreateProcessA.
    BOOL ok = CreateProcessW(nullptr, cbuf.data(), nullptr, nullptr, TRUE, 0, nullptr, nullptr,
                             &si, &pi);
    CloseHandle(c_in_r);
    CloseHandle(c_out_w);
    if (!ok) {
        CloseHandle(c_in_w);
        CloseHandle(c_out_r);
        if (nul_w) CloseHandle(nul_w);
        return std::nullopt;
    }
    // Feed stdin on a helper thread while the main thread drains stdout. Writing
    // all of `input` first (the old code) deadlocks whenever the child fills its
    // bounded stdout pipe (~64KB) before it has consumed all of stdin: the child
    // blocks on write, the parent blocks on WriteFile.
    std::thread feeder;
    if (!input.empty()) {
        feeder = std::thread([in = input, h = c_in_w]() {
            size_t off = 0;
            while (off < in.size()) {
                DWORD chunk = static_cast<DWORD>(std::min<size_t>(in.size() - off, 1u << 20));
                DWORD written = 0;
                if (!WriteFile(h, in.data() + off, chunk, &written, nullptr) || written == 0) break;
                off += written;
            }
            CloseHandle(h);  // EOF for the child
        });
    } else {
        CloseHandle(c_in_w);
    }

    std::string out;
    char buf[8192];
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(kTimeoutEncode);
    bool timed_out = false;
    for (;;) {
        if (std::chrono::steady_clock::now() >= deadline) {
            timed_out = true;  // enforced below: the old bounded-spin was unreachable
            break;
        }
        DWORD avail = 0;
        if (!PeekNamedPipe(c_out_r, nullptr, 0, nullptr, &avail, nullptr)) break;
        if (avail > 0) {
            DWORD rd = 0;
            if (!ReadFile(c_out_r, buf, sizeof(buf), &rd, nullptr) || rd == 0) break;
            out.append(buf, rd);
            continue;
        }
        if (WaitForSingleObject(pi.hProcess, 10) == WAIT_OBJECT_0) {
            // Child exited: drain whatever is still buffered, then stop.
            while (PeekNamedPipe(c_out_r, nullptr, 0, nullptr, &avail, nullptr) && avail > 0) {
                DWORD rd = 0;
                if (!ReadFile(c_out_r, buf, sizeof(buf), &rd, nullptr) || rd == 0) break;
                out.append(buf, rd);
            }
            break;
        }
    }
    if (timed_out) TerminateProcess(pi.hProcess, 1);
    WaitForSingleObject(pi.hProcess, 5000);
    if (feeder.joinable()) feeder.join();  // pipe break on terminate unblocks WriteFile
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(c_out_r);
    if (nul_w) CloseHandle(nul_w);
    if (timed_out || code != 0 || out.empty()) return std::nullopt;
    return out;
#else
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0) return std::nullopt;
    if (pipe(out_pipe) != 0) { close(in_pipe[0]); close(in_pipe[1]); return std::nullopt; }
    pid_t pid = fork();
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]);
        return std::nullopt;
    }
    if (pid == 0) {
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        int nul = open("/dev/null", O_WRONLY);
        dup2(nul, STDERR_FILENO);
        close(nul);
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]);
        std::vector<char*> args;
        for (auto& a : argv) args.push_back(const_cast<char*>(a.c_str()));
        args.push_back(nullptr);
        execvp(args[0], args.data());
        _exit(127);
    }
    close(in_pipe[0]);
    close(out_pipe[1]);
    // Non-blocking stdin so a full pipe to a child that has not yet drained
    // stdout cannot deadlock the parent; poll() multiplexes both directions and
    // the deadline bounds the whole exchange (SIGKILL the child on timeout).
    fcntl(in_pipe[1], F_SETFL, fcntl(in_pipe[1], F_GETFL, 0) | O_NONBLOCK);
    std::string out;
    char buf[8192];
    size_t off = 0;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(kTimeoutEncode);
    bool timed_out = false;
    bool in_open = true;
    while (true) {
        if (std::chrono::steady_clock::now() >= deadline) {
            timed_out = true;
            break;
        }
        struct pollfd fds[2];
        nfds_t nfds = 0;
        int in_idx = -1, out_idx = -1;
        if (in_open && off < input.size()) {
            in_idx = static_cast<int>(nfds);
            fds[nfds].fd = in_pipe[1];
            fds[nfds].events = POLLOUT;
            fds[nfds].revents = 0;
            ++nfds;
        }
        out_idx = static_cast<int>(nfds);
        fds[nfds].fd = out_pipe[0];
        fds[nfds].events = POLLIN;
        fds[nfds].revents = 0;
        ++nfds;
        int pr = ::poll(fds, nfds, 200);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (fds[out_idx].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(out_pipe[0], buf, sizeof(buf));
            if (n > 0) {
                out.append(buf, static_cast<size_t>(n));
            } else if (n == 0) {
                break;  // EOF: child closed stdout
            } else if (errno != EAGAIN && errno != EINTR) {
                break;
            }
        }
        if (in_idx >= 0 && (fds[in_idx].revents & (POLLOUT | POLLERR | POLLHUP))) {
            ssize_t w = write(in_pipe[1], input.data() + off, input.size() - off);
            if (w > 0) off += static_cast<size_t>(w);
        }
        // Deliver EOF as soon as stdin is drained: encoders that buffer until
        // end-of-input would otherwise never finish (and hit the deadline).
        if (in_open && off >= input.size()) {
            close(in_pipe[1]);
            in_open = false;
        }
        if (!in_open && (fds[out_idx].revents & POLLHUP)) break;
    }
    if (in_open) close(in_pipe[1]);
    close(out_pipe[0]);
    if (timed_out) kill(pid, SIGKILL);
    int status = 0;
    waitpid(pid, &status, 0);
    if (timed_out || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || out.empty())
        return std::nullopt;
    return out;
#endif
}

std::optional<std::string> which_exe(const std::string& name) {
#ifdef _WIN32
    std::string env = name + ".exe";
    std::string path = sa_core::paths::getenv_utf8("PATH");
    if (path.empty()) return std::nullopt;
    std::istringstream ps(path);
    std::string dir;
    while (std::getline(ps, dir, ';')) {
        if (dir.empty()) continue;
        std::string cand = dir + "\\" + env;
        if (sa_core::paths::is_file(cand)) return cand;
    }
    return std::nullopt;
#else
    std::string path = sa_core::paths::getenv_utf8("PATH");
    if (path.empty()) return std::nullopt;
    std::istringstream ps(path);
    std::string dir;
    while (std::getline(ps, dir, ':')) {
        std::string cand = (dir.empty() ? std::string(".") : dir) + "/" + name;
        if (access(cand.c_str(), X_OK) == 0) return cand;
    }
    return std::nullopt;
#endif
}

std::string detect_encoder() {
    static std::mutex m;
    static std::string cached;  // only positive results are cached
    {
        std::lock_guard<std::mutex> lk(m);
        if (!cached.empty()) return cached;
    }
    // Test/ops override: force "no encoder available" deterministically.
    std::string dis = sa_core::paths::getenv_utf8("EDITOR_TTS_ENCODER_DISABLE");
    if (!dis.empty() && dis != "0") return "";
    std::string found;
    if (which_exe("ffmpeg")) found = "ffmpeg";
    else if (which_exe("oggenc")) found = "oggenc";
    if (found.empty()) return found;  // miss is cheap; do not cache (encoder may appear later)
    std::lock_guard<std::mutex> lk(m);
    cached = found;
    return cached;
}

std::optional<std::string> encode_ogg(std::string_view wav) {
    if (wav.empty()) return std::nullopt;
    std::string enc = detect_encoder();
    if (enc == "ffmpeg") {
        auto out = run_capture({"ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", "-",
                                "-c:a", "libvorbis", "-q:a", "5", "-f", "ogg", "-"},
                               std::string(wav));
        return out;
    }
    if (enc == "oggenc") {
        std::string tmp = sa_core::paths::join(sa_core::paths::path_to_utf8(
                                                   std::filesystem::temp_directory_path()),
                                               "sa_tts_" + p4::random_hex(8) + ".wav");
        std::optional<std::string> out;
        {
            std::ofstream f(sa_core::paths::to_path(tmp), std::ios::binary);
            f.write(wav.data(), static_cast<std::streamsize>(wav.size()));
        }
        out = run_capture({"oggenc", "-Q", "-o", "-", tmp}, "");
        sa_core::paths::remove_file(tmp);
        return out;
    }
    return std::nullopt;
}

}  // namespace tts

// ===========================================================================
// tts_store namespace (mod audio/tts/ + AudioCfg/TalkCfg writes)
// ===========================================================================
namespace tts_store {
namespace {

constexpr const char* kAllowed = "wav|ogg|mp3|m4a";

std::mutex g_cfg_lock;  // tts_store._CFG_LOCK: serialise AudioCfg id assignment

std::string safe_key(std::string key) {
    key = p4::strip(key);
    static const std::regex kGood("^[A-Za-z0-9_\\-]+$");
    if (key.empty() || !std::regex_match(key, kGood))
        key = "tts_" + std::to_string(sa_core::now_ms());  // ms granularity
    return key;
}

void check_mod_root(const std::string& mod_root) {
    if (mod_root.empty() || !sa_core::paths::is_dir(mod_root))
        throw TtsStoreError("未选择模组或模组目录不存在");
}

std::string ext_of(const std::string& name) {
    return sa_core::str::lower(p4::split_ext(name).second).substr(
        sa_core::str::lower(p4::split_ext(name).second).empty() ? 0 : 1);
}

void check_abs_in_audio_dir(const std::string& mod_root, const std::string& abs_path,
                            const std::string& verb) {
    std::string base = sa_core::paths::abs_path(sa_core::paths::join(mod_root, kAudioDir));
    if (abs_path != base &&
        !(abs_path.size() > base.size() && abs_path.compare(0, base.size(), base) == 0 &&
          (abs_path[base.size()] == '/' || abs_path[base.size()] == '\\')))
        throw TtsStoreError("仅允许" + verb + " audio/tts/ 内的素材");
}

}  // namespace

json save_audio(const std::string& mod_root, const std::string& audio, const std::string& ext_in,
                const std::string& key, bool ogg) {
    check_mod_root(mod_root);
    std::string ext = sa_core::str::lower(ext_in);
    if (!ext.empty() && ext.front() == '.') ext = ext.substr(1);
    if (ext.empty()) ext = "wav";
    static const std::vector<std::string> kAllow = {"wav", "ogg", "mp3", "m4a"};
    if (std::find(kAllow.begin(), kAllow.end(), ext) == kAllow.end())
        throw TtsStoreError("不支持的音频格式: " + ext);
    if (audio.empty()) throw TtsStoreError("音频内容为空");
    std::string data = audio;
    bool converted = false;
    if (ext == "wav" && ogg) {
        if (auto enc = tts::encode_ogg(data)) {
            data = *enc;
            ext = "ogg";
            converted = true;
        }
    }
    std::string k = safe_key(key);
    std::string rel = std::string(kAudioDir) + "/" + k + "." + ext;
    std::string abs;
    try {
        abs = p4::fs_resolve(mod_root, rel);
    } catch (const SandboxError& e) {
        throw TtsStoreError(e.what());
    }
    try {
        sa_core::write_bytes_atomic(abs, data);
    } catch (const std::exception& e) {
        throw TtsStoreError(std::string("保存音频失败: ") + e.what());
    }
    json out;
    out["key"] = k;
    out["path"] = rel;
    out["ext"] = ext;
    out["convertedOgg"] = converted;
    out["bytes"] = static_cast<long long>(data.size());
    return out;
}

long long register_audio_cfg(const std::string& cfg_dir, const std::string& key,
                             const std::string& title) {
    if (cfg_dir.empty()) throw TtsStoreError("未选择模组，无法登记 AudioCfg");
    std::lock_guard<std::mutex> lk(g_cfg_lock);
    std::string k = safe_key(key);
    std::string path = sa_core::paths::join(cfg_dir, "AudioCfg.json");
    json data = json::object();
    std::optional<long long> expect;
    if (sa_core::paths::is_file(path)) {
        if (auto st = sa_core::paths::stat(path)) expect = st->mtime_ns;
        if (auto raw = sa_core::paths::read_bytes(path)) {
            // BOM-tolerant decode (matches bind_talk_audio): a BOM-prefixed or
            // malformed table must NOT fall through as an empty object, or the
            // write below would wipe every existing voice entry.
            std::string body = *raw;
            if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF)
                body = body.substr(3);
            auto parsed = json::parse(body, nullptr, false);
            if (parsed.is_discarded() || !parsed.is_object())
                throw TtsStoreError("AudioCfg.json 结构异常，无法登记配音（已中止写入以保护现有数据）");
            data = parsed;
        }
    }
    long long max_id = 0;
    for (auto it = data.begin(); it != data.end(); ++it) {
        if (!it.value().is_object()) continue;
        const json& rec = it.value();
        std::string idv = rec.contains("id") && !rec.at("id").is_null() ? sa_core::py_str(rec.at("id"))
                                                                        : it.key();
        auto iv = sa_core::py_int(idv);
        if (!iv) continue;
        max_id = std::max(max_id, *iv);
    }
    long long new_id = max_id + 1;
    std::string summary = p4::strip(title);
    if (summary.empty()) summary = "配音 " + k;
    if (p4::utf8_len(summary) > 24) summary = trunc_chars(summary, 24);
    json row;
    row["id"] = new_id;
    row["name"] = summary;
    row["url"] = std::string(kAudioDir) + "/" + k;
    row["type"] = 0;
    row["volumn"] = 0;
    row["group"] = json::array();
    row["cond"] = json::array();
    row["disable"] = 0;
    row["uiType"] = 0;
    data[std::to_string(new_id)] = std::move(row);
    json result = cfg_store::write_cfg(path, data, expect, nullptr, false, true);
    if (result.value("conflict", false))
        throw TtsStoreError("登记 AudioCfg 冲突：文件在读取后已被其他窗口修改，请重试");
    if (!result.value("ok", false))
        throw TtsStoreError("登记 AudioCfg 失败: " + result.value("error", std::string("未知错误")));
    return new_id;
}

json bind_talk_audio(const std::string& mod_root, const std::string& talk_id_in, long long audio_cfg_id) {
    std::string talk_id = sa_core::py_str(json(talk_id_in));  // str(talk_id)
    std::vector<std::string> candidates = {
        sa_core::paths::join(sa_core::paths::join(mod_root, "Cfgs"), "TalkCfg.json"),
        sa_core::paths::join(sa_core::paths::join(mod_root, "Cfgs"), "zh-cn") + "\\TalkCfg.json",
    };
    // Order: Cfgs/zh-cn first then Cfgs (api candidates list is zh-cn then Cfgs).
    candidates = {
        sa_core::paths::join(sa_core::paths::join(sa_core::paths::join(mod_root, "Cfgs"), "zh-cn"),
                             "TalkCfg.json"),
        sa_core::paths::join(sa_core::paths::join(mod_root, "Cfgs"), "TalkCfg.json"),
    };
    std::string path;
    for (const auto& c : candidates)
        if (sa_core::paths::is_file(c)) { path = c; break; }
    if (path.empty()) throw TtsStoreError("TalkCfg.json 不存在，无法绑定对白");
    std::optional<long long> expect;
    if (auto st = sa_core::paths::stat(path)) expect = st->mtime_ns;
    auto raw = sa_core::paths::read_bytes(path);
    json data;
    if (raw) {
        std::string body = *raw;
        if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF) body = body.substr(3);
        data = json::parse(body, nullptr, false);
    }
    if (data.is_discarded() || !data.is_object()) throw TtsStoreError("TalkCfg 结构异常，无法绑定");
    if (!data.contains(talk_id) || !data.at(talk_id).is_object())
        throw TtsStoreError("对白 " + talk_id + " 不存在于 TalkCfg");
    data[talk_id]["audio"] = audio_cfg_id;
    json result = cfg_store::write_cfg(path, data, expect, nullptr, false, true);
    if (result.value("conflict", false))
        throw TtsStoreError("写回 TalkCfg 冲突：文件在读取后已被其他窗口修改（" +
                            result.value("reason", std::string("未知原因")) + "），请重试绑定");
    if (!result.value("ok", false))
        throw TtsStoreError("写回 TalkCfg 失败: " + result.value("error", std::string("未知错误")));
    return json{{"talkId", talk_id}, {"audioCfgId", audio_cfg_id}};
}

json list_materials(const std::string& mod_root) {
    check_mod_root(mod_root);
    json items = json::array();
    std::string dir = sa_core::paths::join(mod_root, kAudioDir);
    if (!sa_core::paths::is_dir(dir)) return items;
    static const std::vector<std::string> kAllow = {"wav", "ogg", "mp3", "m4a"};
    for (const auto& name : sa_core::paths::listdir_sorted(dir)) {
        std::string full = sa_core::paths::join(dir, name);
        if (!sa_core::paths::is_file(full)) continue;
        std::string e = ext_of(name);
        if (std::find(kAllow.begin(), kAllow.end(), e) == kAllow.end()) continue;
        long long sz = sa_core::paths::file_size(full);
        items.push_back(json{{"path", std::string(kAudioDir) + "/" + name},
                             {"size", sz < 0 ? 0 : sz}, {"ext", e}});
    }
    return items;
}

std::string read_audio(const std::string& mod_root, const std::string& rel_in) {
    check_mod_root(mod_root);
    std::string rel = p4::strip(sa_core::str::replace_all(rel_in, "\\", "/"));
    std::string prefix = std::string(kAudioDir) + "/";
    if (!sa_core::str::starts_with(rel, prefix)) throw TtsStoreError("仅允许读取 audio/tts/ 内的素材");
    std::string abs;
    try {
        abs = p4::fs_resolve(mod_root, rel);
    } catch (const SandboxError& e) {
        throw TtsStoreError(e.what());
    }
    check_abs_in_audio_dir(mod_root, abs, "读取");
    std::error_code ec;
    if (std::filesystem::is_symlink(sa_core::paths::to_path(abs), ec))
        throw TtsStoreError("不允许读取符号链接指向的素材");
    std::string real = sa_core::paths::path_to_utf8(std::filesystem::weakly_canonical(
        sa_core::paths::to_path(abs), ec));
    check_abs_in_audio_dir(mod_root, real, "读取");
    if (!sa_core::paths::is_file(abs)) throw TtsStoreError("文件不存在: " + rel);
    auto raw = sa_core::paths::read_bytes(abs);
    if (!raw) throw TtsStoreError("读取音频失败");
    return *raw;
}

std::string delete_material(const std::string& mod_root, const std::string& rel_in) {
    check_mod_root(mod_root);
    std::string rel = p4::strip(sa_core::str::replace_all(rel_in, "\\", "/"));
    std::string prefix = std::string(kAudioDir) + "/";
    if (!sa_core::str::starts_with(rel, prefix)) throw TtsStoreError("仅允许删除 audio/tts/ 内的素材");
    std::string abs;
    try {
        abs = p4::fs_resolve(mod_root, rel);
    } catch (const SandboxError& e) {
        throw TtsStoreError(e.what());
    }
    check_abs_in_audio_dir(mod_root, abs, "删除");
    std::error_code ec;
    if (std::filesystem::is_symlink(sa_core::paths::to_path(abs), ec))
        throw TtsStoreError("不允许删除符号链接");
    std::string real = sa_core::paths::path_to_utf8(std::filesystem::weakly_canonical(
        sa_core::paths::to_path(abs), ec));
    check_abs_in_audio_dir(mod_root, real, "删除");
    if (!sa_core::paths::is_file(abs)) throw TtsStoreError("文件不存在: " + rel);
    if (!sa_core::paths::remove_file(abs)) throw TtsStoreError("删除失败: " + rel);
    return rel;
}

}  // namespace tts_store

// ===========================================================================
// /api/tts/* routes (api.py:1793-1968)
// ===========================================================================
namespace {

std::string b64_str(const std::string& bytes) { return sa_core::http::b64_encode(bytes); }

std::string json_get_str(const json& o, const std::string& key, const std::string& def = "") {
    if (!o.is_object() || !o.contains(key) || o.at(key).is_null()) return def;
    return o.at(key).is_string() ? o.at(key).get<std::string>() : sa_core::py_str(o.at(key));
}

json read_settings() { return env_store_ai::read_ai_settings(sa::editor_root()); }

// CONVENTIONS `_truthy`: only real True / "true". Used for the `ogg` flag.
bool truthy_json(const json& v) {
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_string()) return sa_core::str::lower(sa_core::str::trim(v.get<std::string>())) == "true";
    return false;
}

// Python `bool(x)` truthiness (empty/0/null/false == False). api.py's
// `if body.get("writeCfg"):` uses this (NOT _truthy): a non-empty "false"
// string is Truthy there — a deliberate, documented divergence from `ogg`.
bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    if (v.is_object() || v.is_array()) return !v.empty();
    return true;
}

std::string body_str(const json& body, const std::string& key) {
    if (!body.is_object() || !body.contains(key) || body.at(key).is_null()) return "";
    return body.at(key).is_string() ? body.at(key).get<std::string>() : sa_core::py_str(body.at(key));
}

Resp tts_error(const TtsError& e) { return Resp::Json(400, json{{"error", e.what()}}); }
Resp tts_store_error(const TtsStoreError& e) { return Resp::Json(400, json{{"error", e.what()}}); }

}  // namespace

void register_tts_routes(Router& r) {
    // GET /api/tts/settings — {"settings": read_ai_settings()}.
    r.get(R"(/api/tts/settings)", [](const Req&) -> Resp {
        return Resp::Json(200, json{{"settings", read_settings()}});
    });

    // PUT /api/tts/settings — only tts* keys accepted.
    r.put(R"(/api/tts/settings)", [](const Req& req) -> Resp {
        const json& body = req.body;
        json patch = body.is_object() && body.contains("settings") && body.at("settings").is_object()
                         ? body.at("settings")
                         : (body.is_object() ? body : json());
        if (!patch.is_object())
            return Resp::Json(400, json{{"error", "body must be a settings object"}});
        json tts_patch = json::object();
        for (auto it = patch.begin(); it != patch.end(); ++it)
            if (sa_core::str::starts_with(it.key(), "tts")) tts_patch[it.key()] = it.value();
        json settings = env_store_ai::write_ai_settings(sa::editor_root(), tts_patch);
        return Resp::Json(200, json{{"ok", true}, {"settings", std::move(settings)}});
    });

    // POST /api/tts/test.
    r.post(R"(/api/tts/test)", [](const Req& req) -> Resp {
        try {
            json settings = req.body.is_object() && req.body.contains("settings")
                                ? req.body.at("settings")
                                : json::object();
            json params = req.body.is_object() && req.body.contains("params")
                              ? req.body.at("params")
                              : json::object();
            return Resp::Json(200, tts::test_connection(body_str(req.body, "provider"), settings, params));
        } catch (const std::exception& e) {
            return Resp::Json(500, json{{"error", std::string("Exception: ") + e.what()}});
        }
    });

    // GET /api/tts/voices.
    r.get(R"(/api/tts/voices)", [](const Req& req) -> Resp {
        try {
            json settings = read_settings();
            std::string provider;
            auto it = req.query.find("provider");
            if (it != req.query.end() && !it->second.empty())
                provider = it->second;
            else
                provider = json_get_str(settings, "ttsProvider");
            return Resp::Json(200, tts::voices_list(provider, settings));
        } catch (const TtsError& e) {
            return tts_error(e);
        }
    });

    // POST /api/tts/synthesize.
    r.post(R"(/api/tts/synthesize)", [](const Req& req) -> Resp {
        try {
            json settings = read_settings();
            std::string provider = body_str(req.body, "provider");
            if (provider.empty()) provider = json_get_str(settings, "ttsProvider");
            json params = req.body.is_object() && req.body.contains("params") ? req.body.at("params")
                                                                              : json::object();
            auto [bytes, ext] = tts::synthesize(provider, body_str(req.body, "text"),
                                                body_str(req.body, "voice"), settings, params);
            json out;
            out["audio"] = b64_str(bytes);
            out["ext"] = ext;
            out["bytes"] = static_cast<long long>(bytes.size());
            return Resp::Json(200, std::move(out));
        } catch (const TtsError& e) {
            return tts_error(e);
        }
    });

    // POST /api/tts/save.
    r.post(R"(/api/tts/save)", [](const Req& req) -> Resp {
        std::string audio;
        if (!sa_core::http::b64_decode(body_str(req.body, "audio"), &audio))
            return Resp::Json(400, json{{"error", "audio base64 decode failed"}});
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (mod_root.empty()) return Resp::Json(400, json{{"error", "未选择模组"}});
        bool ogg = req.body.is_object() && req.body.contains("ogg") && truthy_json(req.body.at("ogg"));
        json saved;
        try {
            saved = tts_store::save_audio(mod_root, audio, body_str(req.body, "ext"),
                                           body_str(req.body, "key"), ogg);
        } catch (const TtsStoreError& e) {
            return tts_store_error(e);
        }
        // Build responses in Python's key order: ok, <saved...>, audioCfgId,
        // boundTalkId / warning.
        auto envelope = [&](const json& extra_id, const json& extra_tail) {
            json out = json::object();
            out["ok"] = true;
            for (auto it = saved.begin(); it != saved.end(); ++it) out[it.key()] = it.value();
            for (auto it = extra_id.begin(); it != extra_id.end(); ++it) out[it.key()] = it.value();
            for (auto it = extra_tail.begin(); it != extra_tail.end(); ++it) out[it.key()] = it.value();
            return Resp::Json(200, std::move(out));
        };
        std::string cfg_dir = sa::cfg_dir();
        long long audio_cfg_id = 0;  // 0 == None
        bool have_id = false;
        bool write_cfg = req.body.is_object() && req.body.contains("writeCfg") &&
                         py_truthy(req.body.at("writeCfg"));
        if (write_cfg) {
            try {
                audio_cfg_id = tts_store::register_audio_cfg(cfg_dir, saved["key"].get<std::string>(),
                                                             body_str(req.body, "title"));
                have_id = true;
                invalidate_mod_cfgs_cache();
                invalidate_preview_cache();
            } catch (const std::exception& e) {
                json id{{"audioCfgId", nullptr}};
                json tail{{"warning", std::string("文件已保存，登记 AudioCfg 失败: ") + e.what()}};
                return envelope(id, tail);
            }
        }
        std::string bind_talk = sa_core::str::trim(body_str(req.body, "bindTalkId"));
        if (!bind_talk.empty()) {
            if (!have_id) {
                json id{{"audioCfgId", nullptr}};
                json tail{{"boundTalkId", nullptr},
                          {"warning", "未绑定对白 " + bind_talk + "：本次未登记 AudioCfg"}};
                return envelope(id, tail);
            }
            try {
                tts_store::bind_talk_audio(mod_root, bind_talk, audio_cfg_id);
                invalidate_mod_cfgs_cache();
                invalidate_preview_cache();
                json id{{"audioCfgId", audio_cfg_id}};
                json tail{{"boundTalkId", bind_talk}};
                return envelope(id, tail);
            } catch (const TtsStoreError& e) {
                json id{{"audioCfgId", audio_cfg_id}};
                json tail{{"boundTalkId", nullptr},
                          {"warning", std::string("音频已保存并登记，绑定对白失败: ") + e.what()}};
                return envelope(id, tail);
            }
        }
        json id = have_id ? json{{"audioCfgId", audio_cfg_id}} : json{{"audioCfgId", nullptr}};
        json tail{{"boundTalkId", nullptr}};
        return envelope(id, tail);
    });

    // GET /api/tts/audio?path=... — base64 + ext.
    r.get(R"(/api/tts/audio)", [](const Req& req) -> Resp {
        auto it = req.query.find("path");
        std::string rel = it == req.query.end() ? "" : it->second;
        if (rel.empty()) return Resp::Json(400, json{{"error", "path required"}});
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        std::string blob;
        try {
            blob = tts_store::read_audio(mod_root, rel);
        } catch (const TtsStoreError& e) {
            std::string msg = e.what();
            int status = sa_core::str::starts_with(msg, "文件不存在") ? 404 : 400;
            return Resp::Json(status, json{{"error", msg}});
        }
        std::string ext = sa_core::str::lower(p4::split_ext(rel).second);
        if (!ext.empty() && ext.front() == '.') ext = ext.substr(1);
        if (ext.empty()) ext = "wav";
        json out;
        out["path"] = rel;
        out["ext"] = ext;
        out["audio"] = b64_str(blob);
        return Resp::Json(200, std::move(out));
    });

    // GET /api/tts/list.
    r.get(R"(/api/tts/list)", [](const Req&) -> Resp {
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        try {
            return Resp::Json(200, json{{"items", tts_store::list_materials(mod_root)}});
        } catch (const TtsStoreError& e) {
            return tts_store_error(e);
        }
    });

    // POST /api/tts/delete {path}.
    r.post(R"(/api/tts/delete)", [](const Req& req) -> Resp {
        std::string rel = body_str(req.body, "path");
        if (rel.empty()) return Resp::Json(400, json{{"error", "path required"}});
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        try {
            tts_store::delete_material(mod_root, rel);
        } catch (const TtsStoreError& e) {
            std::string msg = e.what();
            int status = sa_core::str::starts_with(msg, "文件不存在") ? 404 : 400;
            return Resp::Json(status, json{{"error", msg}});
        }
        return Resp::Json(200, json{{"ok", true}, {"path", rel}});
    });
}

}  // namespace sa
