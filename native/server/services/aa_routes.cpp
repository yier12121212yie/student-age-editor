// wip/P4/aa_routes.cpp — /api/aa/{keys,preview,status,export,scan} (port of
// api.py aa_* routes; the C++ never scans bundles nor decodes them).
#include <algorithm>
#include <cctype>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/cfg_cache.h"
#include "server/httpd.h"
#include "server/state.h"
#include "aa.h"
#include "base_store.h"
#include "flow_assets.h"
#include "p4_util.h"

namespace sa {
namespace {

// The `pick` closure in api.py:aa_keys — union of key groups, q-filtered,
// de-duplicated, count-truncated at `limit`.
std::vector<std::string> pick_keys(const std::vector<std::vector<std::string>>& groups,
                                   const std::string& q, long long limit) {
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (const auto& keys : groups) {
        bool stop = false;
        for (const auto& k : keys) {
            if (!seen.insert(k).second) continue;
            if (!q.empty() && sa_core::str::lower(k).find(q) == std::string::npos) continue;
            out.push_back(k);
            if (static_cast<long long>(out.size()) >= limit) { stop = true; break; }
        }
        if (stop) break;
    }
    return out;
}

std::string qget(const Req& req, const std::string& key, const std::string& def = "") {
    auto it = req.query.find(key);
    return it == req.query.end() ? def : it->second;
}

// ---- kind=txt: decoded-pack Cfgs/zh-cn fallback (wave-2 integration) ------
// File naming per export_decoded_pack.py: core tables land as "<TableName>.json",
// the ~300 non-core game texts as _safe_name(norm key).json. Resolve
// case-insensitively over the lowercased stem map. 多 base：按启用顺序逐包查找，
// 靠前的包优先（首个命中即返回）。
std::optional<std::string> read_pack_txt_one(const std::string& dir, const std::string& key) {
    namespace ps = sa_core::paths;
    static std::mutex mu;
    static std::map<std::string, std::map<std::string, std::string>> stems_by_dir;
    static std::set<std::string> loaded;
    const std::string cfgs_dir = ps::join(ps::join(dir, "Cfgs"), "zh-cn");
    std::string fname;
    {
        std::lock_guard<std::mutex> lk(mu);
        auto& stems = stems_by_dir[dir];
        if (!loaded.count(dir)) {
            loaded.insert(dir);
            for (const auto& f : ps::listdir_sorted(cfgs_dir)) {
                if (f.size() > 5 && sa_core::str::lower(f.substr(f.size() - 5)) == ".json")
                    stems[sa_core::str::lower(f.substr(0, f.size() - 5))] = f;
            }
        }
        std::string probe = sa_core::str::lower(sa::norm_key(key));
        for (char& c : probe) {
            unsigned char u = static_cast<unsigned char>(c);
            if (!(std::isalnum(u) || c == '.' || c == '_' || c == '-')) c = '_';  // _safe_name
        }
        auto it = stems.find(probe);
        if (it == stems.end()) it = stems.find(sa_core::str::lower(key));
        if (it == stems.end()) return std::nullopt;
        fname = it->second;
    }
    return ps::read_bytes(ps::join(cfgs_dir, fname));
}

std::optional<std::string> read_pack_txt(const std::string& key) {
    for (const auto& dir : sa::active_pack_dirs()) {
        if (auto raw = read_pack_txt_one(dir, key)) return raw;
    }
    return std::nullopt;
}

// preview payload: utf-8 errors=replace decode + 200 000 codepoint slice
// (api.py:2371-2380 — len() is codepoints; 200K truncation + flag).
json txt_preview_payload(const std::string& raw) {
    std::string text = sa_core::decode_utf8_sig_replace(raw);
    size_t cp = 0, i = 0;
    const size_t n = text.size();
    while (i < n && cp < 200000) {
        unsigned char lead = static_cast<unsigned char>(text[i]);
        size_t len = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
        if (i + len > n) len = n - i;
        i += len;
        ++cp;
    }
    return json{{"kind", "txt"}, {"text", text.substr(0, i)},
                {"truncated", i < n}};
}

// GET 二进制图片直发的共用逻辑：优先走 [fetch_tex_raw]（模组本地资源优先），
// 404/422 时若索引与资源扩展均未配置，回旧接口语义的 400 not ready。
Resp serve_tex_raw_checked(const Req& req, const std::string& key) {
    Resp raw = fetch_tex_raw(key, req.if_none_match_header);
    if (raw.status == 200 || raw.status == 302 || raw.status == 304) return raw;
    auto idx = ensure_aa_index();
    auto store = ensure_pack_store();
    bool store_active = store && store->active();
    if (!idx && !store_active && !portrait_source_configured() &&
        !background_source_configured())
        return Resp::Json(400, json{{"error", "index not ready"}});
    return raw;
}

}  // namespace

void register_aa_routes(Router& r) {
    // GET /api/aa/status — api.py:2081-2092.
    r.get(R"(/api/aa/status)", [](const Req&) -> Resp {
        auto store = ensure_pack_store();
        json bundled = nullptr;
        std::string pid, pname;
        if (store && store->active()) {
            std::tie(pid, pname) = pack_active_info();
            bundled = json{{"active", pid},
                           {"name", pname},
                           {"tex", store->tex_count()},
                           {"aud", store->aud_count()}};
        }
        std::string status, error;
        json dirs = json::array();
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            status = STATE().aa_status;
            error = STATE().aa_error;
            for (const auto& d : STATE().aa_dirs) dirs.push_back(d);
        }
        auto pstore = portrait_local_store();
        auto bstore = background_local_store();
        if (status == "idle" && ((pstore && pstore->active()) || (bstore && bstore->active()))) {
            status = "ready";
        }
        json body;
        body["status"] = status;
        body["dirs"] = std::move(dirs);
        body["error"] = error;
        body["detected"] = sa_core::steam_paths::detect_game_aa_dir();
        body["bundled"] = std::move(bundled);
        return Resp::Json(200, std::move(body));
    });

