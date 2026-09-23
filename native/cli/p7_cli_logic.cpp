// p7_cli_logic.cpp — see p7_cli_logic.h.
//
// CLI11 owns the grammar; everything downstream of it is plain data so the
// tests can assert exact request specs and rendered text. JSON-valued options
// bind to strings and are materialized after parse (CLI11 has no nlohmann
// lexer). The rendering is deliberately plain lines — the Python rich tables
// are excluded per brief.
#include "p7_cli_logic.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>

#include <CLI11/CLI11.hpp>

#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/util.h"

namespace sa_cli {

namespace fs = std::filesystem;

// ---------------------------------------------------------------------------
// Small shared helpers (also used by main.cpp)
// ---------------------------------------------------------------------------

bool parse_json_arg(const std::string& text, json& out, std::string& err_msg) {
    json parsed = json::parse(text, nullptr, false);
    if (parsed.is_discarded()) {
        err_msg = "invalid JSON: " + text.substr(0, 120);
        return false;
    }
    out = std::move(parsed);
    return true;
}

bool read_json_file(const std::string& path, json& out, std::string& err_msg) {
    std::string bytes;
    if (!read_text_file(path, bytes, err_msg)) return false;
    return parse_json_arg(bytes, out, err_msg);
}

bool read_text_file(const std::string& path, std::string& out, std::string& err_msg) {
    std::ifstream f(fs::u8path(path), std::ios::binary);
    if (!f) {
        err_msg = "cannot read file: " + path;
        return false;
    }
    out.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    // utf-8-sig tolerance (CONVENTIONS 3).
    if (out.size() >= 3 && static_cast<unsigned char>(out[0]) == 0xEF &&
        static_cast<unsigned char>(out[1]) == 0xBB &&
        static_cast<unsigned char>(out[2]) == 0xBF) {
        out.erase(0, 3);
    }
    return true;
}

std::vector<std::string> split_csv(const std::string& s) {
    std::vector<std::string> out;
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t comma = s.find(',', pos);
        std::string piece = s.substr(pos, comma == std::string::npos ? std::string::npos
                                                                     : comma - pos);
        size_t b = piece.find_first_not_of(" \t\r\n");
        size_t e = piece.find_last_not_of(" \t\r\n");
        if (b != std::string::npos) out.push_back(piece.substr(b, e - b + 1));
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return out;
}

namespace {

std::string lower_ascii(std::string s) {
    for (auto& ch : s) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return s;
}

// UTF-8-safe prefix cut for text previews (byte truncation would chop CJK).
std::string utf8_prefix(const std::string& s, size_t max_cp) {
    size_t cp = 0, i = 0;
    while (i < s.size() && cp < max_cp) {
        unsigned char ch = static_cast<unsigned char>(s[i]);
        size_t step = 1;
        if ((ch & 0xE0) == 0xC0) step = 2;
        else if ((ch & 0xF0) == 0xE0) step = 3;
        else if ((ch & 0xF8) == 0xF0) step = 4;
        if (i + step > s.size()) step = s.size() - i;
        i += step;
        ++cp;
    }
    return s.substr(0, i);
}

std::string oneline(const std::string& s) {
    std::string out;
    for (char ch : s) out += (ch == '\r' || ch == '\n') ? ' ' : ch;
    return out;
}

std::string scalar_or_dump(const json& v) {
    if (v.is_string()) return oneline(v.get<std::string>());
    if (v.is_number() || v.is_boolean() || v.is_null()) return sa_core::py_str(v);
    return oneline(sa_core::py_dumps(v));
}

// Inline JSON options: string -> value; failure surfaces as a usage error.
bool bind_json(const std::string& txt, json& dst, bool& has, std::string& err) {
    if (txt.empty()) return true;
    if (!parse_json_arg(txt, dst, err)) {
        err = "invalid --*-value JSON: " + err;
        return false;
    }
    has = true;
    return true;
}

}  // namespace

// ---------------------------------------------------------------------------
// CLI11 wiring
// ---------------------------------------------------------------------------

namespace {

struct AppParts {
    CLI::App app{"学生时代 Mod编辑器 — native CLI (C++ 后端)"};
    GlobalFlags* g = nullptr;
    Command* c = nullptr;

    // inline JSON option texts (materialized after parse)
    std::string data_txt, set_txt, remove_txt, if_match_txt, opts_txt;
    std::string provider_cfg_txt, ai_txt, cloud_provider_txt;
    bool no_mark_done = false;

