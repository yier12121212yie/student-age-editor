// server/services/mod_refs_routes.cpp — 见 mod_refs_routes.h。
//
// 设计（与用户确认的形态）：自托管网页端的大贴图/配乐/视频**留在 COS，只存
// 引用**。浏览器走模块 A 的 upload/request + PUT 直传（不 complete、不落盘），
// add_ref 把记录钉成 linked（永久引用，免遭 pending 清理），模组目录只维护一份
// cos_resources.json 索引；游戏/分发消费发生在导出时：export_staged 流式拼接
// 「本地盘文件 + 从 COS 拉回的引用资源」为 store-only zip，产物登记进模块 A
// （archived），客户端经 /api/v1/files/:id/download 预热拿直链、带进度下载。
//
// 小文件仍走 /api/mod/import_files（base64 落盘），两种来源在导出里天然合并
// ——这就是「从 COS 和本地拼接 zip」。
#include "mod_refs_routes.h"

#include <atomic>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include "p3b_fs_tools.h"  // p3b::ext_of
#include "p4_util.h"       // p4::split_ext
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "server/api_router.h"    // invalidate_preview_cache
#include "server/cfg_cache.h"     // invalidate_mod_cfgs_cache
#include "server/services/file_transfer.h"
#include "server/services/zip_store_writer.h"
#include "server/state.h"  // STATE, list_mods, cfg_dir, truthy
#include "tts.h"           // tts_store::register_audio_cfg_url