    // POST /api/aa/scan — C++ never scans bundles (migration decision #3).
    // scan == "re-read the generated artifact" (aa_index.json produced by
    // tools/resource_scan under <data_root>/_cache/aa_index/), then mirrors
    // api.py:2098-2099's success shape {"status": ...}. Missing/unloadable
    // artifact keeps the guiding-error shape of Python's no-UnityPy branch
    // (api.py:2096-2097).
    r.post(R"(/api/aa/scan)", [](const Req&) -> Resp {
        reset_aa_singletons_for_test();  // force re-read of the probed locations
        auto idx = ensure_aa_index();
        if (!idx) {
            std::string tried;
            for (const auto& p : aa_index_candidate_paths()) {
                tried += "\n  - ";
                tried += p;
            }
            return Resp::Json(500, json{{"error", "unityfs unavailable"},
                                        {"detail",
                                         "未找到可用的游戏资源索引 aa_index.json（已搜索：" +
                                             tried + "）。\n"
                                             "请在装有《学生时代》的机器上启动一次编辑器生成缓存，"
                                             "或用 `py -m resource_scan index --aa <游戏 "
                                             "StreamingAssets\\aa 目录> --out "
                                             "<编辑器根>\\_cache\\aa_index` 生成后重试。"}});
        }
        std::lock_guard<std::mutex> lk(STATE().mu_);
        return Resp::Json(200, json{{"status", STATE().aa_status}});
    });

