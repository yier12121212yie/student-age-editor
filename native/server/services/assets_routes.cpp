// server/services/assets_routes.cpp — /api/assets/{catalog,tags}（见 .h 的设计说明）。
//
// 契约（additive，前端 asset_explorer_panel 消费）：
//
//   GET /api/assets/tags
//     {status, total, sources, tags:[...], counts:{tag:n}}
//     total   = 全量资源条数；counts 也是全量口径（不受 catalog 分页影响）
//     tags    = base_types() 固定顺序在前，其余字典序
//
//   GET /api/assets/catalog?q=&tags=a,b&kind=&limit=&offset=
//     {status, total, matched, returned, truncated, sources, counts,
//      resources_by_kind:{sprite:[...],texture:[...],audio:[...]}}
//     total    = 全量资源条数（未过滤）
//     matched  = 过滤后条数（分页前）；truncated = matched > returned
//     counts   = 全量 per-kind 计数（未过滤）
//     行 = {key, original_name, kind, width, height, sha24, tags}
//       kind   : sprite（tex 且规则判为 role）| texture | audio
//       sha24  : sha256(kind + ":" + key) 前 24 位十六进制（稳定行 id）
//       width/height : texmeta 有值才非 0（稀疏语义，见 ARTIFACT_FORMAT §8.4）
//     过滤：q 对 key 大小写不敏感子串；tags 逗号分隔、命中任一即保留；
//           kind 非法值 -> 400 {"error":"bad kind"}；limit 默认 500 / 上限 5000
#include "assets_routes.h"

#include <algorithm>
#include <array>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "sa_core/sha256.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "aa.h"
#include "tag_service.h"