namespace sa {
namespace {

namespace cs = sa_core::paths;

// ---- 与 mod_files_routes.cpp 同款小工具（独立 TU 自带一份） ----------------

bool is_image_ext(const std::string& ext) {
    static const std::vector<std::string> kExts = {"png", "jpg", "jpeg", "webp", "bmp"};
    for (const auto& e : kExts)
        if (e == ext) return true;
    return false;
}
bool is_audio_ext(const std::string& ext) {
    static const std::vector<std::string> kExts = {"wav", "mp3", "ogg", "m4a"};
    for (const auto& e : kExts)
        if (e == ext) return true;
    return false;
}
bool is_video_ext(const std::string& ext) {
    static const std::vector<std::string> kExts = {"mp4", "webm", "mov", "mkv"};
    for (const auto& e : kExts)
        if (e == ext) return true;
    return false;
}

bool is_forbidden_char(unsigned char c) {
    switch (c) {
        case '<': case '>': case ':': case '"': case '|': case '?': case '*':
        case '/': case '\\':
            return true;
        default:
            return false;
    }
}

std::string sanitize_name(const std::string& raw) {
    size_t sep = raw.find_last_of("/\\");
    std::string s = sep == std::string::npos ? raw : raw.substr(sep + 1);
    std::string out;
    for (unsigned char c : s) {
        if (c < 0x20 || c == 0x7F) continue;
        if (is_forbidden_char(c)) continue;
        out.push_back(static_cast<char>(c));
    }
    size_t b = out.find_first_not_of(" \t\n\r\f\v");
    if (b == std::string::npos) return {};
    size_t e = out.find_last_not_of(" \t\n\r\f\v");
    out = out.substr(b, e - b + 1);
    while (!out.empty() && out.back() == '.') out.pop_back();
    return out;
}

bool valid_single_dir(const std::string& dir) {
    if (dir.empty()) return false;
    if (dir == "." || dir == "..") return false;
    for (unsigned char c : dir) {
        if (c == '/' || c == '\\' || c == ':') return false;
        if (c < 0x20 || c == 0x7F) return false;
        if (is_forbidden_char(c)) return false;
    }
    return true;
}

bool str_field(const json& obj, const char* key, std::string& out) {
    if (!obj.is_object()) return false;
    auto it = obj.find(key);
    if (it == obj.end() || !it->is_string()) return false;
    out = it->get<std::string>();
    return true;
}

std::string body_str(const json& body, const char* key) {
    std::string s;
    str_field(body, key, s);
    return s;
}

Resp err_json(int status, const std::string& msg) {
    return Resp::Json(status, json{{"error", msg}});
}

// ---- cos_resources.json 索引 ----------------------------------------------

constexpr const char* kCosIndexFile = "cos_resources.json";

json load_cos_index(const std::string& mod_root) {
    json idx = json::object();
    auto raw = cs::read_bytes(cs::join(mod_root, kCosIndexFile));
    if (raw) {
        json parsed = json::parse(*raw, nullptr, false);
        if (parsed.is_object() && parsed.contains("refs") && parsed["refs"].is_object()) {
            parsed["v"] = 1;
            return parsed;
        }
    }
    idx["v"] = 1;
    idx["refs"] = json::object();
    return idx;
}

bool save_cos_index(const std::string& mod_root, const json& idx) {
    return cs::write_bytes_simple(cs::join(mod_root, kCosIndexFile),
                                  sa_core::py_dumps_indent(idx));
}

std::string current_mod_root() {
    std::lock_guard<std::mutex> lk(STATE().mu_);
    return STATE().mod_root;
}

std::string next_tmp_stem(const char* tag) {
    static std::atomic<unsigned long long> seq{0};
    return std::string("editor_") + tag + "_" + std::to_string(sa_core::now_ms()) + "_" +
           std::to_string(seq.fetch_add(1));
}

}  // namespace

// ---------------------------------------------------------------------------
// POST /api/mods/add_ref {file_id, name, dir?, register_audio?}
// ---------------------------------------------------------------------------
static Resp add_ref(const Req& req) {
    const std::string root = current_mod_root();
    if (root.empty()) return err_json(400, "未选择模组");
    if (!req.body.is_object() || req.body.contains("_raw"))
        return err_json(400, "请求体必须是 JSON 对象");
    const json& body = req.body;

    const std::string file_id = body_str(body, "file_id");
    if (file_id.empty()) return err_json(400, "file_id required");
    const json rec = file_transfer::find_record(editor_root(), file_id);
    if (!rec.is_object()) return err_json(404, "no such file: " + file_id);

    std::string orig;
    if (!str_field(body, "name", orig)) return err_json(400, "name required");
    const std::string safe = sanitize_name(orig);
    if (safe.empty()) return err_json(400, "文件名非法或为空");

    const std::string ext_with_dot = p3b::ext_of(safe);
    const std::string ext = ext_with_dot.empty() ? std::string() : ext_with_dot.substr(1);
    std::string dir_given;
    const bool has_dir = str_field(body, "dir", dir_given);
    std::string dir;
    bool audio = is_audio_ext(ext);
    if (has_dir && !dir_given.empty()) {
        size_t b = dir_given.find_first_not_of(" \t\n\r\f\v");
        size_t e = dir_given.find_last_not_of(" \t\n\r\f\v");
        std::string d = b == std::string::npos ? std::string() : dir_given.substr(b, e - b + 1);
        if (!valid_single_dir(d))
            return err_json(400, "dir 需为单层目录名（不得含路径分隔符、盘符或 ..）");
        dir = d;
    } else if (is_image_ext(ext)) {
        dir = "Textures";
    } else if (audio) {
        dir = "Audios";
    } else if (is_video_ext(ext)) {
        dir = "Videos";
    } else {
        return err_json(400, "未知扩展名，需显式 dir");
    }

    // 重名不覆盖：磁盘真文件与索引已有 rel 都要避让（与 import_files 同款递增）。
    json idx = load_cos_index(root);
    json& refs = idx["refs"];
    const auto pr = p4::split_ext(safe);
    std::string candidate = safe;
    int bump = 0;
    const auto taken = [&](const std::string& rel) {
        return cs::is_file(cs::join(root, rel)) || refs.contains(rel);
    };
    while (taken(dir + "/" + candidate)) {
        ++bump;
        candidate = pr.first + "_" + std::to_string(bump) + pr.second;
    }
    const std::string rel = dir + "/" + candidate;

    std::string lerr;
    if (!file_transfer::mark_linked(editor_root(), file_id, &lerr)) {
        // 状态在读取与登记之间被后台归档线程改写（complete 后的竞态）时，
        // 如实回 409 + 当前状态，让前端提示「文件已落盘/不可引用」。
        if (lerr.rfind("status not linkable", 0) == 0) {
            const json cur = file_transfer::find_record(editor_root(), file_id);
            const std::string cur_st =
                cur.is_object() ? cur.value("status", std::string()) : std::string();
            return Resp::Json(409, json{{"error", "文件当前状态不可引用"}, {"status", cur_st}});
        }
        return err_json(500, "标记引用失败: " + lerr);
    }

    long long size = 0;
    if (rec.contains("size") && rec["size"].is_number()) size = rec["size"].get<long long>();

    json entry = json::object();
    entry["file_id"] = file_id;
    entry["size"] = size;
    entry["orig_name"] = orig;
    entry["uploaded_at"] = sa_core::now_ms();
    entry["kind"] = is_image_ext(ext) ? "texture" : (audio ? "audio" : (is_video_ext(ext) ? "video" : "other"));
    refs[rel] = std::move(entry);
    if (!save_cos_index(root, idx)) {
        // 引用没落账就回滚状态？linked 只是标记，重复无害；但必须让调用方知道
        // 这次没成，不能出现「前端以为成功、导出拼不进」的静默不一致。
        return err_json(500, "写入 " + std::string(kCosIndexFile) + " 失败");
    }

    // 可选：音频登记进 AudioCfg（与 import_files 同语义；文件本体在 COS）。
    json audio_id = nullptr;
    json audio_error = nullptr;
    bool registered = false;
    if (body.contains("register_audio") && truthy(body.at("register_audio")) && audio) {
        try {
            audio_id = tts_store::register_audio_cfg_url(cfg_dir(), rel, p4::split_ext(candidate).first);
            registered = true;
        } catch (const TtsStoreError& e) {
            audio_error = std::string("登记 AudioCfg 失败: ") + e.what();
        } catch (const std::exception& e) {
            audio_error = std::string("登记 AudioCfg 失败: ") + e.what();
        }
    }
    if (registered) {
        invalidate_mod_cfgs_cache();
        invalidate_preview_cache();
    }

    json saved_entry = json::object();
    saved_entry["name"] = orig;
    saved_entry["path"] = rel;
    saved_entry["size"] = size;
    saved_entry["cos"] = true;
    saved_entry["file_id"] = file_id;
    saved_entry["audio_id"] = audio_id;
    saved_entry["audio_error"] = audio_error;
    json saved_arr = json::array();
    saved_arr.push_back(std::move(saved_entry));
    return Resp::Json(200, json{{"saved", std::move(saved_arr)},
                                {"errors", json::array()}});
}

// ---------------------------------------------------------------------------
// POST /api/mods/export_staged {name?} —— 流式拼接本地盘 + COS 引用。
// 长任务（分钟级）：经 wrap_async_job 支持 ?async=1（202 job_id + /api/jobs 轮询）。
// ---------------------------------------------------------------------------
static Resp export_staged(const Req& req) {
    std::string name = req.body.is_object() ? body_str(req.body, "name") : std::string();
    std::string root;
    if (name.empty()) {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        name = STATE().mod_name;
        root = STATE().mod_root;
    } else {
        for (const auto& m : list_mods())
            if (m.value("name", "") == name) { root = m.value("root", ""); break; }
    }
    if (name.empty() || root.empty() || !cs::is_dir(root))
        return err_json(400, "mod not found: " + (name.empty() ? std::string("(none)") : name));

    std::vector<zipstore::FileSource> sources;
    std::set<std::string> rels_on_disk;
    const std::filesystem::path base = cs::to_path(root);
    std::error_code ec;
    for (std::filesystem::recursive_directory_iterator it(base, ec), end;
         !ec && it != end; it.increment(ec)) {
        if (it->is_directory(ec)) continue;
        if (!it->is_regular_file(ec)) continue;
        std::error_code rel_ec;
        const auto relp = std::filesystem::relative(it->path(), base, rel_ec);
        if (rel_ec) continue;
        const std::u8string rel_u8 = relp.generic_u8string();
        const std::string relname(reinterpret_cast<const char*>(rel_u8.data()), rel_u8.size());
        if (relname.rfind(".editor_history/", 0) == 0) continue;
        if (relname == kCosIndexFile) continue;  // 索引是服务器侧账本，不进分发包
        rels_on_disk.insert(relname);
        zipstore::FileSource src;
        src.name = relname;
        src.path = cs::path_to_utf8(it->path());
        sources.push_back(std::move(src));
    }

    // 引用资源：经内网拉回临时文件。磁盘上已有同名真文件（例如导入的完整包）
    // 时磁盘优先，跳过该引用。
    const std::filesystem::path tmp_dir = std::filesystem::temp_directory_path();
    std::vector<std::filesystem::path> tmp_files;
    auto drop_tmp = [&tmp_files]() {
        for (const auto& p : tmp_files) {
            std::error_code tec;
            std::filesystem::remove(p, tec);
        }
    };

    const json idx = load_cos_index(root);
    if (idx.contains("refs") && idx["refs"].is_object()) {
        for (auto it = idx["refs"].begin(); it != idx["refs"].end(); ++it) {
            const std::string rel = it.key();
            if (rels_on_disk.count(rel)) continue;
            const json& ref = it.value();
            const std::string file_id = ref.is_object() ? ref.value("file_id", std::string()) : std::string();
            if (file_id.empty()) continue;
            std::filesystem::path dst = tmp_dir / cs::to_path(next_tmp_stem("mat"));
            std::string merr;
            if (!file_transfer::materialize(editor_root(), file_id, cs::path_to_utf8(dst), &merr)) {
                drop_tmp();
                return err_json(500, "引用资源拉取失败 " + rel + ": " + merr);
            }
            tmp_files.push_back(dst);
            zipstore::FileSource src;
            src.name = rel;
            src.path = cs::path_to_utf8(dst);
            sources.push_back(std::move(src));
        }
    }

    if (sources.empty()) return err_json(400, "mod is empty: " + name);

    const std::filesystem::path zip_path = tmp_dir / cs::to_path(next_tmp_stem("modexp") + ".zip");
    long long total = 0;
    std::string zerr;
    if (!zipstore::build_to_file(sources, cs::path_to_utf8(zip_path), total, zerr)) {
        drop_tmp();
        const bool oversize =
            zerr.find("too many") != std::string::npos || zerr.find("4 GiB") != std::string::npos ||
            zerr.find("too large") != std::string::npos;
        return err_json(oversize ? 413 : 500, "打包失败: " + zerr);
    }
    drop_tmp();

    const std::string filename = name + ".zip";
    const std::string file_id = file_transfer::register_local_artifact(editor_root(), filename,
                                                                       cs::path_to_utf8(zip_path), total);
    if (file_id.empty()) {
        std::error_code rec;
        std::filesystem::remove(zip_path, rec);
        return err_json(500, "cannot register export artifact");
    }

    json out = json::object();
    out["file_id"] = file_id;
    out["filename"] = filename;
    out["size"] = total;
    out["entries"] = static_cast<long long>(sources.size());
    out["ref_count"] = static_cast<long long>(
        idx.contains("refs") && idx["refs"].is_object() ? idx["refs"].size() : 0);
    return Resp::Json(200, std::move(out));
}

void register_mod_refs_routes(Router& r) {
    r.post(R"(/api/mods/add_ref)", [](const Req& req) -> Resp { return add_ref(req); });
    r.post(R"(/api/mods/export_staged)",
           wrap_async_job([](const Req& req) -> Resp { return export_staged(req); }));
}

}  // namespace sa