    // GET /api/aa/keys — api.py:2125-2243.
    r.get(R"(/api/aa/keys)", [](const Req& req) -> Resp {
        auto idx = ensure_aa_index();
        auto store = ensure_pack_store();
        std::string q = sa_core::str::lower(p4::strip(qget(req, "q", "")));
        long long limit = sa_core::py_int(qget(req, "limit", "500")).value_or(500);
        std::string scope = sa_core::str::lower(p4::strip(qget(req, "scope", "")));
        bool store_active = store && store->active();
        auto pstore = portrait_local_store();
        auto bstore = background_local_store();
        bool pstore_active = pstore && pstore->active();
        bool bstore_active = bstore && bstore->active();

        std::vector<std::string> itex, iaud, itxt, stex, saud, stxt;
        if (idx) { itex = idx->tex_keys(); iaud = idx->aud_keys(); itxt = idx->txt_keys(); }
        if (store_active) { stex = store->tex_keys(); saud = store->aud_keys(); stxt = store->txt_keys(); }

        std::string status;
        if (idx || store_active || pstore_active || bstore_active) {
            status = "ready";
        } else {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            status = STATE().aa_status;
        }

        if (scope == "flow") {
            // BGM signal: base + mod AudioCfg type==1 url basenames.
            json audio_rows = json::object();
            auto base_audio = sa::base_store()->table("AudioCfg");
            if (base_audio && base_audio->is_object())
                for (auto it = base_audio->begin(); it != base_audio->end(); ++it)
                    audio_rows[it.key()] = it.value();
            try {
                auto view = load_mod_cfgs();
                auto it = view.tables.find("AudioCfg");
                if (it != view.tables.end() && it->second && it->second->is_object())
                    for (auto kt = it->second->begin(); kt != it->second->end(); ++kt)
                        audio_rows[kt.key()] = kt.value();
            } catch (...) {}
            auto music_urls = flow::music_url_basenames(audio_rows);

            bool tex_filterable = (idx && idx->has_texmeta()) || store_active || pstore_active || bstore_active;

            using BundleFn = std::function<std::string(const std::string&)>;
            using SizeFn = std::function<std::optional<std::array<int, 2>>(const std::string&)>;
            struct Group { std::vector<std::string> keys; BundleFn bundle; SizeFn size; };
            std::vector<Group> tex_groups;
            if (idx)
                tex_groups.push_back({itex, [&](const std::string& k) { return idx->tex_bundle(k); },
                                      [&](const std::string& k) { return idx->tex_meta(k); }});
            if (store_active)
                tex_groups.push_back({stex, [&](const std::string& k) { return store->tex_path(k); },
                                      [&](const std::string& k) { return store->tex_meta(k); }});
            if (bstore_active) {
                auto bkeys = bstore->tex_keys();
                tex_groups.push_back({bkeys, [&](const std::string& k) { return bstore->tex_path(k); },
                                      [&](const std::string& k) { return bstore->tex_meta(k); }});
            }
            if (pstore_active) {
                auto pkeys = pstore->tex_keys();
                tex_groups.push_back({pkeys, [&](const std::string& k) { return pstore->tex_path(k); },
                                      [&](const std::string& k) { return pstore->tex_meta(k); }});
            }
            std::vector<Group> aud_groups;
            if (idx)
                aud_groups.push_back({iaud, [&](const std::string& k) { return idx->aud_bundle(k); }, nullptr});
            if (store_active) aud_groups.push_back({saud, nullptr, nullptr});

            auto flow_pick = [&](std::vector<Group>& groups,
                                 const std::function<bool(const std::string&, const std::string&,
                                                          std::optional<std::array<int, 2>>)>& keep) {
                std::vector<std::string> out;
                std::set<std::string> seen;
                for (auto& g : groups) {
                    bool stop = false;
                    for (const auto& k : g.keys) {
                        if (!seen.insert(k).second) continue;
                        if (!q.empty() && sa_core::str::lower(k).find(q) == std::string::npos) continue;
                        std::optional<std::array<int, 2>> sz = g.size ? g.size(k) : std::nullopt;
                        std::string b = g.bundle ? g.bundle(k) : "";
                        if (keep(k, b, sz)) {
                            out.push_back(k);
                            if (static_cast<long long>(out.size()) >= limit) { stop = true; break; }
                        }
                    }
                    if (stop) break;
                }
                return out;
            };

            auto tex = flow_pick(tex_groups,
                                 [&](const std::string& k, const std::string& b,
                                     std::optional<std::array<int, 2>> s) {
                                     if (!tex_filterable) return true;
                                     int w = s ? (*s)[0] : 0, h = s ? (*s)[1] : 0;
                                     return flow::is_cg_image(k, b, w, h);
                                 });
            bool tex_had_source = false;
            for (auto& g : tex_groups)
                if (!g.keys.empty()) tex_had_source = true;
            if (tex.empty() && tex_had_source && q.empty()) {
                tex_filterable = false;
                tex = flow_pick(tex_groups,
                                [](const std::string&, const std::string&,
                                   std::optional<std::array<int, 2>>) { return true; });
            }
            bool music_filterable = (idx != nullptr) || !music_urls.empty();
            auto aud = flow_pick(aud_groups,
                                 [&](const std::string& k, const std::string& b,
                                     std::optional<std::array<int, 2>>) {
                                     if (!music_filterable) return true;
                                     return flow::is_music(k, b, music_urls);
                                 });
            json meta = json::object();
            if (tex_filterable) {
                // A14: {key -> size_fn} index (avoid the O(n^2) linear probe).
                std::map<std::string, SizeFn> fn_for;
                for (auto& g : tex_groups)
                    if (g.size) for (const auto& k : g.keys) fn_for.emplace(k, g.size);
                for (const auto& k : tex) {
                    auto it = fn_for.find(k);
                    if (it == fn_for.end()) continue;
                    auto s = it->second(k);
                    if (s) meta[k] = json::array({(*s)[0], (*s)[1]});
                }
            }
            json body;
            body["status"] = status;
            body["tex"] = std::move(tex);
            body["aud"] = std::move(aud);
            body["txt"] = pick_keys({itxt, stxt}, q, limit);
            body["meta"] = std::move(meta);
            body["flow_filtered"] = tex_filterable;
            return Resp::Json(200, std::move(body));
        }

        std::vector<std::vector<std::string>> tex_sources;
        if (!itex.empty()) tex_sources.push_back(itex);
        if (!stex.empty()) tex_sources.push_back(stex);
        if (bstore_active) tex_sources.push_back(bstore->tex_keys());
        if (pstore_active) tex_sources.push_back(pstore->tex_keys());

        json body;
        body["status"] = status;
        body["tex"] = pick_keys(tex_sources, q, limit);
        body["aud"] = pick_keys({iaud, saud}, q, limit);
        body["txt"] = pick_keys({itxt, stxt}, q, limit);
        return Resp::Json(200, std::move(body));
    });

