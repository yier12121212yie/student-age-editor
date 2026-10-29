#include "semantic_linter.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/services/semantic_assets.h"
#include "server/services/semantic_logic.h"
#include "server/services/stores_api.h"
#include "server/state.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;
namespace str = sa_core::str;

std::string try_cfg_path(const std::string& cfg) {
    std::string root;
    {
        std::lock_guard<std::mutex> lock(STATE().mu_);
        root = STATE().mod_root;
    }
    if (root.empty()) return {};
    return cs::join(cs::join(root, "Cfgs"), cfg + ".json");
}

std::optional<json> read_table(const std::string& cfg_name) {
    std::string path = try_cfg_path(cfg_name);
    if (path.empty() || !cs::is_file(path)) return std::nullopt;
    auto rl = cfg_store::read_lossy(path);
    if (!rl.text) return std::nullopt;
    std::string content = str::trim(*rl.text);
    if (content.empty()) return json::object();
    json data = json::parse(content, nullptr, false);
    if (data.is_discarded() || !data.is_object()) return std::nullopt;
    return data;
}

bool save_table(const std::string& cfg_name, const json& data) {
    std::string path = try_cfg_path(cfg_name);
    if (path.empty()) return false;
    json res = cfg_store::write_cfg(path, data, std::nullopt, nullptr, false, true);
    return res.value("ok", false);
}

std::set<std::string> collect_known_person_ids() {
    std::set<std::string> ids = {"0", "00", "000", "-1"};
    auto opt = read_table("PersonCfg");
    if (opt && opt->is_object()) {
        for (auto it = opt->begin(); it != opt->end(); ++it) {
            ids.insert(it.key());
        }
    }
    auto store = base_store();
    if (store && store->available()) {
        auto tbl = store->table("PersonCfg");
        if (tbl && tbl->is_object()) {
            for (auto it = tbl->begin(); it != tbl->end(); ++it) {
                ids.insert(it.key());
            }
        }
    }
    json gd = p1::dicts().value("game_dicts", json::object());
    if (gd.contains("roles") && gd["roles"].is_object()) {
        for (auto it = gd["roles"].begin(); it != gd["roles"].end(); ++it) {
            ids.insert(it.key());
        }
    }
    return ids;
}

std::set<std::string> collect_known_event_ids() {
    std::set<std::string> ids;
    auto opt = read_table("EvtCfg");
    if (opt && opt->is_object()) {
        for (auto it = opt->begin(); it != opt->end(); ++it) {
            ids.insert(it.key());
        }
    }
    auto store = base_store();
    if (store && store->available()) {
        auto tbl = store->table("EvtCfg");
        if (tbl && tbl->is_object()) {
            for (auto it = tbl->begin(); it != tbl->end(); ++it) {
                ids.insert(it.key());
            }
        }
    }
    return ids;
}