    CLI::App *mods_list = nullptr, *mods_create = nullptr, *mods_add = nullptr,
             *mods_select = nullptr, *mods_remove = nullptr, *cfg_list = nullptr,
             *cfg_get = nullptr, *cfg_set = nullptr, *cfg_patch = nullptr,
             *cfg_history = nullptr, *validate = nullptr, *bugfix_scan = nullptr,
             *bugfix_fix = nullptr, *story_export = nullptr, *story_import = nullptr,
             *oobe_status = nullptr, *oobe_done = nullptr, *oobe_setup = nullptr,
             *env_get = nullptr, *env_set = nullptr, *plugin_list = nullptr,
             *plugin_install = nullptr, *plugin_uninstall = nullptr,
             *plugin_reload = nullptr, *plugin_tools = nullptr, *cloud_providers = nullptr,
             *cloud_add = nullptr, *cloud_update = nullptr, *cloud_remove = nullptr,
             *cloud_test = nullptr, *cloud_sync = nullptr, *cloud_status = nullptr,
             *cloud_drivers = nullptr, *cloud_local = nullptr, *cloud_remote = nullptr,
             *ai_settings = nullptr, *ai_set = nullptr;
};

void wire_app(AppParts& P) {
    GlobalFlags& g = *P.g;
    Command& c = *P.c;
    CLI::App& app = P.app;
    app.name("backend_cli");
    app.require_subcommand(1);
    // 编排者合并裁决（MERGE_P7 §7.9）：Python cli 有 --version，此处对齐补上；
    // CLI11 打印后直接 rc=0 退出，不进子命令判定。
    app.set_version_flag("--version", "backend_cli Alpha-v0.3 (native C++ backend)");
    app.add_option("--url", g.url, "打已在运行的后端实例（省略则内嵌自起，随机端口）");
    app.add_option("--data-root", g.data_root,
                   "数据根目录（EDITOR_DATA_ROOT；内嵌模式与 env 子命令使用）");
    app.add_option("--workspace", g.workspace, "工作区目录（内嵌模式 init_state 注入）");
    app.add_option("--mod", g.mod, "本次命令使用的模组（等价 Python CLI 的每命令 --mod）");
    app.add_flag("--json", g.json, "原样输出后端 JSON 响应");
    app.add_option("--timeout", g.timeout, "HTTP 超时秒数")->capture_default_str();

    // ---- mods ----
    CLI::App* mods = app.add_subcommand("mods", "模组管理");
    mods->require_subcommand(1);
    P.mods_list = mods->add_subcommand("list", "列出模组与当前选中");
    P.mods_create = mods->add_subcommand("create", "新建空模组（add 的别名）");
    P.mods_create->add_option("title", c.title, "模组标题/目录名")->required();
    P.mods_create->add_option("--desc", c.desc, "描述");
    P.mods_add = mods->add_subcommand("add", "新建 / 导入模组");
    P.mods_add->add_option("title", c.title, "新建模组标题");
    P.mods_add->add_option("--desc", c.desc, "描述");
    P.mods_add->add_option("--path", c.path, "把已有模组目录复制进工作区并选中");
    P.mods_add->add_option("--zip", c.zip, "把模组 zip 解包进工作区并选中");
    P.mods_add->add_option("--name", c.mod_name, "导入后的模组名（默认取目录名/zip 文件名）");
    P.mods_select = mods->add_subcommand("select", "选中模组");
    P.mods_select->add_option("name", c.mod_name, "模组名")->required();
    P.mods_select->add_option("--root", c.root, "显式模组目录（须在工作区内）");
    P.mods_remove = mods->add_subcommand("remove", "删除模组");
    P.mods_remove->add_option("name", c.mod_name, "模组名")->required();

    // ---- cfg ----
    CLI::App* cfg = app.add_subcommand("cfg", "配置表 Cfgs/zh-cn/*.json");
    cfg->require_subcommand(1);
    P.cfg_list = cfg->add_subcommand("list", "列出当前模组配置表");
    P.cfg_get = cfg->add_subcommand("get", "读取表 / 记录 / 字段");
    P.cfg_get->add_option("cfg", c.cfg, "表名（EvtCfg 等，容错大小写）")->required();
    P.cfg_get->add_option("--id", c.id, "只看一条记录");
    P.cfg_get->add_option("--field", c.field, "配合 --id 只看一个字段");
    P.cfg_get->add_flag("--keys", c.keys, "只要键列表");
    P.cfg_get->add_flag("--meta", c.meta, "只要元信息（条数/mtime）");
    P.cfg_get->add_option("--prefix", c.prefix, "键前缀过滤（逗号分隔）");
    P.cfg_get->add_option("--suffix", c.suffix, "前缀过滤尾截长度 1..8")->capture_default_str();
    P.cfg_get->add_option("--limit", c.limit, "文本视图最多显示行数")->capture_default_str();
    P.cfg_set = cfg->add_subcommand("set", "整表覆盖写入（PUT）");
    P.cfg_set->add_option("cfg", c.cfg, "表名")->required();
    P.cfg_set->add_option("--data", P.data_txt, "整表 JSON 字符串");
    P.cfg_set->add_option("--file", c.path, "整表 JSON 文件路径");
    P.cfg_set->add_option("--expect-mtime", c.expect_mtime, "表级并发检测（ns）");
    P.cfg_set->add_flag("--force", c.force, "跳过冲突检测");
    P.cfg_patch = cfg->add_subcommand("patch", "行级补丁（PUT body 判别 patch 字段）");
    P.cfg_patch->add_option("cfg", c.cfg, "表名")->required();
    P.cfg_patch->add_option("--set", P.set_txt, "行补丁 {id: record} JSON");
    P.cfg_patch->add_option("--set-file", c.path, "行补丁 JSON 文件");
    P.cfg_patch->add_option("--remove", P.remove_txt, "删除行 id 列表（逗号分隔）");
    P.cfg_patch->add_option("--if-match", P.if_match_txt, "if_match {id: 期望值} JSON");
    P.cfg_patch->add_option("--expect-mtime", c.expect_mtime, "表级并发检测（ns）");
    P.cfg_patch->add_flag("--force", c.force, "跳过冲突检测");
    P.cfg_history = cfg->add_subcommand("history", "历史快照列表 / undo / redo");
    P.cfg_history->add_option("cfg", c.cfg, "表名")->required();
    P.cfg_history->add_flag("--undo", c.undo, "撤销上一次写入");
    P.cfg_history->add_flag("--redo", c.redo, "重做");

    // ---- validate / bugfix ----
    P.validate = app.add_subcommand("validate", "schema+跨表校验");
    P.validate->add_option("cfg", c.cfg, "表名")->required();
    P.validate->add_option("--data", P.data_txt, "待校验整表 JSON（默认从当前模组读取）");
    P.validate->add_option("--file", c.path, "待校验整表 JSON 文件");
    P.validate->add_flag("--strict", c.strict, "有 error 级问题时 exit 1");
    CLI::App* bugfix = app.add_subcommand("bugfix", "逻辑 bug 扫描/修复");
    bugfix->require_subcommand(1);
    P.bugfix_scan = bugfix->add_subcommand("scan", "扫描全模组");
    P.bugfix_fix = bugfix->add_subcommand("fix", "应用修复（默认全部）");
    P.bugfix_fix->add_option("--from-file", c.path, "scan 输出的 JSON（bugs 数组或整包）");

    // ---- story ----
    CLI::App* story = app.add_subcommand("story", "剧情文本导入导出");
    story->require_subcommand(1);
    P.story_export = story->add_subcommand("export", "导出事件剧情文本");
    P.story_export->add_option("--evt", c.evt_ids, "EvtCfg id 列表（逗号分隔）")->required();
    P.story_export->add_option("--out", c.out, "写入文件（默认 stdout）");
    P.story_export->add_option("--dual", c.dual, "选项显示 both|option|talk");
    P.story_export->add_option("--opts", P.opts_txt, "透传 opts JSON");
    P.story_import = story->add_subcommand("import", "导入剧情文本");
    P.story_import->add_option("--start-id", c.start_id, "起始事件 id")->required();
    P.story_import->add_option("--text", c.text, "剧情文本（与 --file 二选一）");
    P.story_import->add_option("--file", c.path, "剧情文本文件");
    P.story_import->add_flag("--write", c.write, "写入 TalkCfg/EvtCfg（默认仅预览）");
    P.story_import->add_flag("--append", c.append, "追加而非替换同前缀行");

    // ---- oobe / env ----
    CLI::App* oobe = app.add_subcommand("oobe", "首次使用引导状态");
    oobe->require_subcommand(1);
    P.oobe_status = oobe->add_subcommand("status", "查看引导状态");
    P.oobe_done = oobe->add_subcommand("done", "标记引导完成");
    P.oobe_setup = oobe->add_subcommand("setup", "设置工作区/建模组（可选标记完成）");
    P.oobe_setup->add_option("--workspace", c.root, "工作区目录");
    P.oobe_setup->add_option("--mod", c.title, "顺手新建的模组名");
    P.oobe_setup->add_option("--desc", c.desc, "模组描述");
    P.oobe_setup->add_flag("--no-mark-done", P.no_mark_done, "不标记 OOBE 完成");
    // The backend's /api/oobe/setup ignores ai_settings/cloud_provider (the
    // Python port swallows that step), so the CLI composes them client-side as
    // follow-up requests — see make_plan.
    P.oobe_setup->add_option("--ai", P.ai_txt, "AI 设置 JSON（等价 ai set --data）");
    P.oobe_setup->add_option("--cloud-provider", P.cloud_provider_txt,
                             "云盘 Provider JSON（等价 cloud add）");
    CLI::App* env = app.add_subcommand("env", "editor_env.json 键值（本地文件，非 HTTP）");
    env->require_subcommand(1);
    P.env_get = env->add_subcommand("get", "读一个键");
    P.env_get->add_option("key", c.env_key, "键名")->required();
    P.env_set = env->add_subcommand("set", "写一个键");
    P.env_set->add_option("key", c.env_key, "键名")->required();
    P.env_set->add_option("value", c.env_value, "值（默认按字符串存）")->required();
    P.env_set->add_flag("--json-value", c.json_value, "值按 JSON 解析后存");

    // ---- plugin ----
    CLI::App* plugin = app.add_subcommand("plugin", "插件管理（声明型，常开无启用态）");
    plugin->require_subcommand(1);
    P.plugin_list = plugin->add_subcommand("list", "列出已安装插件");
    P.plugin_install = plugin->add_subcommand("install", "安装插件 zip");
    P.plugin_install->add_option("zip", c.zip, "插件 zip 路径")->required();
    P.plugin_install->add_option("--name", c.plugin_name,
                                 "zip 文件名（缺 manifest.id 时用于推导插件 id）");
    P.plugin_uninstall = plugin->add_subcommand("uninstall", "卸载插件（删除插件目录）");
    P.plugin_uninstall->add_option("id", c.plugin_id, "插件 id")->required();
    P.plugin_reload = plugin->add_subcommand("reload", "重新扫描全部插件");
    P.plugin_tools = plugin->add_subcommand("tools", "列出插件提供给 AI 的工具");

    // ---- cloud ----
    CLI::App* cloud = app.add_subcommand("cloud", "云同步（providers + 增量同步）");
    cloud->require_subcommand(1);
    P.cloud_providers = cloud->add_subcommand("providers", "列出云盘 Provider 与可用驱动");
    P.cloud_add = cloud->add_subcommand("add", "新增 Provider");
    P.cloud_add->add_option("--name", c.provider_name, "Provider 名称");
    P.cloud_add->add_option("--type", c.provider_type, "驱动类型（webdav/local/openlist/...）");
    P.cloud_add->add_option("--config", P.provider_cfg_txt, "驱动配置 JSON（如 {\"url\":...}）");
    P.cloud_add->add_option("--config-file", c.path, "驱动配置 JSON 文件");
    P.cloud_add->add_option("--remote-root", c.remote_root, "远端根目录（默认 mods）");
    P.cloud_update = cloud->add_subcommand("update", "修改 Provider");
    P.cloud_update->add_option("id", c.provider_id, "Provider id")->required();
    P.cloud_update->add_option("--name", c.provider_name, "新名称");
    P.cloud_update->add_option("--type", c.provider_type, "新驱动类型");
    P.cloud_update->add_option("--config", P.provider_cfg_txt, "驱动配置补丁 JSON");
    P.cloud_update->add_option("--config-file", c.path, "驱动配置补丁 JSON 文件");
    P.cloud_update->add_option("--remote-root", c.remote_root, "新远端根目录");
    P.cloud_remove = cloud->add_subcommand("remove", "删除 Provider");
    P.cloud_remove->add_option("id", c.provider_id, "Provider id")->required();
    P.cloud_test = cloud->add_subcommand("test", "测试连接（已保存 Provider 或临时 type+config）");
    P.cloud_test->add_option("provider_id", c.provider_id, "Provider id（与 --type 二选一）");
    P.cloud_test->add_option("--type", c.provider_type, "临时驱动类型");
    P.cloud_test->add_option("--config", P.provider_cfg_txt, "临时驱动配置 JSON");
    P.cloud_sync = cloud->add_subcommand("sync", "增量同步（默认整 Mod 文件夹）");
    P.cloud_sync->add_option("provider_id", c.provider_id, "Provider id")->required();
    P.cloud_sync->add_option("--direction", c.direction,
                             "upload|download|delete_remote|delete_local|sync")->capture_default_str();
    P.cloud_sync->add_option("--mod", c.mod_name, "模组名（默认当前选中模组）");
    P.cloud_sync->add_option("--files", c.files_txt, "只同步这些相对路径（逗号分隔）");
    P.cloud_sync->add_flag("--folder", c.folder, "整文件夹同步（默认）");
    P.cloud_sync->add_flag("--dry-run", c.dry_run, "只预览不写入");
    P.cloud_sync->add_flag("--delete-extra", c.delete_extra, "清理对端多余文件");
    P.cloud_status = cloud->add_subcommand("status", "查看同步进度与历史");
    P.cloud_drivers = cloud->add_subcommand("drivers", "列出驱动的配置 schema");
    P.cloud_local = cloud->add_subcommand("local", "列出 Mod 的本地文件");
    P.cloud_local->add_option("--mod", c.mod_name, "模组名（默认当前选中模组）");
    P.cloud_remote = cloud->add_subcommand("remote", "列出 Provider 上的远端文件");
    P.cloud_remote->add_option("provider_id", c.provider_id, "Provider id")->required();
    P.cloud_remote->add_option("--mod", c.mod_name, "模组名（默认当前选中模组）");
    P.cloud_remote->add_option("--path", c.remote_root, "远端子目录");

    // ---- ai ----
    CLI::App* ai = app.add_subcommand("ai", "AI 设置（.editor_ai.json）");
    ai->require_subcommand(1);
    P.ai_settings = ai->add_subcommand("settings", "查看 AI 设置（含 permissionMode）");
    P.ai_set = ai->add_subcommand("set", "修改 AI 设置");
    P.ai_set->add_option("--mode", c.direction, "permissionMode: confirm|full");
    P.ai_set->add_option("--data", P.ai_txt, "设置补丁 JSON（与 --mode 合并）");
    P.ai_set->add_option("--file", c.path, "设置补丁 JSON 文件");

    // Let global options (--json etc.) appear after the subcommand too
    // (Python parity): every non-root app falls unrecognized options through
    // to its parent. get_subcommands() only lists *parsed* apps pre-parse, so
    // the list is built explicitly here.
    for (CLI::App* s : {mods, cfg, bugfix, story, oobe, env, plugin, cloud, ai,
                        P.mods_list, P.mods_create, P.mods_add, P.mods_select, P.mods_remove,
                        P.cfg_list, P.cfg_get, P.cfg_set, P.cfg_patch, P.cfg_history,
                        P.validate, P.bugfix_scan, P.bugfix_fix,
                        P.story_export, P.story_import,
                        P.oobe_status, P.oobe_done, P.oobe_setup,
                        P.env_get, P.env_set,
                        P.plugin_list, P.plugin_install, P.plugin_uninstall, P.plugin_reload,
                        P.plugin_tools,
                        P.cloud_providers, P.cloud_add, P.cloud_update, P.cloud_remove,
                        P.cloud_test, P.cloud_sync, P.cloud_status, P.cloud_drivers,
                        P.cloud_local, P.cloud_remote,
                        P.ai_settings, P.ai_set}) {
        s->fallthrough();
    }
}

}  // namespace

ParseResult parse_command_line(const std::vector<std::string>& args, GlobalFlags& g,
                               Command& c, std::string& err_msg) {
    AppParts P;
    P.g = &g;
    P.c = &c;
    wire_app(P);
    try {
        // NOTE: App::parse(std::vector&) consumes from the BACK (the argc/argv
        // overload pre-reverses and drops argv[0]). Hand it a real argv.
        std::vector<std::string> storage{"backend_cli"};
        storage.insert(storage.end(), args.begin(), args.end());
        std::vector<const char*> argv;
        argv.reserve(storage.size());
        for (const auto& s : storage) argv.push_back(s.c_str());
        P.app.parse(static_cast<int>(argv.size()), argv.data());
    } catch (const CLI::CallForHelp&) {
        err_msg = P.app.help();  // caller prints to stdout, exit 0
        return ParseResult::Help;
    } catch (const CLI::CallForAllHelp&) {
        err_msg = P.app.help("", CLI::AppFormatMode::All);
        return ParseResult::Help;
    } catch (const CLI::Success& e) {
        // --version (merged-wave adjudication): CLI11 raises Success (a
        // ParseError subclass carrying the version string) — same stdout
        // channel + rc 0 as help, NOT a usage error. Catch before ParseError.
        err_msg = std::string(e.what()) + "\n";
        return ParseResult::Help;
    } catch (const CLI::ParseError& e) {
        err_msg = e.what();
        return ParseResult::UsageError;
    }

    auto hit = [](CLI::App* a) { return a != nullptr && a->parsed(); };
    if (hit(P.mods_list)) c.kind = Kind::ModsList;
    else if (hit(P.mods_create)) c.kind = Kind::ModsCreate;
    else if (hit(P.mods_add)) {
        bool has_title = !c.title.empty();
        bool has_path = !c.path.empty();
        bool has_zip = !c.zip.empty();
        if (static_cast<int>(has_title) + static_cast<int>(has_path) +
                static_cast<int>(has_zip) != 1) {
            err_msg = "mods add 需要 TITLE、--path DIR 或 --zip FILE 之一";
            return ParseResult::UsageError;
        }
        c.kind = has_zip ? Kind::ModsAddZip : has_path ? Kind::ModsAddPath : Kind::ModsCreate;
    }
    else if (hit(P.mods_select)) c.kind = Kind::ModsSelect;
    else if (hit(P.mods_remove)) c.kind = Kind::ModsRemove;
    else if (hit(P.cfg_list)) c.kind = Kind::CfgList;
    else if (hit(P.cfg_get)) {
        c.kind = Kind::CfgGet;
        if (!c.id.empty() && (c.meta || c.keys)) {
            err_msg = "cfg get --id 与 --meta/--keys 不能同用";
            return ParseResult::UsageError;
        }
        if (!c.field.empty() && c.id.empty()) {
            err_msg = "cfg get --field 需要配合 --id";
            return ParseResult::UsageError;
        }
    }
    else if (hit(P.cfg_set)) c.kind = Kind::CfgSet;
    else if (hit(P.cfg_patch)) c.kind = Kind::CfgPatch;
    else if (hit(P.cfg_history)) {
        c.kind = Kind::CfgHistory;
        if (c.undo && c.redo) {
            err_msg = "cfg history --undo 与 --redo 互斥";
            return ParseResult::UsageError;
        }
    }
    else if (hit(P.validate)) c.kind = Kind::Validate;
    else if (hit(P.bugfix_scan)) c.kind = Kind::BugfixScan;
    else if (hit(P.bugfix_fix)) c.kind = Kind::BugfixFix;
    else if (hit(P.story_export)) c.kind = Kind::StoryExport;
    else if (hit(P.story_import)) c.kind = Kind::StoryImport;
    else if (hit(P.oobe_status)) c.kind = Kind::OobeStatus;
    else if (hit(P.oobe_done)) c.kind = Kind::OobeDone;
    else if (hit(P.oobe_setup)) c.kind = Kind::OobeSetup;
    else if (hit(P.env_get)) c.kind = Kind::EnvGet;
    else if (hit(P.env_set)) c.kind = Kind::EnvSet;
    else if (hit(P.plugin_list)) c.kind = Kind::PluginList;
    else if (hit(P.plugin_install)) c.kind = Kind::PluginInstall;
    else if (hit(P.plugin_uninstall)) c.kind = Kind::PluginUninstall;
    else if (hit(P.plugin_reload)) c.kind = Kind::PluginReload;
    else if (hit(P.plugin_tools)) c.kind = Kind::PluginTools;
    else if (hit(P.cloud_providers)) c.kind = Kind::CloudProviders;
    else if (hit(P.cloud_add)) c.kind = Kind::CloudAdd;
    else if (hit(P.cloud_update)) c.kind = Kind::CloudUpdate;
    else if (hit(P.cloud_remove)) c.kind = Kind::CloudRemove;
    else if (hit(P.cloud_test)) c.kind = Kind::CloudTest;
    else if (hit(P.cloud_sync)) c.kind = Kind::CloudSync;
    else if (hit(P.cloud_status)) c.kind = Kind::CloudStatus;
    else if (hit(P.cloud_drivers)) c.kind = Kind::CloudDrivers;
    else if (hit(P.cloud_local)) c.kind = Kind::CloudLocal;
    else if (hit(P.cloud_remote)) c.kind = Kind::CloudRemote;
    else if (hit(P.ai_settings)) c.kind = Kind::AiSettings;
    else if (hit(P.ai_set)) c.kind = Kind::AiSet;
    else {
        err_msg = "缺少子命令";
        return ParseResult::UsageError;
    }

    if (c.kind == Kind::CloudTest && c.provider_id.empty() && c.provider_type.empty()) {
        err_msg = "cloud test 需要 PROVIDER_ID 或 --type";
        return ParseResult::UsageError;
    }
    if (c.kind == Kind::CloudSync) {
        if (c.direction.empty()) {
            err_msg = "cloud sync 需要 --direction upload|download|sync|delete_remote|delete_local";
            return ParseResult::UsageError;
        }
        const std::string dir = lower_ascii(c.direction);
        if (dir != "upload" && dir != "download" && dir != "delete_remote" &&
            dir != "delete_local" && dir != "sync") {
            err_msg = "cloud sync --direction 非法: " + c.direction;
            return ParseResult::UsageError;
        }
        c.direction = dir;
    }
    if (c.kind == Kind::AiSet) {
        if (c.direction.empty() && P.ai_txt.empty() && c.path.empty()) {
            err_msg = "ai set 需要 --mode、--data 或 --file";
            return ParseResult::UsageError;
        }
        if (!c.direction.empty()) {
            const std::string mode = lower_ascii(c.direction);
            if (mode != "confirm" && mode != "full") {
                err_msg = "ai set --mode 只能是 confirm 或 full";
                return ParseResult::UsageError;
            }
            c.direction = mode;
        }
    }

    // expect-mtime supplied? CLI11 leaves 0 when unset; treat non-zero as set.
    if (c.expect_mtime != 0) c.has_expect_mtime = true;
    if (c.kind == Kind::OobeSetup && P.no_mark_done) c.mark_done = false;

    // Materialize inline JSON options.
    if (!bind_json(P.data_txt, c.data, c.has_data, err_msg) ||
        !bind_json(P.set_txt, c.set_obj, c.has_set, err_msg) ||
        !bind_json(P.if_match_txt, c.if_match, c.has_if_match, err_msg) ||
        !bind_json(P.opts_txt, c.opts, c.has_opts, err_msg) ||
        !bind_json(P.provider_cfg_txt, c.provider_config, c.has_provider_config, err_msg) ||
        !bind_json(P.ai_txt, c.ai_settings, c.has_ai_settings, err_msg) ||
        !bind_json(P.cloud_provider_txt, c.cloud_provider, c.has_cloud_provider, err_msg)) {
        return ParseResult::UsageError;
    }
    if (c.has_provider_config && !c.provider_config.is_object()) {
        err_msg = "cloud --config 必须是 JSON object";
        return ParseResult::UsageError;
    }
    if (c.has_ai_settings && !c.ai_settings.is_object()) {
        err_msg = "ai --data/--ai 必须是 JSON object";
        return ParseResult::UsageError;
    }
    if (c.has_cloud_provider && !c.cloud_provider.is_object()) {
        err_msg = "oobe setup --cloud-provider 必须是 JSON object";
        return ParseResult::UsageError;
    }
    if (!P.remove_txt.empty()) {
        json arr = json::array();
        for (auto& k : split_csv(P.remove_txt)) arr.push_back(k);
        c.remove_arr = std::move(arr);
        c.has_remove = true;
    }
    if (c.has_set && !c.set_obj.is_object()) {
        err_msg = "cfg patch --set 必须是 JSON object {id: record}";
        return ParseResult::UsageError;
    }
    if (c.has_if_match && !c.if_match.is_object()) {
        err_msg = "cfg patch --if-match 必须是 JSON object";
        return ParseResult::UsageError;
    }
    return ParseResult::Ok;
}

std::string usage_text() {
    AppParts P;
    GlobalFlags g;
    Command c;
    P.g = &g;
    P.c = &c;
    wire_app(P);
    return P.app.help();
}

// ---------------------------------------------------------------------------
// Request planning
// ---------------------------------------------------------------------------

std::string build_url(const std::string& base_url, const HttpRequestSpec& spec) {
    std::string base = base_url;
    while (!base.empty() && base.back() == '/') base.pop_back();
    // Percent-encode per path segment with Python quote() semantics. A
    // user-typed '/' inside a cfg name therefore DOES open a new segment:
    // the server URL-decodes before fullmatch (httpd.cpp:379, mirroring
    // httpd.py:132-134), so %2F would collapse back to '/' before matching
    // — encoding it buys nothing and both spellings route-miss to the same
    // 404. Query values remain fully encoded (see quote_component).
    std::string encoded_path;
    {
        std::string path = spec.path.empty() ? "/" : spec.path;
        encoded_path = path[0] == '/' ? "/" : "";
        size_t seg_start = path[0] == '/' ? 1 : 0;
        for (;;) {
            size_t slash = path.find('/', seg_start);
            encoded_path += sa_core::http::quote_component(
                path.substr(seg_start, slash == std::string::npos ? std::string::npos
                                                                  : slash - seg_start));
            if (slash == std::string::npos) break;
            encoded_path += '/';
            seg_start = slash + 1;
        }
    }
    std::string url = base + encoded_path;
    bool first = true;
    for (const auto& [k, v] : spec.query) {
        url += first ? '?' : '&';
        first = false;
        url += sa_core::http::quote_component(k) + "=" + sa_core::http::quote_component(v);
    }
    return url;
}

HttpRequestSpec cfg_get_request(const std::string& cfg_name) {
    return HttpRequestSpec{"GET", "/api/cfg/" + cfg_name, {}, json()};
}

HttpRequestSpec validate_post(const std::string& cfg_name, const json& data) {
    json body;
    body["cfg"] = cfg_name;
    body["data"] = data;
    return HttpRequestSpec{"POST", "/api/validate", {}, std::move(body)};
}

HttpRequestSpec mod_select_request(const std::string& name, const std::string& root) {
    json body;
    body["name"] = name;
    if (!root.empty()) body["root"] = root;
    return HttpRequestSpec{"POST", "/api/mods/select", {}, std::move(body)};
}

HttpRequestSpec state_request() {
    return HttpRequestSpec{"GET", "/api/state", {}, json()};
}

bool make_plan(Command& c, std::vector<HttpRequestSpec>& out, std::string& err_msg) {
    out.clear();
    // --file materialization (runtime inputs, not part of the grammar).
    if (c.kind == Kind::CfgSet || c.kind == Kind::Validate || c.kind == Kind::CfgPatch ||
        c.kind == Kind::BugfixFix) {
        if (!c.path.empty()) {
            json file_json;
            if (!read_json_file(c.path, file_json, err_msg)) return false;
            if (c.kind == Kind::CfgPatch) {
                c.set_obj = std::move(file_json);
                c.has_set = true;
            } else if (c.kind == Kind::BugfixFix) {
                c.bugs = std::move(file_json);
                c.has_bugs = true;
            } else {
                c.data = std::move(file_json);
                c.has_data = true;
            }
        }
    }
    if (c.kind == Kind::StoryImport && c.text.empty() && !c.path.empty()) {
        std::string text;
        if (!read_text_file(c.path, text, err_msg)) return false;
        c.text = std::move(text);
    }
    // --config-file / ai set --file: JSON objects merged over any inline --config/--data.
    if ((c.kind == Kind::CloudAdd || c.kind == Kind::CloudUpdate) && !c.path.empty()) {
        json from_file;
        if (!read_json_file(c.path, from_file, err_msg)) return false;
        if (!from_file.is_object()) {
            err_msg = "--config-file 必须是 JSON object";
            return false;
        }
        for (auto it = from_file.begin(); it != from_file.end(); ++it)
            c.provider_config[it.key()] = it.value();
        c.has_provider_config = true;
    }
    if (c.kind == Kind::AiSet && !c.path.empty()) {
        json from_file;
        if (!read_json_file(c.path, from_file, err_msg)) return false;
        if (!from_file.is_object()) {
            err_msg = "ai set --file 必须是 JSON object";
            return false;
        }
        for (auto it = from_file.begin(); it != from_file.end(); ++it)
            c.ai_settings[it.key()] = it.value();
        c.has_ai_settings = true;
    }

    auto put_data = [&](json& body) {
        body["data"] = c.data;
        if (c.has_expect_mtime) body["expect_mtime_ns"] = c.expect_mtime;
        if (c.force) body["force"] = true;
    };
    switch (c.kind) {
        case Kind::ModsList:
            out.push_back({"GET", "/api/mods", {}, json()});
            return true;
        case Kind::ModsCreate: {
            json body;
            body["title"] = c.title;
            body["desc"] = c.desc;
            out.push_back({"POST", "/api/mods/create", {}, std::move(body)});
            return true;
        }
        case Kind::ModsAddPath:
        case Kind::ModsAddZip: {
            std::string name = import_target_name(c.kind == Kind::ModsAddPath ? c.path : c.zip,
                                                  c.kind == Kind::ModsAddZip, c.mod_name);
            if (name.empty()) {
                err_msg = "导入源名称不适合做模组名";
                return false;
            }
            // Step 1 fetches STATE (workspace root); main performs the local
            // copy/extract; step 2 selects the imported mod.
            out.push_back(state_request());
            out.push_back(mod_select_request(name));
            return true;
        }
        case Kind::ModsSelect: {
            json body;
            body["name"] = c.mod_name;
            if (!c.root.empty()) body["root"] = c.root;
            out.push_back({"POST", "/api/mods/select", {}, std::move(body)});
            return true;
        }
        case Kind::ModsRemove: {
            json body;
            body["name"] = c.mod_name;
            out.push_back({"POST", "/api/mods/delete", {}, std::move(body)});
            return true;
        }
        case Kind::CfgList:
            out.push_back({"GET", "/api/cfg", {}, json()});
            return true;
        case Kind::CfgGet: {
            HttpRequestSpec spec{"GET", "/api/cfg/" + c.cfg, {}, json()};
            if (c.meta) spec.query.emplace_back("meta", "1");
            if (c.keys) spec.query.emplace_back("keys", "1");
            if (!c.prefix.empty()) {
                spec.query.emplace_back("prefix", c.prefix);
                spec.query.emplace_back("suffix", std::to_string(c.suffix));
            }
            out.push_back(std::move(spec));
            return true;
        }
        case Kind::CfgSet: {
            if (!c.has_data) {
                err_msg = "cfg set 需要 --data JSON 或 --file FILE";
                return false;
            }
            if (!c.data.is_object()) {
                err_msg = "cfg set 的数据必须是 JSON object（整表）";
                return false;
            }
            json body;
            put_data(body);
            out.push_back({"PUT", "/api/cfg/" + c.cfg, {}, std::move(body)});
            return true;
        }
        case Kind::CfgPatch: {
            if (!c.has_set && !c.has_remove) {
                err_msg = "cfg patch 至少需要 --set/--set-file 或 --remove";
                return false;
            }
            json patch = json::object();
            if (c.has_set) patch["set"] = c.set_obj;
            if (c.has_remove) patch["remove"] = c.remove_arr;
            json body;
            body["patch"] = std::move(patch);
            if (c.has_if_match) body["if_match"] = c.if_match;
            if (c.has_expect_mtime) body["expect_mtime_ns"] = c.expect_mtime;
            if (c.force) body["force"] = true;
            out.push_back({"PUT", "/api/cfg/" + c.cfg, {}, std::move(body)});
            return true;
        }
        case Kind::CfgHistory: {
            if (c.undo || c.redo) {
                json body;
                body["cfg"] = c.cfg;
                out.push_back({"POST",
                               c.undo ? "/api/history/undo" : "/api/history/redo", {},
                               std::move(body)});
            } else {
                out.push_back({"GET", "/api/history", {{"cfg", c.cfg}}, json()});
            }
            return true;
        }
        case Kind::Validate: {
            if (c.has_data) {
                if (!c.data.is_object()) {
                    err_msg = "validate --data/--file 必须是 JSON object";
                    return false;
                }
                out.push_back(validate_post(c.cfg, c.data));
            } else {
                // Auto mode: GET the live table; main turns the response into
                // validate_post(resp.cfg, resp.data).
                out.push_back(cfg_get_request(c.cfg));
            }
            return true;
        }
        case Kind::BugfixScan:
            out.push_back({"POST", "/api/bugfix/scan", {}, json()});
            return true;
        case Kind::BugfixFix: {
            json body = json::object();
            if (c.has_bugs) {
                if (c.bugs.is_array()) {
                    body["bugs"] = c.bugs;
                } else if (c.bugs.is_object() && c.bugs.contains("bugs") &&
                           c.bugs.at("bugs").is_array()) {
                    body["bugs"] = c.bugs.at("bugs");
                } else {
                    err_msg = "--from-file 需要 bugs 数组或 scan 输出对象";
                    return false;
                }
            }
            out.push_back({"POST", "/api/bugfix/fix", {}, std::move(body)});
            return true;
        }
        case Kind::StoryExport: {
            auto ids = split_csv(c.evt_ids);
            if (ids.empty()) {
                err_msg = "story export 需要 --evt id[,id...]";
                return false;
            }
            json idarr = json::array();
            for (auto& s : ids) idarr.push_back(s);
            json body;
            body["evt_ids"] = std::move(idarr);
            if (!c.dual.empty()) body["dual_choice"] = c.dual;
            if (c.has_opts) body["opts"] = c.opts;
            out.push_back({"POST", "/api/story/export", {}, std::move(body)});
            return true;
        }
        case Kind::StoryImport: {
            if (c.start_id.empty()) {
                err_msg = "story import 需要 --start-id";
                return false;
            }
            if (c.text.empty()) {
                err_msg = "story import 需要 --text 或 --file";
                return false;
            }
            json body;
            body["start_id"] = c.start_id;
            body["text"] = c.text;
            body["write"] = c.write;
            body["append"] = c.append;
            out.push_back({"POST", "/api/story/import", {}, std::move(body)});
            return true;
        }
        case Kind::OobeStatus:
            out.push_back({"GET", "/api/oobe/status", {}, json()});
            return true;
        case Kind::OobeDone:
            out.push_back({"POST", "/api/oobe/complete", {}, json()});
            return true;
        case Kind::OobeSetup: {
            json body;
            if (!c.root.empty()) body["workspace"] = c.root;
            if (!c.title.empty()) body["mod_title"] = c.title;
            if (!c.desc.empty()) body["mod_desc"] = c.desc;
            body["mark_done"] = c.mark_done;
            out.push_back({"POST", "/api/oobe/setup", {}, std::move(body)});
            // Follow-up steps the backend's /api/oobe/setup does not perform
            // itself (it drops ai_settings/cloud_provider on the floor): the
            // CLI applies them as real requests right after the setup call.
            if (c.has_ai_settings) {
                json ai_body = json::object();
                ai_body["settings"] = c.ai_settings;
                out.push_back({"PUT", "/api/ai/settings", {}, std::move(ai_body)});
            }
            if (c.has_cloud_provider) {
                // cloud.add_provider(body) reads name/type/config/remote_root
                // straight off the top-level body — the provider object IS the body.
                out.push_back({"POST", "/api/cloud/providers", {}, c.cloud_provider});
            }
            return true;
        }
        case Kind::PluginList:
            out.push_back({"GET", "/api/plugins", {}, json()});
            return true;
        case Kind::PluginInstall: {
            if (c.zip.empty()) {
                err_msg = "plugin install 需要插件 zip 路径";
                return false;
            }
            json body;
            body["path"] = c.zip;
            if (!c.plugin_name.empty()) body["filename"] = c.plugin_name;
            out.push_back({"POST", "/api/plugins/install_path", {}, std::move(body)});
            return true;
        }
        case Kind::PluginUninstall:
            out.push_back({"DELETE", "/api/plugins/" + c.plugin_id, {}, json()});
            return true;
        case Kind::PluginReload:
            out.push_back({"POST", "/api/plugins/reload", {}, json()});
            return true;
        case Kind::PluginTools:
            out.push_back({"GET", "/api/plugins/agent/tools", {}, json()});
            return true;
        case Kind::CloudProviders:
            out.push_back({"GET", "/api/cloud/providers", {}, json()});
            return true;
        case Kind::CloudAdd: {
            if (!c.has_provider_config && c.provider_type.empty() && c.provider_name.empty()) {
                err_msg = "cloud add 至少需要 --type / --name / --config 之一";
                return false;
            }
            // The route wraps everything but the config: cloud.add_provider(body)
            // reads name/type/config/remote_root off the top level.
            json body = json::object();
            if (!c.provider_name.empty()) body["name"] = c.provider_name;
            if (!c.provider_type.empty()) body["type"] = c.provider_type;
            if (c.has_provider_config) body["config"] = c.provider_config;
            if (!c.remote_root.empty()) body["remote_root"] = c.remote_root;
            out.push_back({"POST", "/api/cloud/providers", {}, std::move(body)});
            return true;
        }
        case Kind::CloudUpdate: {
            json body = json::object();
            if (!c.provider_name.empty()) body["name"] = c.provider_name;
            if (!c.provider_type.empty()) body["type"] = c.provider_type;
            if (c.has_provider_config) body["config"] = c.provider_config;
            if (!c.remote_root.empty()) body["remote_root"] = c.remote_root;
            if (body.empty()) {
                err_msg = "cloud update 需要 --name/--type/--config/--remote-root 之一";
                return false;
            }
            out.push_back({"PUT", "/api/cloud/providers/" + c.provider_id, {}, std::move(body)});
            return true;
        }
        case Kind::CloudRemove:
            out.push_back({"DELETE", "/api/cloud/providers/" + c.provider_id, {}, json()});
            return true;
        case Kind::CloudTest: {
            json body = json::object();
            if (!c.provider_id.empty()) {
                body["provider_id"] = c.provider_id;
            } else {
                body["type"] = c.provider_type;
                body["config"] = c.has_provider_config ? c.provider_config : json::object();
            }
            out.push_back({"POST", "/api/cloud/test", {}, std::move(body)});
            return true;
        }
        case Kind::CloudSync: {
            json body = json::object();
            body["provider_id"] = c.provider_id;
            body["direction"] = c.direction;
            if (!c.mod_name.empty()) body["mod_name"] = c.mod_name;
            auto files = split_csv(c.files_txt);
            if (!files.empty()) {
                json arr = json::array();
                for (auto& f : files) arr.push_back(f);
                body["files"] = std::move(arr);
            }
            if (c.folder || files.empty()) body["folder"] = true;
            if (c.dry_run) body["dry_run"] = true;
            if (c.delete_extra) body["delete_extra"] = true;
            out.push_back({"POST", "/api/cloud/sync", {}, std::move(body)});
            return true;
        }
        case Kind::CloudStatus:
            out.push_back({"GET", "/api/cloud/status", {}, json()});
            return true;
        case Kind::CloudDrivers:
            out.push_back({"GET", "/api/cloud/drivers", {}, json()});
            return true;
        case Kind::CloudLocal: {
            HttpRequestSpec spec{"GET", "/api/cloud/local_files", {}, json()};
            if (!c.mod_name.empty()) spec.query.emplace_back("mod_name", c.mod_name);
            out.push_back(std::move(spec));
            return true;
        }
        case Kind::CloudRemote: {
            HttpRequestSpec spec{"GET", "/api/cloud/list", {}, json()};
            spec.query.emplace_back("provider_id", c.provider_id);
            if (!c.mod_name.empty()) spec.query.emplace_back("mod_name", c.mod_name);
            if (!c.remote_root.empty()) spec.query.emplace_back("path", c.remote_root);
            out.push_back(std::move(spec));
            return true;
        }
        case Kind::AiSettings:
            out.push_back({"GET", "/api/ai/settings", {}, json()});
            return true;
        case Kind::AiSet: {
            json patch = json::object();
            if (!c.direction.empty()) patch["permissionMode"] = c.direction;
            if (c.has_ai_settings) {
                for (auto it = c.ai_settings.begin(); it != c.ai_settings.end(); ++it)
                    patch[it.key()] = it.value();
            }
            if (patch.empty()) {
                err_msg = "ai set 需要 --mode、--data 或 --file";
                return false;
            }
            // PUT /api/ai/settings accepts either {"settings": {...}} or a flat
            // body; the flat form keeps the patch minimal and obvious.
            out.push_back({"PUT", "/api/ai/settings", {}, std::move(patch)});
            return true;
        }
        case Kind::EnvGet:
        case Kind::EnvSet:
            return true;  // local file ops, no HTTP
        case Kind::None:
            err_msg = "无命令";
            return false;
    }
    err_msg = "internal: unhandled command kind";
    return false;
}

// ---------------------------------------------------------------------------
// Exit policy + rendering
// ---------------------------------------------------------------------------

int compute_exit(int status, const json& body, const Command& c) {
    if (status < 200 || status > 299) return 1;
    if (c.kind == Kind::Validate && c.strict) {
        if (body.is_object() && body.contains("counts") && body["counts"].is_object() &&
            body["counts"].value("error", 0) > 0) {
            return 1;
        }
    }
    if (c.kind == Kind::CfgGet && !c.id.empty()) {
        const json* data = nullptr;
        if (body.is_object() && body.contains("data") && body["data"].is_object())
            data = &body["data"];
        if (!data || !data->contains(c.id)) return 1;
    }
    return 0;
}

std::string error_text(const json& body) {
    std::ostringstream os;
    if (body.is_object() && body.contains("error")) {
        os << "error: " << scalar_or_dump(body.at("error"));
        if (body.contains("detail")) os << "\ndetail: " << scalar_or_dump(body.at("detail"));
        if (body.contains("conflicting_keys") && body.at("conflicting_keys").is_array()) {
            os << "\nconflicting_keys: ";
            bool first = true;
            for (const auto& k : body.at("conflicting_keys")) {
                os << (first ? "" : ", ") << scalar_or_dump(k);
                first = false;
            }
        }
    } else {
        os << "error: " << oneline(sa_core::py_dumps(body));
    }
    return os.str();
}

namespace {

// Python bool(x) over JSON: null/false/0/""/[]/{} are falsy.
bool json_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get_ref<const std::string&>().empty();
    return !v.empty();
}

// obj[key] when it is a string, else "" (never throws on a type mismatch).
std::string jstr(const json& o, const char* k) {
    if (!o.is_object()) return {};
    auto it = o.find(k);
    if (it == o.end() || !it->is_string()) return {};
    return it->get<std::string>();
}

bool jbool(const json& o, const char* k) {
    if (!o.is_object()) return false;
    auto it = o.find(k);
    return it != o.end() && json_truthy(*it);
}

long long jint(const json& o, const char* k, long long def) {
    if (!o.is_object()) return def;
    auto it = o.find(k);
    if (it == o.end()) return def;
    if (it->is_number_integer()) return it->get<long long>();
    if (it->is_number_unsigned()) return static_cast<long long>(it->get<unsigned long long>());
    if (it->is_number_float()) return static_cast<long long>(it->get<double>());
    return def;
}

// One "id  name vX  已加载" row shared by the plugin list/reload renderers.
void append_plugin_row(std::ostringstream& os, const json& p) {
    const std::string id = jstr(p, "id");
    std::string name = jstr(p, "name");
    if (name.empty()) name = id;
    os << "    " << id << "  " << name;
    const std::string version = jstr(p, "version");
    if (!version.empty()) os << " v" << version;
    os << "  " << (jbool(p, "loaded") ? "已加载" : "未加载");
    const std::string err = jstr(p, "error");
    if (!err.empty()) os << "  error=" << utf8_prefix(oneline(err), 80);
    const std::string author = jstr(p, "author");
    if (!author.empty()) os << "  author=" << author;
    const std::string desc = jstr(p, "description");
    if (!desc.empty()) os << "  " << utf8_prefix(oneline(desc), 60);
    os << "\n";
}

// Bug rows appear in both the scan list and the fix "remaining" list.
void append_bug_row(std::ostringstream& os, const std::string& prefix, const json& b) {
    std::string desc = jstr(b, "desc");
    if (desc.empty()) desc = scalar_or_dump(b.contains("val") ? b.at("val") : json());
    os << prefix << "[" << jstr(b, "flag") << "] " << jstr(b, "cfg") << "#"
       << sa_core::py_str(b.contains("id") ? b.at("id") : json()) << "." << jstr(b, "key")
       << ": " << utf8_prefix(oneline(desc), 80) << "\n";
}

void append_records(std::ostringstream& os, const Command& c, const json& data) {
    static const char* preferred[] = {"title", "content", "showTxt", "desc", "type"};
    long long shown = 0;
    for (auto it = data.begin(); it != data.end() && shown < c.limit; ++it, ++shown) {
        os << it.key();
        const json& rec = it.value();
        if (rec.is_object()) {
            std::vector<std::string> cols;
            for (const char* f : preferred)
                if (rec.contains(f)) cols.push_back(std::string(f) + "=" + scalar_or_dump(rec.at(f)));
            if (cols.empty()) {
                size_t n = 0;
                for (auto f = rec.begin(); f != rec.end() && n < 3; ++f, ++n)
                    cols.push_back(f.key() + "=" + scalar_or_dump(f.value()));
            }
            for (auto& col : cols) {
                if (col.size() > 120) col = utf8_prefix(col, 60) + "…";
                os << '\t' << col;
            }
        } else {
            std::string v = scalar_or_dump(rec);
            if (v.size() > 120) v = utf8_prefix(v, 60) + "…";
            os << '\t' << v;
        }
        os << '\n';
    }
    long long total = static_cast<long long>(data.size());
    if (total > c.limit) os << "... " << (total - c.limit) << " more (use --json)\n";
}

}  // namespace