    // POST /api/aa/export — api.py:2245-2305 (decoded-pack copy only; game-bundle
    // objects cannot be decoded in C++).
    r.post(R"(/api/aa/export)", [](const Req& req) -> Resp {
        auto idx = ensure_aa_index();
        auto store = ensure_pack_store();
        bool store_active = store && store->active();
        if (!idx && !store_active) return Resp::Json(400, json{{"error", "index not ready"}});
        const json& body = req.body;
        std::string kind = body.is_object() && body.contains("kind") ? sa_core::py_str(body.at("kind")) : "";
        std::string key = body.is_object() && body.contains("key") ? sa_core::py_str(body.at("key")) : "";
        std::string out_rel = body.is_object() && body.contains("out") ? sa_core::py_str(body.at("out")) : "";
        if (kind.empty() || key.empty()) return Resp::Json(400, json{{"error", "kind/key required"}});
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (mod_root.empty()) return Resp::Json(400, json{{"error", "no mod selected"}});
        std::string out_abs;
        try {
            out_abs = p4::fs_resolve(mod_root, out_rel);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
        auto write_copy = [&](const std::string& data) {
            sa_core::paths::create_dirs(sa_core::paths::dirname(out_abs));
            return sa_core::paths::write_bytes_simple(out_abs, data);
        };
        if (kind == "tex") {
            if (store_active) {
                if (auto r = store->read_file(store->tex_path(key))) {
                    if (write_copy(r->first)) return Resp::Json(200, json{{"ok", true}, {"out", out_rel}});
                }
            }
            if (idx && idx->has_tex(key))
                return Resp::Json(422, json{{"error", "texture decode failed: " + key}});
            return Resp::Json(404, json{{"error", "texture key not found: " + key}});
        }
        if (kind == "aud") {
            if (store_active) {
                if (auto r = store->read_file(store->aud_path(key))) {
                    if (write_copy(r->first)) return Resp::Json(200, json{{"ok", true}, {"out", out_rel}});
                }
            }
            if (idx && idx->has_aud(key))
                return Resp::Json(422, json{{"error", "audio decode failed: " + key}});
            return Resp::Json(404, json{{"error", "audio key not found: " + key}});
        }
        if (kind == "txt") {
            // export：解码包文本原样落盘（无 preview 的 200K 截断）。
            if (auto raw = read_pack_txt(key)) {
                if (write_copy(*raw)) return Resp::Json(200, json{{"ok", true}, {"out", out_rel}});
            }
            if (idx && idx->has_txt(key))
                return Resp::Json(422, json{{"error", "text decode failed: " + key}});
            return Resp::Json(404, json{{"error", "text key not found: " + key}});
        }
        return Resp::Json(400, json{{"error", "bad kind"}});
    });

    // POST /api/aa/preview — api.py:2307-2382.
    r.post(R"(/api/aa/preview)", [](const Req& req) -> Resp {
        const json& body = req.body;
        std::string kind = body.is_object() && body.contains("kind") ? sa_core::py_str(body.at("kind")) : "";
        std::string key = body.is_object() && body.contains("key") ? sa_core::py_str(body.at("key")) : "";
        if (kind.empty() || key.empty()) return Resp::Json(400, json{{"error", "kind/key required"}});
        using sa_core::http::b64_encode;

        auto idx = ensure_aa_index();
        auto store = ensure_pack_store();
        bool store_active = store && store->active();
        if (!idx && !store_active && !portrait_source_configured() &&
            !background_source_configured())
            return Resp::Json(400, json{{"error", "index not ready"}});

        if (kind == "tex") {
            // 复用二进制缓存的解析顺序（模组 -> 解码包 -> 人物 -> 背景）取字节，
            // 再按旧接口封装成 Base64 JSON：旧消费方零改动 + 内存缓存加速。
            Resp raw = fetch_tex_raw(key, "");
            if (raw.status == 200)
                return Resp::Json(200, json{{"kind", "tex"},
                                            {"mime", raw.content_type},
                                            {"data", b64_encode(raw.bytes)}});
            if (raw.status == 302)
                return Resp::Json(200, json{{"kind", "tex"},
                                            {"mime", "image/webp"},
                                            {"url", raw.location}});
            return raw;  // 404 / 422 错误信封原样返回
        }
        if (kind == "aud") {
            bool found = idx && idx->has_aud(key);
            if (store_active) {
                if (auto r = store->read_file(store->aud_path(key)))
                    return Resp::Json(200, json{{"kind", "aud"},
                                                {"mime", aud_mime(r->second)},
                                                {"ext", r->second},
                                                {"data", b64_encode(r->first)}});
            }
            if (found) return Resp::Json(422, json{{"error", "audio decode failed: " + key}});
            return Resp::Json(404, json{{"error", "audio key not found: " + key}});
        }
        if (kind == "txt") {
            if (auto raw = read_pack_txt(key))
                return Resp::Json(200, txt_preview_payload(*raw));
            if (idx && idx->has_txt(key))
                // key 在索引但 pack 无文件（全量解码包未铺满时的合法形态）。
                return Resp::Json(422, json{{"error", "text decode failed: " + key}});
            return Resp::Json(404, json{{"error", "text key not found: " + key}});
        }
        return Resp::Json(400, json{{"error", "bad kind"}});
    });

    // GET /api/aa/tex?key=... — 二进制直发（等价 raw?kind=tex）。返回原始字节流
    // （Content-Type: image/...）+ ETag/Cache-Control，命中 If-None-Match 回 304。
    r.get(R"(/api/aa/tex)", [](const Req& req) -> Resp {
        std::string key = qget(req, "key", "");
        if (key.empty()) return Resp::Json(400, json{{"error", "key required"}});
        return serve_tex_raw_checked(req, key);
    });

    // GET /api/aa/raw?kind=tex&key=... — 二进制直发（tex/aud/txt）。tex 走内存
    // LRU 缓存与 ETag/304 协商；对象存储回 302 Location；aud/txt 直出原始字节。
    r.get(R"(/api/aa/raw)", [](const Req& req) -> Resp {
        std::string kind = sa_core::str::lower(p4::strip(qget(req, "kind", "tex")));
        if (kind.empty()) kind = "tex";
        std::string key = qget(req, "key", "");
        if (key.empty()) return Resp::Json(400, json{{"error", "key required"}});
        if (kind == "tex") return serve_tex_raw_checked(req, key);
        if (kind == "aud") {
            Resp raw = fetch_aud_raw(key, req.if_none_match_header);
            if (raw.status == 200 || raw.status == 304) return raw;
            auto idx = ensure_aa_index();
            auto store = ensure_pack_store();
            if (!idx && !(store && store->active()))
                return Resp::Json(400, json{{"error", "index not ready"}});
            return raw;
        }
        if (kind == "txt") {
            if (auto raw = read_pack_txt(key))
                return Resp::BytesTyped(200, sa_core::decode_utf8_sig_replace(*raw),
                                        "text/plain; charset=utf-8");
            auto idx = ensure_aa_index();
            if (idx && idx->has_txt(key))
                return Resp::Json(422, json{{"error", "text decode failed: " + key}});
            return Resp::Json(404, json{{"error", "text key not found: " + key}});
        }
        return Resp::Json(400, json{{"error", "bad kind"}});
    });
}

}  // namespace sa