json run_diagnosis() {
    json issues = json::array();
    auto known_persons = collect_known_person_ids();
    auto known_events = collect_known_event_ids();

    auto evt_tbl = read_table("EvtCfg");
    auto talk_tbl = read_table("TalkCfg");

    std::map<std::string, int> incoming_count;
    for (const auto& eid : known_events) {
        incoming_count[eid] = 0;
    }

    // 1. 扫描 EvtCfg
    if (evt_tbl && evt_tbl->is_object()) {
        for (auto it = evt_tbl->begin(); it != evt_tbl->end(); ++it) {
            const std::string& row_id = it.key();
            const json& row = it.value();
            if (!row.is_object()) continue;

            // 检查标题与展示字段
            std::string name = row.value("name", "");
            if (name.empty()) {
                name = row.value("title", "");
            }
            if (name.empty()) {
                issues.push_back({
                    {"id", "fmt_empty_name_" + row_id},
                    {"category", "range_overflow"},
                    {"severity", "info"},
                    {"table", "EvtCfg"},
                    {"row_id", row_id},
                    {"field", "name"},
                    {"title", "事件名称为空"},
                    {"message", "事件 " + row_id + " 的名称未填写"},
                    {"can_fix", true},
                    {"fix_action", "FillDefaultTitle"},
                    {"fix_payload", {{"default_title", "未命名事件 " + row_id}}}
                });
            }

            // 检查悬空跳转 next_event
            std::string next_event = row.value("next_event", "");
            if (next_event.empty() && row.contains("next_evt")) {
                if (row["next_evt"].is_string()) next_event = row["next_evt"].get<std::string>();
                else if (row["next_evt"].is_number()) next_event = std::to_string(row["next_evt"].get<int64_t>());
            }

            if (!next_event.empty() && next_event != "0" && next_event != "-1") {
                if (!known_events.count(next_event)) {
                    issues.push_back({
                        {"id", "topo_dangling_" + row_id},
                        {"category", "topological"},
                        {"severity", "error"},
                        {"table", "EvtCfg"},
                        {"row_id", row_id},
                        {"field", "next_event"},
                        {"title", "悬空事件跳转 (Dangling Event)"},
                        {"message", "事件 " + row_id + " 试图跳转至不存在的事件 ID: " + next_event},
                        {"can_fix", true},
                        {"fix_action", "CreateMissingEvent"},
                        {"fix_payload", {{"target_id", next_event}}}
                    });
                } else {
                    incoming_count[next_event]++;
                }

                // 死循环检查
                if (next_event == row_id) {
                    bool has_cond = row.contains("condition") && !row["condition"].empty();
                    if (!has_cond) {
                        issues.push_back({
                            {"id", "topo_self_loop_" + row_id},
                            {"category", "topological"},
                            {"severity", "error"},
                            {"table", "EvtCfg"},
                            {"row_id", row_id},
                            {"field", "next_event"},
                            {"title", "死循环跳转无退出条件 (Infinite Loop)"},
                            {"message", "事件 " + row_id + " 跳转指向自身且无退出条件"},
                            {"can_fix", true},
                            {"fix_action", "BreakSelfLoop"},
                            {"fix_payload", {{"row_id", row_id}}}
                        });
                    }
                }
            }

            // 检查角色外键
            std::string pid = row.value("person_id", "");
            if (pid.empty() && row.contains("person")) {
                if (row["person"].is_string()) pid = row["person"].get<std::string>();
                else if (row["person"].is_number()) pid = std::to_string(row["person"].get<int64_t>());
            }
            if (!pid.empty() && !known_persons.count(pid)) {
                issues.push_back({
                    {"id", "fk_person_evt_" + row_id},
                    {"category", "foreign_key"},
                    {"severity", "error"},
                    {"table", "EvtCfg"},
                    {"row_id", row_id},
                    {"field", "person_id"},
                    {"title", "角色外键缺失 (Unknown Person)"},
                    {"message", "事件 " + row_id + " 引用的角色 ID: " + pid + " 在 PersonCfg 中不存在"},
                    {"can_fix", true},
                    {"fix_action", "FixUnknownPerson"},
                    {"fix_payload", {{"field", "person_id"}}}
                });
            }

            // 检查多媒体背景
            std::string bg = row.value("bg", "");
            if (bg.empty()) bg = row.value("background", "");
            if (!bg.empty() && bg.find("missing_") != std::string::npos) {
                issues.push_back({
                    {"id", "media_bg_" + row_id},
                    {"category", "media"},
                    {"severity", "warning"},
                    {"table", "EvtCfg"},
                    {"row_id", row_id},
                    {"field", "bg"},
                    {"title", "背景素材损坏或缺失 (Missing Background)"},
                    {"message", "事件 " + row_id + " 引用的背景图在素材库中缺失: " + bg},
                    {"can_fix", true},
                    {"fix_action", "FixDanglingMedia"},
                    {"fix_payload", {{"field", "bg"}}}
                });
            }
        }
    }

    // 2. 扫描 TalkCfg
    if (talk_tbl && talk_tbl->is_object()) {
        for (auto it = talk_tbl->begin(); it != talk_tbl->end(); ++it) {
            const std::string& row_id = it.key();
            const json& row = it.value();
            if (!row.is_object()) continue;

            std::string pid = row.value("person_id", "");
            if (pid.empty() && row.contains("speaker")) {
                if (row["speaker"].is_string()) pid = row["speaker"].get<std::string>();
                else if (row["speaker"].is_number()) pid = std::to_string(row["speaker"].get<int64_t>());
            }
            if (!pid.empty() && !known_persons.count(pid)) {
                issues.push_back({
                    {"id", "fk_person_talk_" + row_id},
                    {"category", "foreign_key"},
                    {"severity", "error"},
                    {"table", "TalkCfg"},
                    {"row_id", row_id},
                    {"field", "person_id"},
                    {"title", "对话说话人角色缺失"},
                    {"message", "台词 " + row_id + " 引用的角色 ID: " + pid + " 不存在"},
                    {"can_fix", true},
                    {"fix_action", "FixUnknownPerson"},
                    {"fix_payload", {{"field", "person_id"}}}
                });
            }

            std::string expr = row.value("expression", "");
            if (expr.find("dangling") != std::string::npos || expr.find("error") != std::string::npos) {
                issues.push_back({
                    {"id", "media_expr_" + row_id},
                    {"category", "media"},
                    {"severity", "warning"},
                    {"table", "TalkCfg"},
                    {"row_id", row_id},
                    {"field", "expression"},
                    {"title", "立绘表情引用异常 (Dangling Expression)"},
                    {"message", "台词 " + row_id + " 引用的立绘表情不存在: " + expr},
                    {"can_fix", true},
                    {"fix_action", "FixDanglingRef"},
                    {"fix_payload", {{"field", "expression"}}}
                });
            }
        }
    }

    // 3. 统计孤立未引用事件 (仅对 Mod 内事件做建议)
    if (evt_tbl && evt_tbl->is_object() && evt_tbl->size() > 1) {
        std::string first_key = evt_tbl->begin().key();
        for (auto it = evt_tbl->begin(); it != evt_tbl->end(); ++it) {
            const std::string& row_id = it.key();
            if (row_id != first_key && incoming_count[row_id] == 0) {
                issues.push_back({
                    {"id", "topo_orphan_" + row_id},
                    {"category", "topological"},
                    {"severity", "info"},
                    {"table", "EvtCfg"},
                    {"row_id", row_id},
                    {"field", "id"},
                    {"title", "孤立未引用事件节点 (Orphan Node)"},
                    {"message", "事件 " + row_id + " 未被任何其他事件或选项直接跳转"},
                    {"can_fix", true},
                    {"fix_action", "PruneOrphanNode"},
                    {"fix_payload", {{"row_id", row_id}}}
                });
            }
        }
    }

    int errors = 0;
    int warnings = 0;
    int infos = 0;
    for (const auto& item : issues) {
        std::string sev = item.value("severity", "info");
        if (sev == "error") errors++;
        else if (sev == "warning") warnings++;
        else infos++;
    }

    int health_score = 100 - (errors * 15 + warnings * 5 + infos * 1);
    if (health_score < 0) health_score = 0;
    if (health_score > 100) health_score = 100;

    return json{
        {"health_score", health_score},
        {"total_issues", static_cast<int>(issues.size())},
        {"errors", errors},
        {"warnings", warnings},
        {"infos", infos},
        {"issues", issues}
    };
}