std::string format_text(const Command& c, const json& body) {
    std::ostringstream os;
    auto str_at = [&](const char* k) -> std::string {
        if (body.is_object() && body.contains(k) && body.at(k).is_string())
            return body.at(k).get<std::string>();
        return {};
    };
    switch (c.kind) {
        case Kind::ModsList: {
            std::string selected = str_at("selected");
            os << "selected: " << (selected.empty() ? "(none)" : selected) << "\n";
            if (body.contains("mods") && body["mods"].is_array()) {
                os << "mods: " << body["mods"].size() << "\n";
                for (const auto& m : body["mods"]) {
                    std::string name = m.value("name", "");
                    os << (name == selected ? "*   " : "    ") << name;
                    std::string mt = m.value("manifest_title", "");
                    if (!mt.empty()) os << "  («" << mt << "»)";
                    if (m.contains("cfg_files") && m["cfg_files"].is_array())
                        os << "  cfgs=" << m["cfg_files"].size();
                    os << "  " << m.value("root", "") << "\n";
                }
            }
            break;
        }
        case Kind::ModsCreate:
        case Kind::ModsAddPath:
        case Kind::ModsAddZip:
        case Kind::ModsSelect: {
            if (body.contains("mod") && body["mod"].is_object()) {
                os << "selected: " << body["mod"].value("name", "") << "\n"
                   << "root: " << body["mod"].value("root", "") << "\n";
            } else {
                os << sa_core::py_dumps(body) << "\n";
            }
            break;
        }
        case Kind::ModsRemove:
            os << "ok: removed\n";
            break;
        case Kind::CfgList: {
            os << "mod: " << str_at("mod") << "\n";
            if (body.contains("cfg_files") && body["cfg_files"].is_array()) {
                os << "cfgs: " << body["cfg_files"].size() << "\n";
                for (const auto& f : body["cfg_files"]) os << "    " << scalar_or_dump(f) << "\n";
            }
            break;
        }
        case Kind::CfgGet: {
            os << "cfg: " << str_at("cfg")
               << "  exists=" << (body.value("exists", false) ? "true" : "false")
               << "  mtime_ns: "
               << sa_core::py_str(body.contains("mtime_ns") ? body.at("mtime_ns") : json())
               << "\n";
            if (body.contains("keys") && body["keys"].is_array()) {
                for (const auto& k : body["keys"]) os << "    " << scalar_or_dump(k) << "\n";
                break;
            }
            if (!body.contains("data") || !body["data"].is_object()) {
                if (body.contains("count"))
                    os << "records: " << body.value("count", 0) << "\n";
                break;
            }
            const json& data = body["data"];
            os << "records: " << data.size() << "\n";
            if (!c.id.empty()) {
                auto it = data.find(c.id);
                if (it == data.end()) {
                    os << "no such id: " << c.id << "\n";
                    break;
                }
                if (!c.field.empty()) {
                    if (it->is_object() && it->contains(c.field)) {
                        const json& v = it->at(c.field);
                        os << (v.is_string() || v.is_number() || v.is_boolean() || v.is_null()
                                   ? sa_core::py_str(v)
                                   : sa_core::py_dumps_indent(v))
                           << "\n";
                    } else {
                        os << "no such field: " << c.field << "\n";
                    }
                } else {
                    os << sa_core::py_dumps_indent(it.value()) << "\n";
                }
                break;
            }
            append_records(os, c, data);
            break;
        }
        case Kind::CfgSet:
        case Kind::CfgPatch: {
            os << "ok: " << str_at("cfg") << "  mtime_ns: "
               << sa_core::py_str(body.contains("mtime_ns") ? body.at("mtime_ns") : json())
               << "\n";
            if (body.contains("applied_set") || body.contains("applied_remove")) {
                os << "applied_set: " << body.value("applied_set", 0)
                   << "  applied_remove: " << body.value("applied_remove", 0) << "\n";
            }
            break;
        }
        case Kind::CfgHistory: {
            if (body.contains("entries") && body["entries"].is_array()) {
                os << "cfg: " << str_at("cfg")
                   << "  snapshots: " << body["entries"].size() << "\n";
                for (const auto& e : body["entries"]) {
                    os << "    " << e.value("file", "")
                       << "  ts=" << sa_core::py_str(e.contains("ts") ? e.at("ts") : json())
                       << "  size=" << sa_core::py_str(e.contains("size") ? e.at("size") : json())
                       << "\n";
                }
            } else {
                os << "ok: " << str_at("cfg") << "  mtime_ns: "
                   << sa_core::py_str(body.contains("mtime_ns") ? body.at("mtime_ns") : json())
                   << "\n";
            }
            break;
        }
        case Kind::Validate: {
            if (body.contains("issues") && body["issues"].is_array()) {
                for (const auto& it : body["issues"]) {
                    os << "[" << it.value("level", "?") << "] ";
                    std::string rid = it.value("rid", "");
                    if (!rid.empty()) os << rid << ": ";
                    os << it.value("msg", "") << "\n";
                }
            }
            if (body.contains("counts") && body["counts"].is_object()) {
                os << "counts: error=" << body["counts"].value("error", 0)
                   << " warn=" << body["counts"].value("warn", 0)
                   << " info=" << body["counts"].value("info", 0) << "\n";
            }
            break;
        }
        case Kind::BugfixScan: {
            // Per-flag tally, first-seen order (the GUI groups by flag too).
            std::vector<std::pair<std::string, long long>> by_flag;
            if (body.contains("bugs") && body["bugs"].is_array()) {
                for (const auto& b : body["bugs"]) {
                    const std::string flag = jstr(b, "flag");
                    bool seen = false;
                    for (auto& [f, n] : by_flag) {
                        if (f == flag) {
                            ++n;
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) by_flag.emplace_back(flag, 1);
                    append_bug_row(os, "", b);
                }
            }
            os << "count: " << body.value("count", 0) << "\n";
            if (!by_flag.empty()) {
                os << "by_flag:";
                for (const auto& [f, n] : by_flag) os << " " << f << "=" << n;
                os << "\n";
            }
            break;
        }
        case Kind::BugfixFix: {
            // The unfixable leftovers are the actionable part of the answer
            // (LOGIC/ERROR rows never auto-heal) — list them, not just the count.
            os << "fixed: " << body.value("fixed", 0)
               << "  remaining: " << body.value("remaining_count", 0) << "\n";
            if (body.contains("remaining") && body["remaining"].is_array()) {
                for (const auto& b : body["remaining"]) append_bug_row(os, "remaining ", b);
            }
            break;
        }
        case Kind::PluginList: {
            const json* arr =
                body.contains("plugins") && body["plugins"].is_array() ? &body["plugins"] : nullptr;
            os << "plugins: " << (arr ? arr->size() : 0) << "\n";
            if (arr)
                for (const auto& p : *arr) append_plugin_row(os, p);
            break;
        }
        case Kind::PluginInstall: {
            os << "installed: " << str_at("id") << "\n";
            if (body.contains("plugin") && body["plugin"].is_object())
                append_plugin_row(os, body["plugin"]);
            break;
        }
        case Kind::PluginUninstall:
            os << "ok: uninstalled\n";
            break;
        case Kind::PluginReload: {
            const json* arr =
                body.contains("plugins") && body["plugins"].is_array() ? &body["plugins"] : nullptr;
            os << "ok: reloaded  plugins: " << (arr ? arr->size() : 0) << "\n";
            if (arr)
                for (const auto& p : *arr) append_plugin_row(os, p);
            break;
        }
        case Kind::PluginTools: {
            const json* arr =
                body.contains("tools") && body["tools"].is_array() ? &body["tools"] : nullptr;
            os << "tools: " << (arr ? arr->size() : 0) << "\n";
            if (arr) {
                for (const auto& t : *arr) {
                    os << "    " << jstr(t, "name");
                    const std::string pid = jstr(t, "plugin_id");
                    if (!pid.empty()) os << "  plugin=" << pid;
                    if (jbool(t, "confirm")) os << "  confirm";
                    const std::string desc = jstr(t, "description");
                    if (!desc.empty()) os << "  " << utf8_prefix(oneline(desc), 70);
                    os << "\n";
                }
            }
            break;
        }
        case Kind::CloudProviders: {
            const json* arr = body.contains("providers") && body["providers"].is_array()
                                  ? &body["providers"]
                                  : nullptr;
            os << "providers: " << (arr ? arr->size() : 0) << "\n";
            if (arr) {
                for (const auto& p : *arr) {
                    os << "    " << jstr(p, "id") << "  " << jstr(p, "name") << "  ["
                       << jstr(p, "type") << "]";
                    const std::string rr = jstr(p, "remote_root");
                    if (!rr.empty()) os << "  remote_root=" << rr;
                    os << "\n";
                }
            }
            if (body.contains("drivers") && body["drivers"].is_array()) {
                os << "drivers:";
                for (const auto& d : body["drivers"]) os << " " << scalar_or_dump(d);
                os << "\n";
            }
            break;
        }
        case Kind::CloudAdd:
        case Kind::CloudUpdate: {
            if (body.contains("provider") && body["provider"].is_object()) {
                const json& p = body["provider"];
                os << "provider: " << jstr(p, "id") << "  " << jstr(p, "name") << "  ["
                   << jstr(p, "type") << "]"
                   << "  remote_root=" << jstr(p, "remote_root") << "\n";
            } else {
                os << sa_core::py_dumps(body) << "\n";
            }
            break;
        }
        case Kind::CloudRemove:
        case Kind::CloudTest:
            os << (c.kind == Kind::CloudRemove ? "ok: removed" : "ok: connection ok") << "\n";
            break;
        case Kind::CloudStatus: {
            os << "running: " << (body.value("running", false) ? "true" : "false")
               << "  action: " << str_at("action")
               << "  progress: " << body.value("progress", 0) << "/" << body.value("total", 0)
               << "\n";
            if (!str_at("provider").empty()) os << "provider: " << str_at("provider") << "\n";
            if (!str_at("last").empty()) os << "last: " << str_at("last") << "\n";
            if (!str_at("error").empty()) os << "error: " << str_at("error") << "\n";
            if (body.contains("history") && body["history"].is_array()) {
                for (const auto& h : body["history"]) {
                    os << "    " << jstr(h, "time") << "  " << jstr(h, "provider") << "  "
                       << jstr(h, "mod") << "  " << jstr(h, "direction")
                       << "  count=" << jint(h, "count", 0) << "\n";
                }
            }
            break;
        }
        case Kind::CloudDrivers: {
            const json* drv =
                body.contains("drivers") && body["drivers"].is_object() ? &body["drivers"] : nullptr;
            os << "drivers: " << (drv ? drv->size() : 0) << "\n";
            if (drv) {
                for (auto it = drv->begin(); it != drv->end(); ++it) {
                    os << "    " << it.key() << ":";
                    if (it.value().is_object()) {
                        for (auto f = it.value().begin(); f != it.value().end(); ++f)
                            os << " " << f.key();
                    }
                    os << "\n";
                }
            }
            break;
        }
        case Kind::CloudLocal: {
            os << "mod: " << str_at("mod") << "  root: " << str_at("root") << "\n"
               << "files: " << body.value("count", 0) << "\n";
            if (body.contains("entries") && body["entries"].is_array()) {
                for (const auto& e : body["entries"]) {
                    os << "    " << jstr(e, "name") << "  " << jint(e, "size", 0) << "B\n";
                }
            }
            break;
        }
        case Kind::CloudRemote: {
            os << "remote: " << str_at("remote") << "\n";
            const json* objs =
                body.contains("objects") && body["objects"].is_array() ? &body["objects"] : nullptr;
            os << "objects: " << (objs ? objs->size() : 0) << "\n";
            if (objs) {
                for (const auto& o : *objs) {
                    std::string path = jstr(o, "path");
                    if (path.empty()) path = jstr(o, "name");
                    os << "    " << path << (jbool(o, "is_dir") ? "/" : "")
                       << "  " << jint(o, "size", 0) << "B\n";
                }
            }
            break;
        }
        case Kind::CloudSync: {
            os << "direction: " << str_at("direction")
               << "  dry_run: " << (body.value("dry_run", false) ? "true" : "false") << "\n";
            if (!str_at("message").empty()) os << "message: " << str_at("message") << "\n";
            if (body.contains("total")) os << "total: " << body.value("total", 0) << "\n";
            if (body.contains("results") && body["results"].is_array()) {
                long long uploaded = 0, downloaded = 0, skipped = 0, failed = 0;
                for (const auto& r : body["results"]) {
                    const std::string rel = jstr(r, "rel");
                    const std::string action = jstr(r, "action");
                    if (!jbool(r, "ok")) ++failed;
                    else if (action.rfind("download", 0) == 0) ++downloaded;
                    else if (action.rfind("upload", 0) == 0) ++uploaded;
                    else ++skipped;
                    os << "    [" << (jbool(r, "ok") ? "ok" : "!!") << "] "
                       << (action.empty() ? "?" : action) << "  " << rel;
                    const std::string err = jstr(r, "error");
                    if (!err.empty()) os << "  error=" << utf8_prefix(oneline(err), 70);
                    os << "\n";
                }
                os << "summary: upload=" << uploaded << " download=" << downloaded
                   << " skip=" << skipped << " failed=" << failed << "\n";
            } else {
                // Single-file result shape (no results[]): dump the interesting keys.
                if (body.contains("local_exists") || body.contains("remote_exists")) {
                    os << "local_exists: " << (body.value("local_exists", false) ? "true" : "false")
                       << "  remote_exists: "
                       << (body.value("remote_exists", false) ? "true" : "false") << "\n";
                }
                if (!str_at("action").empty()) os << "action: " << str_at("action") << "\n";
                if (!str_at("remote").empty()) os << "remote: " << str_at("remote") << "\n";
                if (!str_at("local").empty()) os << "local: " << str_at("local") << "\n";
            }
            break;
        }
        case Kind::AiSettings: {
            const json* s =
                body.contains("settings") && body["settings"].is_object() ? &body["settings"] : nullptr;
            if (!s) {
                os << sa_core::py_dumps(body) << "\n";
                break;
            }
            os << "permissionMode: " << jstr(*s, "permissionMode") << "\n"
               << "provider: " << jstr(*s, "provider") << "\n"
               << "baseUrl: " << jstr(*s, "baseUrl") << "\n"
               << "model: " << jstr(*s, "model") << "\n"
               << "temperature: " << scalar_or_dump(s->contains("temperature")
                                                        ? s->at("temperature")
                                                        : json())
               << "\n";
            break;
        }
        case Kind::AiSet: {
            os << "ok: settings updated\n";
            if (body.contains("settings") && body["settings"].is_object())
                os << "permissionMode: " << jstr(body["settings"], "permissionMode") << "\n";
            break;
        }
        case Kind::StoryExport: {
            std::string text = str_at("text");
            os << text;
            if (!text.empty() && text.back() != '\n') os << "\n";
            break;
        }
        case Kind::StoryImport: {
            os << (c.write ? "imported" : "preview") << ": " << body.value("count", 0)
               << " rows\n";
            if (body.contains("preview") && body["preview"].is_array()) {
                size_t n = 0;
                for (const auto& row : body["preview"]) {
                    if (n++ >= static_cast<size_t>(std::max<long long>(c.limit, 0))) {
                        os << "... (use --json)\n";
                        break;
                    }
                    if (!row.is_array() || row.size() < 2) continue;
                    std::string snip;
                    const json& rec = row[1];
                    if (rec.is_object() && rec.contains("content"))
                        snip = scalar_or_dump(rec.at("content"));
                    else
                        snip = scalar_or_dump(rec);
                    os << "    " << scalar_or_dump(row[0]) << "\t" << utf8_prefix(snip, 60)
                       << "\n";
                }
            }
            break;
        }
        case Kind::OobeStatus: {
            os << "done: " << (body.value("done", false) ? "true" : "false") << "\n"
               << "first_run: " << (body.value("first_run", false) ? "true" : "false") << "\n"
               << "workspace_root: " << str_at("workspace_root") << "\n"
               << "suggested_workspace: " << str_at("suggested_workspace") << "\n"
               << "mods_count: " << body.value("mods_count", 0) << "\n";
            break;
        }
        case Kind::OobeDone:
            os << "ok: oobe completed\n";
            break;
        case Kind::OobeSetup: {
            os << "ok\nworkspace_root: " << str_at("workspace_root") << "\n";
            std::string m = str_at("mod_name");
            if (!m.empty()) os << "mod_name: " << m << "\n";
            if (body.contains("mods") && body["mods"].is_array())
                os << "mods: " << body["mods"].size() << "\n";
            break;
        }
        case Kind::EnvGet:
        case Kind::EnvSet:
        default:
            os << sa_core::py_dumps(body) << "\n";
            break;
    }
    return os.str();
}

std::string env_value_text(const json& value) {
    if (value.is_string()) return oneline(value.get<std::string>());
    if (value.is_number() || value.is_boolean() || value.is_null()) return sa_core::py_str(value);
    return sa_core::py_dumps_indent(value);
}

// ---------------------------------------------------------------------------
// Local import helpers
// ---------------------------------------------------------------------------

bool looks_like_mod_dir(const std::string& dir) {
    std::error_code ec;
    fs::path p = fs::u8path(dir);
    if (fs::is_directory(p / "Cfgs" / "zh-cn", ec)) return true;
    ec.clear();
    return fs::is_regular_file(p / "manifest.json", ec);
}

std::string import_target_name(const std::string& src, bool is_zip,
                               const std::string& override_name) {
    std::string name = override_name;
    if (name.empty()) {
        std::string trimmed = src;
        while (!trimmed.empty() && (trimmed.back() == '/' || trimmed.back() == '\\'))
            trimmed.pop_back();
        size_t sep = trimmed.find_last_of("/\\");
        name = sep == std::string::npos ? trimmed : trimmed.substr(sep + 1);
        if (is_zip) {
            std::string low = lower_ascii(name);
            if (low.size() > 4 && low.compare(low.size() - 4, 4, ".zip") == 0)
                name = name.substr(0, name.size() - 4);
        }
    }
    static const std::string illegal = "\\/:*?\"<>|";
    if (name.empty() || name == "." || name == "..") return {};
    if (name.find_first_of(illegal) != std::string::npos) return {};
    return name;
}

bool zip_entry_reject(const std::string& entry) {
    std::string e = entry;
    for (auto& ch : e)
        if (ch == '\\') ch = '/';
    if (e.empty()) return true;
    if (e.front() == '/') return true;                  // absolute on the wire
    if (e.find(':') != std::string::npos) return true;  // drive letters / NTFS streams
    size_t pos = 0;
    while (pos < e.size()) {
        size_t slash = e.find('/', pos);
        std::string seg = e.substr(pos, slash == std::string::npos ? std::string::npos
                                                                   : slash - pos);
        if (seg == "..") return true;
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    return false;
}

}  // namespace sa_cli
