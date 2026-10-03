// native/tui/tui/app.cpp
#include "app.h"

#include <algorithm>
#include <ctime>
#include <string>

#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/event.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>

#include "p8_cfg.h"
#include "p8_render.h"

namespace p8 {
namespace {

// Verbatim copy of the GUI prompt body in
// frontend/lib/features/ai/ai_prompts.dart (buildSystemPrompt base). Only diff:
// the step-6 generate_image/edit_image paragraph is absent (GUI-only tools; the
// remaining steps renumber down). A "并行调研" paragraph, if ever enabled, is
// composed at runtime by the agent layer per toolset — not part of this copy.
const char* kSystemPrompt =
    "你是「学生时代模组编辑器」的 AI 助手，有直接读取和修改当前模组的完整工具。"
    "修改模组必须通过工具完成——不要只给建议，不要回复「无法修改」或「需要手动操作」。\n"
    "\n【标准操作流程】\n"
    "1. list_domains 查看创作领域与配置表；domain 参数只能取返回的领域 id，不要猜；"
    "未归类表放「通用配置」兜底领域。\n"
    "2. list_domain_items 按关键词/ID 搜索，q 同时匹配 id/名称/内容；"
    "空结果换同义词、拆更短词或去掉 table 再试；多时用 table、limit 限量。\n"
    "3. 修改前用 get_domain_item 读完整内容核对字段；patch 中不在该表 schema 的字段会被直接拒绝，"
    "报错列出允许字段清单。\n"
    "4. update_domain_item 修改，patch 只传要改的字段、不整份回写；create_domain_item 新建，data 宜自带 id"
    "（省略时按当前最大数字 id+1 自动分配），id 先 list_domain_items 查重、重复报错；"
    "delete_domain_item 删除，不可恢复，提交审批前先向用户确认。\n"
    "5. 核对 ID：role/npc/item/mapId/type 等字段先 get_game_dicts（roles=角色、items=物品、maps=地点、"
    "jobs=职业、attrs=属性、relations=关系、bgs=背景、turns=回合、evt_types=事件类型），"
    "按名称核对 ID、不要凭记忆猜；q 搜名称/ID，条数受 limit 限制。\n"
    "6. 舞台调度：对白站位/移动/入场退场/表情/动作，先 get_talk_stage 看当前安排，"
    "再 get_stage_dicts 核对表情/动作/站位名称与 ID，最后 set_talk_stage 按示例格式写指令"
    "（修改前预览等确认）。\n"
    "7. list_files / read_file 只查看模组结构与原始文件；改配置一律走领域工具，不要让用户手动改文件。\n"
    "\n【内容条目规则】（有说话人/发送者归属的条目，角色字段必填）\n"
    "- 对白 TalkCfg 的 roleIds（说话人群组，数组）、短信 PhoneMsgCfg 的 role（发送者，单个 ID）、"
    "动态 KZoneContentCfg 的 role（发布者，单个 ID）、评论 KZoneCommentCfg 的 roles（评论者）均为必填；"
    "先 get_game_dicts(name=roles) 查 ID，只填 roleName 时系统按名字匹配、匹配不到报错；\n"
    "- 对白的 roleName（自定义名字）只是覆盖显示名的可选字段，不能替代 roleIds；"
    "旁白（无说话人）时 roleIds 与 roleName 都留空；\n"
    "- 对白的 roles 是舞台调度指令编码（数字串），由 set_talk_stage 维护，"
    "不要用 update_domain_item 改或当成说话人字段。\n"
    "\n【跨类联动】常要动多张表：\n"
    "- 缺角色就新建：角色分游戏内置（name=roles 字典可查）与模组自有（character 领域 PersonCfg），"
    "两处查不到在 character 新建 PersonCfg、用返回 id 填对白/短信/动态/评论的角色字段，"
    "不要把台词安给相近角色或编造 ID；新建角色不进字典（字典只含内置角色），直接用新建 id。\n"
    "- 跨表引用存的都是 ID 不是名字：改名/改属性只改 PersonCfg 条目本身，引用处自动生效，不要逐表替换；"
    "引用先确认或新建被引用方拿到 id 再回填，不留空引用或占位 id。\n"
    "- 剧情链路：事件（EvtCfg）用 talkId 引用对白、options 引用选项（OptionCfg）、mapId 引用地图；"
    "选项用 talkId/talkId2 引用对白、nextEvtId 跳转下一事件；对白用 nextTalk/nextTalk2 续接、"
    "option 挂选项。先建叶子（对白/选项）再由事件串起，或先建空再回填，引用 id 须真实存在。\n"
    "- 视听资源：对白 bg（BgCfg）、audio（AudioCfg）、事件 mapId（MapCfg）、地图 bg 填对应表条目 id 而非路径；"
    "路径字段（BgCfg url、ItemCfg icon、PersonCfg 立绘 url）才填模组内相对路径；"
    "新背景/音乐在「背景与场景」领域建条目再引用。\n"
    "- 社交：评论（KZoneCommentCfg）必须填 parent 指向所属动态（KZoneContentCfg）id，否则不显示在该动态下；"
    "新闻评论（NewsCommentCfg）由新闻（NewsCfg）的 comments 字段引用。\n"
    "- NPC 玩法：送礼（GiftEvtCfg）item+npc、闲聊（InteractCfg）npc+talkId、"
    "好友申请（FriendRequestCfg）npc，先确认被引用物品/角色/对白存在。\n"
    "- 短信链：多轮短信先逐条新建，再用 PhoneMsgCfg 的 next（后续短信 id 数组）串顺序。\n"
    "- 删除前先用 list_domain_items 核对引用它的表（如角色被对白/短信/动态引用），无引用再删，否则留下悬空 ID。\n"
    "\n【修改纪律】\n"
    "- 只改用户要求范围内，不擅动无关条目/字段；\n"
    "- 找不到目标条目时换关键词再查，确认不存在就如实告知，不要编造 id 或字段；\n"
    "- 审批被拒时停止该操作、问用户怎么调整，不要换参数绕过或反复重试；\n"
    "- 工具报错先读错误信息并按其修正重试；同一操作连续失败 2 次就停下来向用户说明。\n"
    "\n【回答要求】\n"
    "- 使用简体中文；修改前一句话说明计划：对哪个条目、改什么；\n"
    "- 完成后简要汇报：条目名称/ID、改动字段、新值，多条目逐条列出，不要把工具返回的大段 JSON 原样贴出；\n"
    "- 用户只是提问还没让你改时，先解答并给可行方案，等确认后再动手。\n";

std::string Trim(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// A single top-level component: it renders the panel and translates keys.
class TuiComponent : public ftxui::ComponentBase {
public:
    TuiComponent(TuiApp* app, ftxui::ScreenInteractive* screen) : app_(app), screen_(screen) {}

    ftxui::Element Render() override {
        return BuildElement(app_->st, app_->render_width(), app_->render_list_height());
    }

    bool OnEvent(ftxui::Event event) override {
        KeyInput k = app_->MapEventPublic(event);
        if (k.kind == KeyInput::None) return false;
        Intent intent = HandleKey(app_->st, k);
        if (intent == Intent::Quit) {
            screen_->Exit();
            return true;
        }
        app_->RunIntent(intent);
        return true;
    }

private:
    TuiApp* app_;
    ftxui::ScreenInteractive* screen_;
};

}  // namespace

TuiApp::TuiApp(std::string base_url, AgentSettings agent_settings, std::string data_root)
    : api_(std::move(base_url)),
      agent_(std::move(agent_settings)),
      data_root_(std::move(data_root)) {
    std::time_t now = std::time(nullptr);
    session_id_ = "tui-" + std::to_string(static_cast<long long>(now));
}

int TuiApp::render_width() const { return width_; }
int TuiApp::render_list_height() const { return std::max(1, height_ - 5); }

void TuiApp::Run() {
    auto probe = ftxui::Screen::Create(ftxui::Dimension::Full(), ftxui::Dimension::Full());
    width_ = probe.dimx();
    height_ = probe.dimy();

    auto screen = ftxui::ScreenInteractive::TerminalOutput();
    screen_ = &screen;
    auto component = std::make_shared<TuiComponent>(this, &screen);

    std::string err;
    if (api_.Ping(&err)) {
        st.status = "已连接 " + api_.base_url();
    } else {
        st.status = "后端未连接: " + err + "  (" + api_.base_url() + ")";
    }
    // The AI modal title carries the active provider·model like the Alpha's
    // 🤖 dialog did.
    {
        const AgentSettings& as = agent_.settings();
        st.agent_label = (as.provider.empty() ? std::string("openai_compatible") : as.provider) +
                         " · " + (as.model.empty() ? std::string("（未配置模型）") : as.model);
    }
    LoadMods();
    // The permission mode gates every mutating action, so it is seeded from the
    // same .editor_ai.json the desktop frontend reads (GET /api/ai/settings).
    {
        std::string ac_err;
        st.permission_mode = api_.LoadPermissionMode(&ac_err);
    }
    // No-code mode is a shared editor setting (GET /api/settings/editor): the
    // three frontends read the same persisted flag; failures just keep it off.
    {
        std::string nc_err;
        st.no_code_mode = api_.LoadNoCodeMode(&nc_err);
    }
    // Form metadata: schema field types (columns + encode/decode) and the dicts
    // key_maps (field 中文 labels). Failures degrade to the generic form.
    RunIntent(Intent::LoadSchema);
    RunIntent(Intent::LoadDictLabels);
    // OOBE first-run wizard (Alpha's OobeScreen; the shared oobe marker).
    {
        std::string ob_err;
        if (!api_.OobeDone(&ob_err)) {
            st.oobe = OobeState{};
            st.oobe.active = true;
            st.page = Page::Oobe;
        }
    }

    screen.Loop(component);
}

void TuiApp::LoadMods() {
    std::string err;
    ModsListing listing = api_.ListModsWithCounts(&err);
    if (!err.empty()) {
        st.status = err;
        return;
    }
    st.mods = std::move(listing.mods);
    st.cfg_counts = std::move(listing.cfg_counts);
    if (!listing.workspace.empty()) st.workspace = listing.workspace;
    st.mod_sel = st.ClampSel(st.mod_sel, static_cast<int>(st.mods.size()));
    st.tree_sel = st.ClampSel(st.tree_sel, static_cast<int>(st.TreeItems().size()));
}

void TuiApp::RunIntent(Intent intent) {
    std::string err;
    switch (intent) {
        case Intent::RefreshMods:
            LoadMods();
            break;
        case Intent::SelectMod: {
            if (api_.SelectMod(st.selected_mod, &err)) {
                st.tables = api_.ListTables(&err);
                st.mod_tables[st.selected_mod] = st.tables;
                st.table = Table{};
                st.focus = Focus::Tables;  // browse starts on the tree pane
                st.status = err.empty() ? ("模组 " + st.selected_mod + " 共 " +
                                           std::to_string(st.tables.size()) + " 张表")
                                        : err;
                // Enter on a cfg of an unselected mod queued the table to open.
                if (!st.pending_table.empty()) {
                    std::string next = st.pending_table;
                    st.pending_table.clear();
                    bool known = false;
                    for (const auto& t : st.tables) known |= t == next;
                    if (known) {
                        st.table = Table{};
                        st.table.name = next;
                        st.focus = Focus::Rows;
                        st.row_sel = 0;
                        st.detail_mode = DetailMode::Form;
                        st.status = "加载 " + st.table.name;
                        RunIntent(Intent::LoadTable);
                    }
                }
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::CreateMod: {
            // N's title prompt: POST /api/mods/create {title}, then select the
            // fresh mod so the tree can expand it (same path as `mods create`).
            const std::string title = Trim(st.mod_input);
            st.mod_input.clear();
            if (title.empty()) {
                st.status = "输入模组标题";
                break;
            }
            Json body;
            body["title"] = title;
            body["desc"] = "";
            std::string id;
            if (api_.CreateMod(title, &id, &err)) {
                st.status = "已创建模组 " + (id.empty() ? title : id);
                LoadMods();
                for (int i = 0; i < static_cast<int>(st.mods.size()); ++i) {
                    if (st.mods[i].name == (id.empty() ? title : id)) {
                        st.tree_sel = i;
                        st.selected_mod = st.mods[i].name;
                        st.mod_sel = i;
                        st.expanded_mods.insert(st.mods[i].name);
                        RunIntent(Intent::SelectMod);
                        break;
                    }
                }
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::RefreshTables:
            st.tables = api_.ListTables(&err);
            st.status = err;
            break;
        case Intent::LoadTable: {
            Table t;
            if (api_.LoadTable(st.table.name, t, &err)) {
                st.table = std::move(t);
                st.row_sel = 0;
                st.status = st.table.exists ? ("载入 " + std::to_string(st.table.rows.size()) + " 行")
                                            : "该表文件尚不存在（保存将新建）";
                // Choose the display columns once per load (Alpha _choose_columns).
                std::vector<std::string> sample;
                sample.reserve(std::min(st.table.rows.size(), size_t{50}));
                for (size_t i = 0; i < st.table.rows.size() && sample.size() < 50; ++i)
                    sample.push_back(st.table.rows[i].raw);
                Json schema_cfg = st.schema.is_object() && st.schema.contains(st.table.name)
                                      ? st.schema.at(st.table.name)
                                      : Json::object();
                st.table.columns = ChooseColumns(st.table.name, schema_cfg, sample);
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::SearchTalk: {
            st.search.results = api_.SearchTalk(st.search.input, &err);
            st.search.busy = false;
            st.search.sel = 0;
            if (!err.empty()) {
                st.search.error = err;
                st.status = err;
            } else {
                st.status = "搜索到 " + std::to_string(st.search.results.size()) + " 条";
            }
            break;
        }
        case Intent::ValidateTable: {
            if (st.table.name.empty()) {
                st.validate.active = false;
                st.validate.busy = false;
                st.status = "先打开一张表";
                break;
            }
            Json data = TableDataForValidate(st.table.rows, st.table.edits, st.table.removes);
            ValidateResult r;
            if (api_.ValidateTable(st.table.name, data, &r, &err)) {
                st.validate.busy = false;
                st.validate.issues = std::move(r.issues);
                st.validate.errors = r.errors;
                st.validate.warns = r.warns;
                st.validate.infos = r.infos;
                st.status = "校验完成: error=" + std::to_string(r.errors) +
                            " warn=" + std::to_string(r.warns) +
                            " info=" + std::to_string(r.infos);
            } else {
                st.validate.busy = false;
                st.validate.error = err;
                st.status = err;
            }
            break;
        }
        case Intent::SaveTable: {
            auto orig = OrigMapFromRows(st.table.rows);
            Json body = BuildSaveBody(orig, st.table.edits, st.table.removes,
                                      st.table.mtime_ns, st.table.adds);
            if (force_save_) body["force"] = true;
            SaveResult r = api_.SaveTable(st.table.name, body, &err);
            switch (r.kind) {
                case SaveResult::Kind::Ok:
                    st.status = "已保存";
                    force_save_ = false;
                    {
                        Table t;
                        std::string e2;
                        if (api_.LoadTable(st.table.name, t, &e2)) st.table = std::move(t);
                        st.row_sel = 0;
                    }
                    break;
                case SaveResult::Kind::ConflictTable:
                case SaveResult::Kind::LossySource:
                    force_save_ = true;
                    st.status = r.message + "（再按 Ctrl-S 强制覆盖）";
                    break;
                default:
                    st.status = err.empty() ? r.message : err;
                    break;
            }
            break;
        }
        case Intent::ScanBugs:
            st.bugs = api_.ScanBugs(&err);
            st.bug_scanned = true;
            st.bug_sel = 0;
            st.status = err.empty() ? ("扫描到 " + std::to_string(st.bugs.size()) + " 条") : err;
            break;
        case Intent::FixBugs: {
            long long fixed = 0;
            if (api_.FixAllBugs(&fixed, &err)) {
                st.status = "已修复 " + std::to_string(fixed) + " 条，重扫中…";
                st.bugs = api_.ScanBugs(&err);
                st.bug_scanned = true;
                st.bug_sel = 0;
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::SendChat: {
            std::string reply = agent_.SendTurn(kSystemPrompt, st.chat, &err);
            st.chat_busy = false;
            if (!err.empty()) {
                st.status = err;
            } else {
                st.chat.push_back(ChatMsg{"assistant", reply});
                SaveSession(data_root_, session_id_, st.chat);
                st.status.clear();
            }
            break;
        }
        case Intent::RefreshPlugins:
            st.plugins = api_.ListPlugins(&err);
            st.plugins_loaded = true;
            st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
            st.status = err.empty() ? ("插件 " + std::to_string(st.plugins.size()) + " 个") : err;
            break;
        case Intent::InstallPlugin: {
            // The path lives in plugin_input (the state machine cleared only the
            // input *mode*); trim it again so a stray space never reaches the FS.
            const std::string path = Trim(st.plugin_input);
            if (path.empty()) {
                st.status = "输入插件 zip 路径";
                break;
            }
            std::string id;
            if (api_.InstallPlugin(path, &id, &err)) {
                st.plugins = api_.ListPlugins(&err);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已安装 " + (id.empty() ? path : id);
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::UninstallPlugin: {
            if (st.plugins.empty()) {
                st.status = "没有可卸载的插件";
                break;
            }
            const int pi = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
            const std::string id = st.plugins[pi].id;
            if (api_.UninstallPlugin(id, &err)) {
                st.plugins = api_.ListPlugins(&err);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已卸载 " + id;
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::ReloadPlugins: {
            std::vector<PluginEntry> list;
            if (api_.ReloadPlugins(&list, &err)) {
                st.plugins = std::move(list);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已重载 " + std::to_string(st.plugins.size()) + " 个插件";
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::RefreshCloudProviders:
            st.providers = api_.ListCloudProviders(&err);
            st.providers_loaded = true;
            st.provider_sel = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            st.status =
                err.empty() ? ("Provider " + std::to_string(st.providers.size()) + " 个") : err;
            break;
        case Intent::LoadCloudFiles: {
            st.cloud_error.clear();
            std::string e_local, e_remote;
            st.cloud_local = api_.CloudLocalFiles(st.selected_mod, &e_local);
            st.cloud_remote.clear();
            if (!st.providers.empty()) {
                const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
                st.cloud_remote = api_.CloudRemoteFiles(st.providers[pi].id, st.selected_mod,
                                                       &e_remote);
            }
            st.cloud_files_loaded = true;
            // The local failure is fatal-ish; a dead remote is informational
            // (the desktop page shows it as a non-blocking empty state too).
            st.cloud_error = !e_local.empty() ? e_local : e_remote;
            st.status = "本地 " + std::to_string(st.cloud_local.size()) + " 个 / 远端 " +
                        std::to_string(st.cloud_remote.size()) + " 个";
            break;
        }
        case Intent::CloudTest: {
            if (st.providers.empty()) {
                st.status = "没有可选 Provider";
                break;
            }
            const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            st.status = api_.CloudTest(st.providers[pi].id, &err) ? "连接测试通过" : err;
            break;
        }
        case Intent::CloudSync: {
            if (st.providers.empty()) {
                st.status = "没有可选 Provider";
                break;
            }
            const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            CloudSyncSummary sum =
                api_.CloudSync(st.providers[pi].id, st.cloud_direction, st.selected_mod,
                               st.cloud_dry_run, st.cloud_delete_extra, /*full=*/true, &err);
            st.cloud_error = err;
            st.cloud_sync_summary = std::string(sum.dry_run ? "DRY-RUN " : "") + "方向 " +
                                    sum.direction + "  共 " + std::to_string(sum.total) +
                                    "  上传 " + std::to_string(sum.uploaded) + "  下载 " +
                                    std::to_string(sum.downloaded) + "  跳过 " +
                                    std::to_string(sum.skipped) + "  失败 " +
                                    std::to_string(sum.failed);
            if (!sum.message.empty()) st.cloud_sync_summary += "  (" + sum.message + ")";
            st.status = st.cloud_sync_summary;
            break;
        }
        case Intent::CheckUpdate: {
            // 只读检查（后端代查 GitHub Releases，默认 6 秒超时）。先带上已知的
            // 当前版本；首次为空时由后端用它自己编译进去的版本号兜底。
            UpdateResult r = api_.CheckUpdate(st.update_current, &err);
            st.update_loaded = true;
            st.update_ok = r.ok;
            st.update_error = r.error;
            if (!r.current.empty()) st.update_current = r.current;
            st.update_latest_tag = r.latest_tag;
            st.update_latest_name = r.latest_name;
            st.update_published_at = r.published_at;
            st.update_html_url = r.html_url;
            st.update_notes = r.notes;
            st.update_available = r.update_available;
            st.update_prerelease = r.prerelease;
            st.update_assets = std::move(r.assets);
            if (!r.ok) {
                st.status = "检查更新失败: " + (r.error.empty() ? err : r.error);
            } else if (r.update_available) {
                st.status = "发现新版本 " +
                            (r.latest_tag.empty() ? r.latest_name : r.latest_tag) +
                            (r.prerelease ? "（预发行版）" : "");
            } else {
                st.status = "已是最新 " + (r.latest_tag.empty() ? r.current : r.latest_tag);
            }
            break;
        }
        case Intent::LoadAiSettings:
            st.permission_mode = api_.LoadPermissionMode(&err);
            break;
        case Intent::SetPermissionMode: {
            std::string e2;
            if (!api_.SavePermissionMode(st.permission_mode, &e2)) st.status = e2;
            break;
        }
        case Intent::SetNoCodeMode: {
            std::string e2;
            if (!api_.SaveNoCodeMode(st.no_code_mode, &e2)) st.status = e2;
            break;
        }
        case Intent::FetchFieldSuggestions: {
            std::string e2;
            st.sug.all = st.sug.mode == "role"
                             ? api_.RoleSuggest(std::string(), &e2)
                             : api_.EffectSuggest(st.sug.mode, std::string(), &e2);
            st.sug.shown = FilterSuggestions(st.sug.all, std::string());
            st.sug.sel = 0;
            st.sug.query.clear();
            st.sug.active = !st.sug.all.empty();
            if (!e2.empty()) {
                st.status = e2;
            } else if (st.sug.active) {
                st.status = "候选 " + std::to_string(st.sug.all.size()) +
                            " 条：Tab/↑↓ 选 · Enter 接受 · Esc 手输";
            } else {
                st.status = "该字段没有可用候选";
            }
            break;
        }
        case Intent::FetchSlotEntries: {
            FieldSuggestState& sg = st.sug;
            if (sg.cand < 0 || sg.cand >= static_cast<int>(sg.all.size()) ||
                sg.slot_i >= static_cast<int>(sg.all[sg.cand].slots.size()))
                break;
            const SuggestionSlot& slot = sg.all[sg.cand].slots[sg.slot_i];
            std::string e2;
            if (sg.mode == "role" || SlotPoolDictKey(slot.dict) == "roles") {
                // Role pool: /api/roles merges the workspace PersonCfg entries
                // on top of game_dicts — always richer than the raw dict.
                sg.slot_entries.clear();
                for (const FieldSuggestion& r : api_.RoleSuggest(sg.slot_q, &e2))
                    sg.slot_entries.emplace_back(r.code, r.desc);
            } else {
                sg.slot_entries = api_.DictEntries(SlotPoolDictKey(slot.dict), &e2);
            }
            if (!e2.empty()) st.status = e2;
            sg.entry_shown = FilterEntries(sg.slot_entries, sg.slot_q);
            sg.entry_sel = 0;
            break;
        }
        case Intent::ReportUsage: {
            if (!st.sug.pending_kind.empty() && !st.sug.pending_key.empty())
                api_.ReportUsage(st.sug.pending_kind, st.sug.pending_key);
            st.sug.pending_kind.clear();
            st.sug.pending_key.clear();
            break;
        }
        case Intent::LoadSchema: {
            st.schema = api_.GetSchema(&err);
            break;
        }
        case Intent::LoadDictLabels: {
            st.key_maps = api_.GetKeyMaps(&err);
            if (!err.empty()) err.clear();  // labels degrade to raw keys
            break;
        }
        case Intent::FetchDictEntries: {
            // st.sug.mode holds the game_dicts pool (roles/bgs/audios/...).
            const std::string pool = st.sug.mode;
            std::string e2;
            st.sug.all.clear();
            if (pool == "roles") {
                // /api/roles merges workspace PersonCfg entries — richer.
                for (const FieldSuggestion& r : api_.RoleSuggest(std::string(), &e2))
                    st.sug.all.push_back(r);
            } else {
                for (auto& [id, name] : api_.DictEntries(pool, &e2))
                    st.sug.all.push_back(
                        FieldSuggestion{id, name.empty() ? id : name, id, {}});
            }
            st.sug.shown = FilterSuggestions(st.sug.all, std::string());
            st.sug.sel = 0;
            st.sug.query.clear();
            st.sug.active = !st.sug.all.empty();
            if (!e2.empty()) {
                st.status = e2;
            } else if (st.sug.active) {
                st.status = "候选 " + std::to_string(st.sug.all.size()) +
                            " 条：Tab/↑↓ 选 · Enter 接受 · 打字过滤 · Esc 手输";
            }
            break;
        }
        case Intent::TtsLoadSettings: {
            Json s = api_.TtsSettings(&err);
            st.tts.loaded = true;
            st.tts.provider = s.value("ttsProvider", std::string());
            st.tts.api_key = s.value("ttsApiKey", std::string());
            st.tts.base_url = s.value("ttsBaseUrl", std::string());
            st.tts.model = s.value("ttsModel", std::string());
            st.tts.voice = s.value("ttsVoice", std::string());
            break;
        }
        case Intent::TtsSaveSettings: {
            Json patch = Json::object();
            if (!st.tts.provider.empty()) patch["ttsProvider"] = st.tts.provider;
            patch["ttsApiKey"] = st.tts.api_key;
            patch["ttsBaseUrl"] = st.tts.base_url;
            patch["ttsModel"] = st.tts.model;
            patch["ttsVoice"] = st.tts.voice;
            if (api_.TtsSaveSettings(patch, &err)) {
                st.status = "已保存配音设置";
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::TtsTest: {
            st.tts.busy = true;
            // PUT the typed fields first so the test uses them.
            Json patch = Json::object();
            if (!st.tts.provider.empty()) patch["ttsProvider"] = st.tts.provider;
            patch["ttsApiKey"] = st.tts.api_key;
            patch["ttsBaseUrl"] = st.tts.base_url;
            patch["ttsModel"] = st.tts.model;
            patch["ttsVoice"] = st.tts.voice;
            api_.TtsSaveSettings(patch, &err);
            Json r = api_.TtsTest(&err);
            st.tts.busy = false;
            if (!err.empty()) {
                st.tts.error = err;
                st.status = err;
            } else if (r.value("ok", false)) {
                st.tts.error.clear();
                st.tts.result = r.value("detail", std::string("连接成功"));
                st.status = st.tts.result;
            } else {
                st.tts.error = r.value("error", std::string("连接失败"));
                st.status = "测试失败: " + st.tts.error;
            }
            break;
        }
        case Intent::TtsSynthesize: {
            st.tts.busy = true;
            // PUT the typed fields first so the synthesis uses them.
            Json patch = Json::object();
            if (!st.tts.provider.empty()) patch["ttsProvider"] = st.tts.provider;
            patch["ttsApiKey"] = st.tts.api_key;
            patch["ttsBaseUrl"] = st.tts.base_url;
            patch["ttsModel"] = st.tts.model;
            patch["ttsVoice"] = st.tts.voice;
            api_.TtsSaveSettings(patch, &err);
            Json synth = api_.TtsSynthesize(st.tts.text, st.tts.voice, &err);
            if (err.empty() && synth.contains("audio")) {
                Json saved = api_.TtsSave(synth.value("audio", std::string()),
                                          synth.value("ext", std::string("wav")),
                                          st.tts.text.substr(0, 20), /*write_cfg=*/false, &err);
                if (err.empty()) {
                    st.tts.result = "已保存 " + saved.value("rel_path",
                                                            saved.value("key", std::string("(素材)")));
                    if (saved.contains("warning") && saved.at("warning").is_string())
                        st.tts.result += "  (" + saved.at("warning").get<std::string>() + ")";
                    st.status = st.tts.result;
                }
            }
            st.tts.busy = false;
            if (!err.empty()) {
                st.tts.error = err;
                st.status = err;
            }
            break;
        }
        case Intent::OobeSetWorkspace: {
            std::string ws = Trim(st.oobe.workspace_input);
            if (!ws.empty()) {
                std::string resolved = api_.SetWorkspace(ws, &err);
                if (!err.empty()) {
                    st.status = err;
                    break;  // stay on step 0 so the path can be corrected
                }
                if (!resolved.empty()) st.workspace = resolved;
                st.status = "工作区已设置: " + resolved;
                LoadMods();
            }
            st.oobe.step = 1;
            break;
        }
        case Intent::OobeComplete: {
            api_.OobeComplete(&err);
            st.oobe.active = false;
            if (st.page == Page::Oobe) st.page = Page::Main;
            break;
        }
        case Intent::Quit:
        case Intent::None:
            break;
    }
}

KeyInput TuiApp::MapEventPublic(const ftxui::Event& e) const { return MapEvent(e); }

KeyInput TuiApp::MapEvent(const ftxui::Event& e) const {
    using ftxui::Event;
    auto mk = [](KeyInput::Kind kind) {
        KeyInput k;
        k.kind = kind;
        return k;
    };
    if (e == Event::ArrowUp) return mk(KeyInput::Up);
    if (e == Event::ArrowDown) return mk(KeyInput::Down);
    if (e == Event::ArrowLeft) return mk(KeyInput::Left);
    if (e == Event::ArrowRight) return mk(KeyInput::Right);
    if (e == Event::Return) return mk(KeyInput::Enter);
    if (e == Event::Escape) return mk(KeyInput::Escape);
    if (e == Event::Backspace) return mk(KeyInput::Backspace);
    if (e == Event::Tab) return mk(KeyInput::Tab);
    if (e == Event::TabReverse) return mk(KeyInput::ShiftTab);
    if (e == Event::Home) return mk(KeyInput::Home);
    if (e == Event::End) return mk(KeyInput::End);
    if (e == Event::PageUp) return mk(KeyInput::PageUp);
    if (e == Event::PageDown) return mk(KeyInput::PageDown);

    // Control letters arrive as a single byte in 0x01..0x1A (Ctrl+letter).
    if (!e.is_character() && e.input().size() == 1) {
        unsigned char b = static_cast<unsigned char>(e.input()[0]);
        if (b >= 1 && b <= 26) {
            KeyInput k = mk(KeyInput::CtrlChar);
            k.ctrl = static_cast<char>('a' + (b - 1));
            return k;
        }
    }
    if (e.is_character()) {
        KeyInput k = mk(KeyInput::Char);
        k.text = e.character();
        return k;
    }
    return mk(KeyInput::None);
}

AppState TuiApp::SampleState(Page page) {
    AppState s;
    s.page = page;
    s.mods = {ModEntry{"DemoMod", "mods/DemoMod", "示例模组", 4},
              ModEntry{"Another", "mods/Another", "", 0}};
    s.selected_mod = "DemoMod";
    s.mod_sel = 0;
    s.expanded_mods.insert("DemoMod");  // the selected mod renders its cfg children
    s.mod_tables["DemoMod"] = {"TalkCfg", "ItemCfg", "PersonCfg", "EvtCfg"};
    s.tree_sel = 1;      // cursor on the first cfg node
    s.tables = {"TalkCfg", "ItemCfg", "PersonCfg", "EvtCfg"};
    s.table = Table{};
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.mtime_ns = 1700000000000000000LL;
    s.table.rows = {TableRow{"1", "你好，同学", R"({"id":1,"effect":"4015","content":"你好，同学"})"},
                    TableRow{"2", "今天天气不错",
                             R"({"id":2,"effect":"4016","content":"今天天气不错"})"}};
    s.table.edits["2"] = R"({"id":2,"effect":"4017","content":"今天下雨了"})";
    s.table.columns = {"ID", "effect", "预览"};
    s.focus = Focus::Rows;
    s.agent_label = "openai_compatible · gpt-4o-mini";
    s.bugs = {BugEntry{"TalkCfg", "5", "roleIds", "REF", "引用了不存在的角色 ID 999"},
              BugEntry{"ItemCfg", "12", "icon", "SCHEMA_HEAL", "字段应为数组 []"} };
    s.bug_scanned = true;
    s.chat = {ChatMsg{"user", "帮我看看 TalkCfg 的第一句"},
              ChatMsg{"assistant", "第一句对白内容为「你好，同学」，说话人角色已配置。"}};
    s.plugins = {PluginEntry{"demo", "Demo Plugin", "1.2.3", "me", "示例插件", "", true},
                 PluginEntry{"broken", "Broken", "", "", "", "manifest 解析失败", false}};
    s.plugins_loaded = true;
    s.providers = {CloudProvider{"p_1", "我的网盘", "webdav", "mods"},
                   CloudProvider{"p_2", "本地目录", "local", "mods"}};
    s.providers_loaded = true;
    s.cloud_local = {CloudFile{"Cfgs/zh-cn/TalkCfg.json", false, 128},
                     CloudFile{"Cfgs/zh-cn/EvtCfg.json", false, 256}};
    s.cloud_remote = {CloudFile{"mods/DemoMod/Cfgs/zh-cn/TalkCfg.json", false, 128}};
    s.cloud_files_loaded = true;
    s.cloud_sync_summary = "DRY-RUN 方向 upload  共 2  上传 1  下载 0  跳过 1  失败 0";
    s.status = "示例数据（--render-check）";
    return s;
}

}  // namespace p8