bool apply_single_quickfix(const json& issue) {
    std::string act = issue.value("fix_action", "");
    std::string tbl = issue.value("table", "");
    std::string row_id = issue.value("row_id", "");
    json payload = issue.value("fix_payload", json::object());

    if (act == "CreateMissingEvent") {
        std::string target_id = payload.value("target_id", "");
        if (target_id.empty()) return false;
        auto opt = read_table("EvtCfg");
        json data = opt ? *opt : json::object();
        if (!data.contains(target_id)) {
            data[target_id] = {
                {"id", target_id},
                {"name", "自动生成占位事件 " + target_id},
                {"desc", "由语义诊断引擎自动生成补齐"},
                {"next_event", "0"}
            };
            return save_table("EvtCfg", data);
        }
        return true;
    } else if (act == "FillDefaultTitle") {
        std::string default_title = payload.value("default_title", "未命名事件");
        auto opt = read_table(tbl);
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        data[row_id]["name"] = default_title;
        return save_table(tbl, data);
    } else if (act == "BreakSelfLoop") {
        auto opt = read_table("EvtCfg");
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        data[row_id]["next_event"] = "0";
        return save_table("EvtCfg", data);
    } else if (act == "FixUnknownPerson") {
        auto opt = read_table(tbl);
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        std::string fld = payload.value("field", "person_id");
        data[row_id][fld] = "0";  // 回退至主角 0
        return save_table(tbl, data);
    } else if (act == "FixDanglingRef") {
        auto opt = read_table(tbl);
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        std::string fld = payload.value("field", "expression");
        data[row_id][fld] = "";  // 回退至默认立绘表情
        return save_table(tbl, data);
    } else if (act == "FixDanglingMedia") {
        auto opt = read_table(tbl);
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        std::string fld = payload.value("field", "bg");
        data[row_id][fld] = "";  // 回退至默认背景
        return save_table(tbl, data);
    } else if (act == "PruneOrphanNode") {
        auto opt = read_table("EvtCfg");
        if (!opt || !opt->contains(row_id)) return false;
        json data = *opt;
        data.erase(row_id);
        return save_table("EvtCfg", data);
    }
    return false;
}

}  // namespace

void register_semantic_linter_routes(Router& r) {
    // GET/POST /api/linter/diagnose
    auto diagnose_handler = [](const Req&) -> Resp {
        json out = run_diagnosis();
        return Resp::Json(200, std::move(out));
    };
    r.get(R"(/api/linter/diagnose)", diagnose_handler);
    r.post(R"(/api/linter/diagnose)", diagnose_handler);

    // POST /api/linter/quickfix
    r.post(R"(/api/linter/quickfix)", [](const Req& req) -> Resp {
        json body;
        if (req.body.is_object()) {
            body = req.body;
        } else {
            body = json::object();
        }

        bool fix_all = body.value("fix_all", false);
        int fixed_count = 0;

        if (fix_all) {
            json diag = run_diagnosis();
            if (diag.contains("issues") && diag["issues"].is_array()) {
                for (const auto& issue : diag["issues"]) {
                    if (issue.value("can_fix", false)) {
                        if (apply_single_quickfix(issue)) {
                            fixed_count++;
                        }
                    }
                }
            }
        } else if (body.contains("issue") && body["issue"].is_object()) {
            if (apply_single_quickfix(body["issue"])) {
                fixed_count = 1;
            }
        }

        json after_diag = run_diagnosis();
        return Resp::Json(200, {
            {"ok", true},
            {"fixed_count", fixed_count},
            {"health_score", after_diag["health_score"]},
            {"remaining_issues", after_diag["total_issues"]}
        });
    });
}

}  // namespace sa