namespace sa {
namespace {

const char* const kKinds[] = {"sprite", "texture", "audio"};

std::string qget(const Req& req, const std::string& key, const std::string& def = "") {
    auto it = req.query.find(key);
    return it == req.query.end() ? def : it->second;
}

// 外部输入安全解析（对齐 /api/aa/keys 的 sa_core::py_int 用法）：非法/缺省回 def，
// 并夹到 [lo, hi]，绝不因为一个坏 query 回 500。
long long qget_int(const Req& req, const std::string& key, long long def, long long lo,
                   long long hi) {
    auto v = sa_core::py_int(qget(req, key, ""));
    if (!v.has_value()) return def;
    return std::max(lo, std::min(hi, *v));
}

// "a, b,,c" -> ["a","b","c"]（trim + 小写 + 去重，保持出现顺序）。
std::vector<std::string> split_csv(const std::string& raw) {
    std::vector<std::string> out;
    std::string cur;
    auto flush = [&]() {
        const std::string t = sa_core::str::lower(sa_core::str::trim(cur));
        cur.clear();
        if (t.empty()) return;
        if (std::find(out.begin(), out.end(), t) == out.end()) out.push_back(t);
    };
    for (char c : raw) {
        if (c == ',') {
            flush();
        } else {
            cur.push_back(c);
        }
    }
    flush();
    return out;
}

struct AssetRow {
    std::string key;
    std::string kind;
    std::string sha24;
    long long width = 0;
    long long height = 0;
    std::vector<std::string> tags;
};

// tex 的 sprite/texture 分桶直接复用标签规则表的第一条命中：命中 role 词元
// （bundle 路径里的 role/character/... 或键本身）即立绘，否则按贴图/CG。
AssetRow make_row(const TagService& svc, const std::string& section, const std::string& key,
                  const std::string& location) {
    AssetRow row;
    row.key = key;
    row.tags = svc.tags_for(section, key, location);
    if (section == "aud") {
        row.kind = "audio";
    } else {
        row.kind = (!row.tags.empty() && row.tags.front() == "role") ? "sprite" : "texture";
    }
    row.sha24 = sa_core::sha256_hex(row.kind + ":" + key).substr(0, 24);
    return row;
}

void add_row(std::map<std::string, AssetRow>& out, AssetRow row, int width, int height) {
    const std::string id = row.kind + '\x1f' + row.key;
    auto it = out.find(id);
    if (it == out.end()) {
        row.width = width;
        row.height = height;
        out.emplace(id, std::move(row));
        return;
    }
    // 索引先落、解码包后落：索引没给尺寸时用包头部读到的尺寸补（反之不动）。
    if (it->second.width <= 0 && width > 0) {
        it->second.width = width;
        it->second.height = height;
    }
}

std::vector<AssetRow> collect() {
    static const TagService svc;
    std::map<std::string, AssetRow> by_id;

    if (auto idx = ensure_aa_index()) {
        for (const std::string& k : idx->tex_keys()) {
            int w = 0, h = 0;
            if (auto m = idx->tex_meta(k)) {
                w = (*m)[0];
                h = (*m)[1];
            }
            add_row(by_id, make_row(svc, "tex", k, idx->tex_bundle(k)), w, h);
        }
        for (const std::string& k : idx->aud_keys())
            add_row(by_id, make_row(svc, "aud", k, idx->aud_bundle(k)), 0, 0);
    }
    if (auto store = ensure_pack_store(); store && store->active()) {
        for (const std::string& k : store->tex_keys()) {
            int w = 0, h = 0;
            if (auto m = store->tex_meta(k)) {
                w = (*m)[0];
                h = (*m)[1];
            }
            add_row(by_id, make_row(svc, "tex", k, std::string()), w, h);
        }
        for (const std::string& k : store->aud_keys())
            add_row(by_id, make_row(svc, "aud", k, std::string()), 0, 0);
    }

    std::vector<AssetRow> rows;
    rows.reserve(by_id.size());
    for (auto& kv : by_id) rows.push_back(std::move(kv.second));
    // 稳定次序（分页前提）：kind 名升序 + key 升序；输出时再按固定桶顺序重排。
    std::sort(rows.begin(), rows.end(), [](const AssetRow& a, const AssetRow& b) {
        if (a.kind != b.kind) return a.kind < b.kind;
        return a.key < b.key;
    });
    return rows;
}

json source_list() {
    json sources = json::array();
    if (ensure_aa_index()) sources.push_back("aa_index");
    auto store = ensure_pack_store();
    if (store && store->active()) sources.push_back("decoded_pack");
    return sources;
}

std::string source_status() { return source_list().empty() ? "idle" : "ready"; }

bool row_matches(const AssetRow& row, const std::string& kind, const std::string& q,
                 const std::vector<std::string>& tags) {
    if (!kind.empty() && row.kind != kind) return false;
    if (!q.empty() && sa_core::str::lower(row.key).find(q) == std::string::npos) return false;
    if (!tags.empty()) {
        bool any = false;
        for (const std::string& t : tags) {
            if (std::find(row.tags.begin(), row.tags.end(), t) != row.tags.end()) {
                any = true;
                break;
            }
        }
        if (!any) return false;
    }
    return true;
}

}  // namespace

void register_assets_routes(Router& r) {
    // GET /api/assets/tags — 标签云（全量口径）。
    r.get(R"(/api/assets/tags)", [](const Req&) -> Resp {
        const std::vector<AssetRow> rows = collect();

        std::map<std::string, long long> counts;
        for (const AssetRow& row : rows)
            for (const std::string& t : row.tags) counts[t] += 1;

        const std::vector<std::string>& base = TagService::base_types();
        std::vector<std::string> ordered;
        for (const std::string& t : base)
            if (counts.count(t) != 0) ordered.push_back(t);
        std::vector<std::string> rest;
        for (const auto& kv : counts)
            if (std::find(base.begin(), base.end(), kv.first) == base.end())
                rest.push_back(kv.first);
        std::sort(rest.begin(), rest.end());
        ordered.insert(ordered.end(), rest.begin(), rest.end());

        json tag_counts = json::object();
        for (const std::string& t : ordered) tag_counts[t] = counts[t];

        json body = json::object();
        body["status"] = source_status();
        body["total"] = static_cast<long long>(rows.size());
        body["sources"] = source_list();
        body["tags"] = ordered;
        body["counts"] = std::move(tag_counts);
        return Resp::Json(200, std::move(body));
    });

    // GET /api/assets/catalog — 资源目录（服务端过滤 + 分页）。
    r.get(R"(/api/assets/catalog)", [](const Req& req) -> Resp {
        const std::string kind = sa_core::str::lower(sa_core::str::trim(qget(req, "kind")));
        if (!kind.empty() && kind != "sprite" && kind != "texture" && kind != "audio")
            return Resp::Json(400, json{{"error", "bad kind"}});
        const std::string q = sa_core::str::lower(sa_core::str::trim(qget(req, "q")));
        const std::vector<std::string> tags = split_csv(qget(req, "tags"));
        const long long limit = qget_int(req, "limit", 500, 0, 5000);
        const long long offset = qget_int(req, "offset", 0, 0, 1000000000LL);

        const std::vector<AssetRow> rows = collect();

        json counts = json::object();
        for (const char* k : kKinds) counts[k] = 0;
        for (const AssetRow& row : rows) counts[row.kind] = counts[row.kind].get<long long>() + 1;

        std::vector<const AssetRow*> matched;
        for (const AssetRow& row : rows)
            if (row_matches(row, kind, q, tags)) matched.push_back(&row);

        json buckets = json::object();
        for (const char* k : kKinds) buckets[k] = json::array();

        long long returned = 0;
        const long long total_matched = static_cast<long long>(matched.size());
        for (long long i = offset; i < total_matched && returned < limit; ++i) {
            const AssetRow& row = *matched[static_cast<std::size_t>(i)];
            json item = json::object();
            item["key"] = row.key;
            item["original_name"] = row.key;
            item["kind"] = row.kind;
            item["width"] = row.width;
            item["height"] = row.height;
            item["sha24"] = row.sha24;
            item["tags"] = row.tags;
            buckets[row.kind].push_back(std::move(item));
            ++returned;
        }

        json body = json::object();
        body["status"] = source_status();
        body["total"] = static_cast<long long>(rows.size());
        body["matched"] = total_matched;
        body["returned"] = returned;
        body["truncated"] = offset + returned < total_matched;
        body["sources"] = source_list();
        body["counts"] = std::move(counts);
        body["resources_by_kind"] = std::move(buckets);
        return Resp::Json(200, std::move(body));
    });
}

}  // namespace sa
