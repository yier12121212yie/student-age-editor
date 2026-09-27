// p7_repl.cpp — see p7_repl.h. Everything terminal-specific (raw-mode line
// editing, history recall, Tab completion menu, ANSI panel drawing) lives here;
// a non-TTY stdin falls back to plain std::getline so pipes/CI still work.
//
// M3 (无代码模式 + 自动补全优化): the Tab key no longer does a plain
// longest-prefix match. The lexical-slot routing lives in p7_cli_logic
// (ReplComplete); this file only (a) caches the HTTP pools the backend offers
// (GET /api/usage, /api/effect_suggest, /api/roles — fetched once per REPL
// session / mode, never per keystroke) and (b) renders the numbered candidate
// menu with ↑↓ / 数字直达 / Enter / Esc on both platforms.
#include "p7_repl.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <set>
#include <sstream>

#include "p7_color.h"
#include "sa_core/paths.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <conio.h>
#include <windows.h>
#include <io.h>
#else
#include <termios.h>
#include <unistd.h>
#endif

namespace sa_cli {

namespace {

bool StdinIsTty() {
#ifdef _WIN32
    return _isatty(_fileno(stdin)) != 0;
#else
    return ::isatty(::fileno(stdin)) != 0;
#endif
}

std::string Trim(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::string LowerAscii(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// The slash families that pass straight through to the CLI grammar (the slash
// is stripped and the words run as ordinary tokens). `settings` is NOT here:
// /settings is handled below so the bare form can default to `show`.
const char* kPassThrough[] = {"mods",  "cfg", "validate", "bugfix", "story", "oobe",
                              "env",   "ai",  "plugin",   "plugins", "cloud", "search"};

// A cyan-bordered welcome panel, the Alpha REPL's banner.
void PrintBanner(const std::string& workspace, size_t mods_count,
                 const std::vector<std::string>& mod_names, size_t cfg_count,
                 const std::string& current_mod, const std::string& no_code_text) {
    const std::string title = "学生时代 · Editor CLI — 类 Claude Code";
    const std::string sub = "输入 /help 查看命令 · Tab 补全菜单 · @提及 · !shell · Ctrl+D 退出";
    size_t w = std::max({title.size(), sub.size()}) + 2;
    std::string line(static_cast<size_t>(w) + 2, '─');
    auto put = [&](const std::string& s) { std::fputs(s.c_str(), stdout); };
    if (Style::Enabled()) {
        put(Style::Cyan("╭" + line + "╮") + "\n");
        put(Style::Cyan("│") + " " + Style::BoldCyan(title) + "\n");
        put(Style::Cyan("│") + " " + Style::Dim(sub) + "\n");
        put(Style::Cyan("╰" + line + "╯") + "\n");
    } else {
        put(title + "\n" + sub + "\n");
    }
    std::string mods_preview;
    for (size_t i = 0; i < mod_names.size() && i < 5; ++i)
        mods_preview += (i ? ", " : "") + mod_names[i];
    if (mod_names.size() > 5) mods_preview += ", …";
    std::ostringstream grid;
    grid << "Workspace: " << (workspace.empty() ? "-" : workspace) << "\n"
         << "Mods: " << mods_count << (mods_preview.empty() ? "" : " (" + mods_preview + ")")
         << "\n"
         << "Cfgs: " << cfg_count << "  当前模组: "
         << (current_mod.empty() ? "-" : current_mod) << "\n"
         << "无代码模式: " << no_code_text << "（/settings no-code on|off 切换）\n";
    put(grid.str());
    put(std::string(60, '─') + "\n");
    put(Style::Dim("提示: 直接输入 /mods list 或 @EvtCfg 试试；Tab 弹出候选菜单，空行 Tab 看高频命令。") +
        "\n");
}

void PrintHelp() {
    struct Row {
        const char* cmd;
        const char* desc;
        const char* example;
    };
    static const Row rows[] = {
        {"/help", "显示本帮助", "/help"},
        {"/use <模组>", "切换当前模组（后续命令免 --mod）", "/use test"},
        {"/status", "查看工作区与模组状态", "/status"},
        {"/settings [no-code on|off|show]", "无代码模式开关（无参 = 查看）",
         "/settings no-code on"},
        {"/search <关键词>", "全局搜索对白", "/search 你好"},
        {"/mods …", "模组管理 list/create/add/select/remove", "/mods list"},
        {"/cfg …", "配置表 list/get/set/patch/history", "/cfg get TalkCfg --id 1"},
        {"/validate <表>", "schema+跨表校验", "/validate TalkCfg"},
        {"/bugfix …", "Bug 扫描/修复", "/bugfix scan"},
        {"/story …", "剧情文本导入导出", "/story export --evt 101"},
        {"/plugin …", "插件管理", "/plugin list"},
        {"/cloud …", "云同步与 Provider 管理", "/cloud providers"},
        {"/ai …", "AI 设置", "/ai settings"},
        {"/oobe …  /env …", "OOBE 状态 / editor_env 键值", "/env get workspace_root"},
        {"/clear", "清屏", "/clear"},
        {"! <命令>", "执行系统命令", "!git status"},
        {"/exit  /quit", "退出 REPL", "/exit"},
        {"@提及", "快捷：@模组 选中 / @表[:id] 读记录 / @role:人物 读人物配置",
         "@EvtCfg:320101"},
    };
    auto put = [&](const std::string& s) { std::fputs(s.c_str(), stdout); };
    put(Style::BoldCyan("可用命令") + "\n");
    for (const auto& r : rows) {
        std::string cmd = r.cmd;
        while (cmd.size() < 34) cmd += ' ';
        std::string desc = r.desc;
        put("  " + Style::BoldGreen(cmd) + " " + Style::Dim(desc) + "  " +
            Style::Cyan(r.example) + "\n");
    }
    put(Style::Dim("快捷键: Tab 补全菜单（↑↓/数字直达/Enter/Esc） · ↑↓ 历史 · 空回车重复上一条 · "
                   "Ctrl+C 取消 · Ctrl+D 退出") +
        "\n");
}

// One history entry + the mutable input buffer shared by the line editors.
struct LineState {
    std::string buffer;
    size_t history_pos = 0;  // == history.size() → drafting a new line
};

void Redraw(const std::string& prompt, const std::string& buffer) {
    // Carriage return + clear-to-end keeps this cheap even for CJK text.
    std::fputs(("\r\x1b[J" + prompt + buffer).c_str(), stdout);
    std::fflush(stdout);
}

#ifdef _WIN32
std::string WideToUtf8(wchar_t c) {
    std::string out(4, '\0');
    int n = WideCharToMultiByte(CP_UTF8, 0, &c, 1, out.data(), 4, nullptr, nullptr);
    out.resize(n > 0 ? n : 0);
    return out;
}

// Console line editor: history + Tab completion + Ctrl-C/Ctrl-D. Returns the
// finished line, or "" for quit (Ctrl-D on empty) / "/__cancel" for Ctrl-C.
// `complete(prompt, buffer)` returns the new buffer ("" = keep as is) and owns
// the candidate-menu rendering.
std::string ReadLineWin(const std::string& prompt, LineState& st,
                        const std::vector<std::string>& history,
                        const std::function<std::string(const std::string&,
                                                       const std::string&)>& complete) {
    Redraw(prompt, st.buffer);
    for (;;) {
        int c = _getwch();
        if (c == 0 || c == 0xE0) {  // arrow/function prefix
            int k = _getwch();
            if (k == 'H' && !history.empty()) {  // up
                if (st.history_pos > 0) --st.history_pos;
                st.buffer = history[st.history_pos];
            } else if (k == 'P') {  // down
                if (st.history_pos + 1 < history.size()) {
                    ++st.history_pos;
                    st.buffer = history[st.history_pos];
                } else {
                    st.history_pos = history.size();
                    st.buffer.clear();
                }
            }
            Redraw(prompt, st.buffer);
            continue;
        }
        if (c == L'\r' || c == L'\n') {
            std::fputs("\n", stdout);
            return st.buffer;
        }
        if (c == 0x03) {  // Ctrl-C
            st.buffer.clear();
            std::fputs("^C\n", stdout);
            return "/__cancel";
        }
        if (c == 0x04) {  // Ctrl-D
            if (st.buffer.empty()) {
                std::fputs("\n", stdout);
                return "";
            }
            continue;
        }
        if (c == L'\t') {
            std::string got = complete(prompt, st.buffer);
            if (!got.empty()) st.buffer = got;
            Redraw(prompt, st.buffer);
            continue;
        }
        if (c == L'\b' || c == 0x7F) {
            // Drop one UTF-8 code point.
            while (!st.buffer.empty() &&
                   (static_cast<unsigned char>(st.buffer.back()) & 0xC0) == 0x80)
                st.buffer.pop_back();
            if (!st.buffer.empty()) st.buffer.pop_back();
            Redraw(prompt, st.buffer);
            continue;
        }
        if (c >= 0x20) {
            st.buffer += WideToUtf8(static_cast<wchar_t>(c));
            Redraw(prompt, st.buffer);
        }
    }
}
#else
// POSIX raw-mode counterpart of ReadLineWin (same contract).
std::string ReadLinePosix(const std::string& prompt, LineState& st,
                          const std::vector<std::string>& history,
                          const std::function<std::string(const std::string&,
                                                         const std::string&)>& complete) {
    termios raw{}, orig{};
    bool raw_ok = ::tcgetattr(0, &orig) == 0;
    if (raw_ok) {
        raw = orig;
        raw.c_lflag &= ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        ::tcsetattr(0, TCSANOW, &raw);
    }
    Redraw(prompt, st.buffer);
    std::string out;
    for (;;) {
        char c = 0;
        if (::read(0, &c, 1) != 1) {  // EOF
            out = st.buffer.empty() ? "" : st.buffer;
            std::fputs("\n", stdout);
            break;
        }
        if (c == '\x1b') {  // escape sequence: arrows
            char seq[2] = {0, 0};
            if (::read(0, &seq[0], 1) == 1 && seq[0] == '[' &&
                ::read(0, &seq[1], 1) == 1) {
                if (seq[1] == 'A' && !history.empty()) {  // up
                    if (st.history_pos > 0) --st.history_pos;
                    st.buffer = history[st.history_pos];
                } else if (seq[1] == 'B') {  // down
                    if (st.history_pos + 1 < history.size()) {
                        ++st.history_pos;
                        st.buffer = history[st.history_pos];
                    } else {
                        st.history_pos = history.size();
                        st.buffer.clear();
                    }
                }
            }
            Redraw(prompt, st.buffer);
            continue;
        }
        if (c == '\r' || c == '\n') {
            std::fputs("\n", stdout);
            out = st.buffer;
            break;
        }
        if (c == 0x03) {  // Ctrl-C
            st.buffer.clear();
            std::fputs("^C\n", stdout);
            out = "/__cancel";
            break;
        }
        if (c == 0x04) {  // Ctrl-D
            if (st.buffer.empty()) {
                std::fputs("\n", stdout);
                out = "";
                break;
            }
            continue;
        }
        if (c == '\t') {
            std::string got = complete(prompt, st.buffer);
            if (!got.empty()) st.buffer = got;
            Redraw(prompt, st.buffer);
            continue;
        }
        if (c == '\x7f' || c == '\b') {
            while (!st.buffer.empty() &&
                   (static_cast<unsigned char>(st.buffer.back()) & 0xC0) == 0x80)
                st.buffer.pop_back();
            if (!st.buffer.empty()) st.buffer.pop_back();
            Redraw(prompt, st.buffer);
            continue;
        }
        st.buffer += c;  // UTF-8 bytes accumulate naturally
        Redraw(prompt, st.buffer);
    }
    if (raw_ok) ::tcsetattr(0, TCSANOW, &orig);
    return out;
}
#endif

// ---------------------------------------------------------------------------
// 候选菜单（两平台共用）
// ---------------------------------------------------------------------------

enum class MenuKey { Up, Down, Enter, Esc, Digit, Cancel, Eof, Other };

#ifdef _WIN32
// 候选菜单用 ANSI 光标上移原地重绘；--no-color 时 Style 不会打开 VT，这里兜底。
void EnsureVt() {
    static bool done = false;
    if (done) return;
    done = true;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (out != INVALID_HANDLE_VALUE && GetConsoleMode(out, &mode))
        SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}

MenuKey ReadMenuKey(int& ch) {
    int c = _getwch();
    if (c == 0 || c == 0xE0) {
        int k = _getwch();
        if (k == 'H') return MenuKey::Up;
        if (k == 'P') return MenuKey::Down;
        return MenuKey::Other;
    }
    ch = c;
    if (c == L'\r' || c == L'\n') return MenuKey::Enter;
    if (c == 0x1b) return MenuKey::Esc;
    if (c == 0x03) return MenuKey::Cancel;
    if (c == 0x04) return MenuKey::Eof;
    if (c >= '0' && c <= '9') return MenuKey::Digit;
    return MenuKey::Other;
}
#else
MenuKey ReadMenuKey(int& ch) {
    unsigned char c = 0;
    if (::read(0, &c, 1) != 1) return MenuKey::Eof;
    if (c == 0x1b) {  // ESC [ A/B
        unsigned char seq[2] = {0, 0};
        if (::read(0, &seq[0], 1) == 1 && seq[0] == '[' && ::read(0, &seq[1], 1) == 1) {
            if (seq[1] == 'A') return MenuKey::Up;
            if (seq[1] == 'B') return MenuKey::Down;
        }
        return MenuKey::Esc;
    }
    ch = c;
    if (c == '\r' || c == '\n') return MenuKey::Enter;
    if (c == 0x03) return MenuKey::Cancel;
    if (c == 0x04) return MenuKey::Eof;
    if (c >= '0' && c <= '9') return MenuKey::Digit;
    return MenuKey::Other;
}
#endif

constexpr size_t kMenuRows = 12;

// 候选行：hint（中文 desc / 人物名）为主显示，插入值作次要信息。
std::string CandidateLabel(const ReplCompletion& c) {
    if (!c.hint.empty()) return c.hint;
    size_t sp = c.text.find_last_of(" \t");
    return sp == std::string::npos ? c.text : c.text.substr(sp + 1);
}

std::string CandidateCode(const ReplCompletion& c) {
    if (c.hint.empty()) return {};
    size_t sp = c.text.find_last_of(" \t");
    return sp == std::string::npos ? c.text : c.text.substr(sp + 1);
}

// 重绘菜单：first=false 时先上移 n 行原地覆盖（光标停在提示行）。
void RenderMenu(const std::vector<ReplCompletion>& cands, int sel, bool first) {
    const size_t n = std::min(cands.size(), kMenuRows);
    std::string out;
    if (!first) out += "\x1b[" + std::to_string(n) + "A";
    for (size_t i = 0; i < n; ++i) {
        const bool on = static_cast<int>(i) == sel;
        const std::string row = "  " + std::to_string(i + 1) + ") ";
        const std::string label = CandidateLabel(cands[i]);
        const std::string code = CandidateCode(cands[i]);
        out += "\x1b[K";
        if (on) {
            out += Style::BoldCyan(row + label);
            if (!code.empty()) out += "  " + Style::Cyan(code);
        } else {
            out += Style::Dim(row) + label;
            if (!code.empty()) out += "  " + Style::Dim(code);
        }
        out += "\n";
    }
    std::string hint = "  ↑↓ 选择 · 数字直达 · Enter 接受 · Esc 返回编辑";
    if (cands.size() > n)
        hint += "（共 " + std::to_string(cands.size()) + " 个，继续输入可缩小范围）";
    out += "\x1b[K" + Style::Dim(hint);
    std::fputs(out.c_str(), stdout);
    std::fflush(stdout);
}

// 编号候选菜单：↑↓ 移动、数字直达、Enter 接受、Esc 取消。
// 返回被接受的候选下标，-1 = 取消。
int PickCandidate(const std::vector<ReplCompletion>& cands) {
    if (cands.empty()) return -1;
#ifdef _WIN32
    EnsureVt();
#endif
    std::fputs("\n", stdout);
    int sel = 0;
    int pending = 0;
    RenderMenu(cands, sel, true);
    for (;;) {
        int ch = 0;
        const MenuKey k = ReadMenuKey(ch);
        if (k == MenuKey::Up) {
            if (sel > 0) --sel;
            pending = 0;
            RenderMenu(cands, sel, false);
        } else if (k == MenuKey::Down) {
            if (sel + 1 < static_cast<int>(std::min(cands.size(), kMenuRows))) ++sel;
            pending = 0;
            RenderMenu(cands, sel, false);
        } else if (k == MenuKey::Digit) {
            const int d = ch - '0';
            if (pending == 0 && d == 0) pending = 10;  // 0 = 第 10 项
            else pending = pending * 10 + d;
            if (pending < 1 || pending > static_cast<int>(cands.size())) {
                pending = 0;  // 非法编号：忽略
                continue;
            }
            sel = pending - 1;
            RenderMenu(cands, sel, false);
            if (pending * 10 > static_cast<int>(cands.size())) {  // 无法再延长 → 直达
                std::fputs("\n", stdout);
                return sel;
            }
        } else if (k == MenuKey::Enter) {
            if (pending >= 1 && pending <= static_cast<int>(cands.size())) sel = pending - 1;
            std::fputs("\n", stdout);
            return sel;
        } else if (k == MenuKey::Esc || k == MenuKey::Cancel || k == MenuKey::Eof) {
            std::fputs("\n", stdout);
            return -1;
        }
    }
}

// 管道 / 非交互模式的一次性罗列（旧 Complete() 的观感，不读键）。
void ListCandidates(const std::vector<ReplCompletion>& cands) {
    if (cands.empty()) return;
    const size_t n = std::min(cands.size(), kMenuRows);
    std::ostringstream os;
    os << "\n";
    for (size_t i = 0; i < n; ++i) {
        os << "  " << Style::Cyan(CandidateLabel(cands[i]));
        const std::string code = CandidateCode(cands[i]);
        if (!code.empty()) os << "  " << Style::Dim(code);
        os << "\n";
    }
    if (cands.size() > n) os << Style::Dim("  ... (" + std::to_string(cands.size()) + ")") << "\n";
    std::fputs(os.str().c_str(), stdout);
}

void RunShell(const std::string& cmd) {
    if (Trim(cmd).empty()) {
        std::fputs(Style::Dim("用法: !<命令>（如 !git status）") .c_str(), stdout);
        std::fputs("\n", stdout);
        return;
    }
    std::fputs(Style::Dim("! " + cmd) .c_str(), stdout);
    std::fputs("\n", stdout);
#ifdef _WIN32
    int n = MultiByteToWideChar(CP_UTF8, 0, cmd.c_str(), -1, nullptr, 0);
    std::wstring w(static_cast<size_t>(n > 0 ? n - 1 : 0), L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, cmd.c_str(), -1, w.data(), n);
    int rc = _wsystem(w.c_str());
#else
    int rc = std::system(cmd.c_str());
#endif
    if (rc != 0)
        std::fputs((Style::Yellow("warning: shell 退出码 " + std::to_string(rc)) + "\n").c_str(),
                   stdout);
}

// The /status surface: same facts as the banner, no panel.
void PrintStatus(const std::string& workspace, size_t mods_count, size_t cfg_count,
                 const std::string& current_mod, const std::string& no_code_text) {
    std::ostringstream os;
    os << "Workspace: " << (workspace.empty() ? "-" : workspace) << "\n"
       << "Mods: " << mods_count << "  Cfgs: " << cfg_count << "  当前模组: "
       << (current_mod.empty() ? "-" : current_mod) << "\n"
       << "无代码模式: " << no_code_text << "\n";
    std::fputs(os.str().c_str(), stdout);
}

// Load best-effort history file (missing file is fine).
std::vector<std::string> LoadHistory(const std::string& path) {
    std::vector<std::string> out;
    if (path.empty()) return out;
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return out;
    std::string line;
    int ch;
    while ((ch = std::fgetc(f)) != EOF) {
        if (ch == '\n') {
            if (!line.empty()) out.push_back(line);
            line.clear();
        } else if (ch != '\r') {
            line += static_cast<char>(ch);
        }
    }
    if (!line.empty()) out.push_back(line);
    std::fclose(f);
    return out;
}

void SaveHistory(const std::string& path, const std::vector<std::string>& history) {
    if (path.empty() || history.empty()) return;
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    for (const auto& h : history) std::fputs((h + "\n").c_str(), f);
    std::fclose(f);
}

// 命令名（POST /api/usage 的 key）：跳过全局 flag 及其取值，取第一个词。
std::string CommandKey(const std::vector<std::string>& tokens) {
    static const std::set<std::string> kValueFlags = {"--url", "--data-root", "--workspace",
                                                      "--mod", "--timeout"};
    for (size_t i = 0; i < tokens.size(); ++i) {
        const std::string& t = tokens[i];
        if (t.empty()) continue;
        if (t[0] == '-') {
            const size_t eq = t.find('=');
            const std::string flag = eq == std::string::npos ? t : t.substr(0, eq);
            if (eq == std::string::npos && kValueFlags.count(flag)) ++i;  // 跳过取值
            continue;
        }
        std::string k = t;
        if (k[0] == '/') k = k.substr(1);
        return LowerAscii(k);
    }
    return {};
}

// 候选接受后回填的 usage key：在池里找回插入值（text 后缀匹配，去掉 JSON 引号）。
std::string AcceptedValue(const std::vector<CompletionItem>& pool, const std::string& text) {
    std::string t = text;
    if (t.size() >= 2 && (t.back() == '"' || t.back() == '\'')) t.pop_back();
    std::string best;
    for (const auto& it : pool) {
        if (it.value.empty() || t.size() < it.value.size()) continue;
        if (t.compare(t.size() - it.value.size(), it.value.size(), it.value) != 0) continue;
        if (it.value.size() > best.size()) best = it.value;
    }
    return best;
}

}  // namespace

int RunRepl(const GlobalFlags& flags, const ReplHost& host) {
    (void)flags;
    // ---- banner facts -------------------------------------------------------
    std::string workspace, current_mod;
    std::vector<std::string> mod_names;
    size_t cfg_count = 0;
    int status = 0;
    json state = host.http(state_request(), &status);
    if (status == 200 && state.is_object()) workspace = state.value("workspace_root", "");
    json mods_body = host.http(HttpRequestSpec{"GET", "/api/mods", {}, json()}, &status);
    if (status == 200 && mods_body.is_object()) {
        current_mod = mods_body.value("selected", "");
        if (mods_body.contains("mods") && mods_body.at("mods").is_array())
            for (const auto& m : mods_body.at("mods"))
                mod_names.push_back(m.value("name", ""));
    }
    json cfg_body = host.http(HttpRequestSpec{"GET", "/api/cfg", {}, json()}, &status);
    std::vector<std::string> cfg_names;
    if (status == 200 && cfg_body.is_object()) {
        if (cfg_body.contains("cfg_files") && cfg_body.at("cfg_files").is_array()) {
            cfg_count = cfg_body.at("cfg_files").size();
            for (const auto& f : cfg_body.at("cfg_files"))
                cfg_names.push_back(f.is_string() ? f.get<std::string>() : f.dump());
        }
    }

    // ---- M3: 编辑器共享设置（无代码模式），启动读一次并缓存 ------------------
    bool no_code = false, no_code_known = false;
    {
        json sb = host.http(editor_settings_get_request(), &status);
        if (status == 200) no_code = parse_no_code_mode(sb, &no_code_known);
    }
    auto no_code_text = [&]() -> std::string {
        if (!no_code_known) return "未知";
        return no_code ? "开" : "关";
    };
    PrintBanner(workspace, mod_names.size(), mod_names, cfg_count, current_mod, no_code_text());

    // ---- 补全池（会话级缓存；只在 Tab / 执行后按需刷新） --------------------
    std::vector<CompletionItem> commands = top_level_commands();
    {
        // REPL 专属命令排在最前（与旧 commands 池的观感一致）。
        const std::vector<CompletionItem> repl_only = {
            {"help", "显示 REPL 帮助"},   {"use", "切换当前模组"},
            {"status", "查看工作区状态"}, {"clear", "清屏"},
            {"exit", "退出 REPL"},        {"quit", "退出 REPL"},
        };
        commands.insert(commands.begin(), repl_only.begin(), repl_only.end());
    }
    std::vector<CompletionItem> slash_commands;
    slash_commands.reserve(commands.size());
    for (const auto& c : commands) slash_commands.push_back({"/" + c.value, c.hint});

    std::vector<CompletionItem> table_items, mod_items;
    for (const auto& n : cfg_names) table_items.push_back({n, ""});
    for (const auto& n : mod_names) mod_items.push_back({n, ""});

    // 高频命令（GET /api/usage?kind=command&limit=10）：启动拉一次，执行后刷新。
    std::vector<CompletionItem> recent_pool;
    auto command_hint = [&](const std::string& key) -> std::string {
        for (const auto& c : commands)
            if (c.value == key) return c.hint;
        return {};
    };
    auto refresh_recent = [&]() {
        HttpRequestSpec spec{"GET", "/api/usage", {}, json()};
        spec.query.emplace_back("kind", "command");
        spec.query.emplace_back("limit", "10");
        json body = host.http(spec, &status);
        recent_pool.clear();
        if (status == 200 && body.is_object() && body.contains("items") &&
            body["items"].is_array()) {
            for (const auto& it : body["items"]) {
                const std::string key = it.value("key", "");
                if (!key.empty()) recent_pool.push_back({key, command_hint(key)});
            }
        }
    };
    refresh_recent();

    // effect_suggest 池（按 mode 缓存；q 空 = 后端最近使用 + 目录默认候选）。
    std::map<std::string, std::vector<CompletionItem>> effect_pool;
    std::map<std::string, std::string> effect_raw;  // mode\ncode -> raw_code 模板
    auto ensure_effects = [&](const std::string& mode) {
        if (effect_pool.count(mode)) return;
        HttpRequestSpec spec{"GET", "/api/effect_suggest", {}, json()};
        spec.query.emplace_back("q", "");
        spec.query.emplace_back("mode", mode);
        json body = host.http(spec, &status);
        std::vector<CompletionItem> items;
        if (status == 200 && body.is_object() && body.contains("items") &&
            body["items"].is_array()) {
            for (const auto& it : body["items"]) {
                const std::string code = it.value("code", "");
                const std::string desc = it.value("desc", "");
                const std::string raw = it.value("raw_code", "");
                if (code.empty()) continue;
                items.push_back({code, desc});
                if (!raw.empty()) effect_raw[mode + "\n" + code] = raw;
            }
        }
        effect_pool[mode] = std::move(items);
    };

    // 人物目录（GET /api/roles，全量缓存一次）。
    std::vector<CompletionItem> role_pool;
    bool roles_loaded = false;
    auto ensure_roles = [&]() {
        if (roles_loaded) return;
        roles_loaded = true;
        json body = host.http(HttpRequestSpec{"GET", "/api/roles", {}, json()}, &status);
        if (status == 200 && body.is_object() && body.contains("roles") &&
            body["roles"].is_array()) {
            for (const auto& r : body["roles"]) {
                const std::string id = r.value("id", "");
                if (!id.empty()) role_pool.push_back({id, r.value("name", "")});
            }
        }
    };

    // 路径池：当前目录条目（Tab 时现取，只有路径槽才用）。
    auto path_pool = []() {
        std::vector<CompletionItem> out;
        std::error_code ec;
        for (std::filesystem::directory_iterator it(std::filesystem::current_path(), ec), end;
             it != end; it.increment(ec)) {
            const std::string name = sa_core::paths::path_to_utf8(it->path().filename());
            const bool dir = it->is_directory(ec);
            out.push_back({name + (dir ? "/" : ""), dir ? "目录" : "文件"});
        }
        return out;
    };

    // 上报一次 usage（失败静默：统计永远不能影响命令本身）。
    auto report_usage = [&](const std::string& kind, const std::string& key) {
        if (kind.empty() || key.empty()) return;
        json body;
        body["kind"] = kind;
        body["key"] = key;
        host.http(HttpRequestSpec{"POST", "/api/usage", {}, std::move(body)}, nullptr);
    };

    std::vector<std::string> history = LoadHistory(host.history_path);
    std::vector<std::string> last_tokens;
    const bool interactive = StdinIsTty() && host.run_tokens;

    // Tab：ReplComplete 分流 → 唯一候选直接补全，歧义时交互菜单 / 管道罗列。
    auto complete = [&](const std::string&, const std::string& buffer) -> std::string {
        const CompletionPlan plan = plan_completion(buffer);
        std::vector<std::string> toks = split_repl_tokens(buffer);
        std::string cmd, sub;
        if (!toks.empty()) {
            cmd = LowerAscii(toks[0]);
            if (!cmd.empty() && cmd[0] == '/') cmd = cmd.substr(1);
            if (toks.size() >= 2 && !toks[1].empty() && toks[1][0] != '-')
                sub = LowerAscii(toks[1]);
        }
        const std::string effect_mode = plan.effect_mode.empty() ? "effect" : plan.effect_mode;
        if (plan.slot == CompletionSlot::Effect) ensure_effects(effect_mode);
        if (plan.slot == CompletionSlot::Role) ensure_roles();

        CompletionCtx ctx;
        ctx.commands = commands;
        ctx.slash_commands = slash_commands;
        ctx.subcommands = command_subcommands(cmd);
        ctx.flags = command_flags(cmd, sub);
        ctx.recent = recent_pool;
        ctx.tables = table_items;
        ctx.mods = mod_items;
        ctx.roles = role_pool;
        ctx.paths = plan.slot == CompletionSlot::Path ? path_pool() : std::vector<CompletionItem>{};
        if (plan.slot == CompletionSlot::Effect) {
            auto it = effect_pool.find(effect_mode);
            if (it != effect_pool.end()) ctx.effects = it->second;
        }

        const std::vector<ReplCompletion> cands = ReplComplete(buffer, ctx);
        if (cands.empty()) return "";
        int sel = 0;
        if (cands.size() > 1) {
            if (!interactive) {
                ListCandidates(cands);  // 管道模式保留旧一次性罗列
                return "";
            }
            sel = PickCandidate(cands);
            if (sel < 0) return "";
        }
        // 接受即上报（effect 记 raw_code 模板，人物记 id，表记表名）。
        if (plan.slot == CompletionSlot::Effect) {
            const std::string code = AcceptedValue(ctx.effects, cands[sel].text);
            auto it = effect_raw.find(effect_mode + "\n" + code);
            report_usage(effect_mode, it != effect_raw.end() ? it->second : code);
        } else if (plan.slot == CompletionSlot::Role) {
            report_usage("role", AcceptedValue(ctx.roles, cands[sel].text));
        } else if (plan.slot == CompletionSlot::Table) {
            report_usage("table", AcceptedValue(ctx.tables, cands[sel].text));
        }
        return cands[sel].text;
    };

    // 执行一条命令：POST usage（key=命令名）→ 跑 → 刷新高频池。
    auto exec_tokens = [&](const std::vector<std::string>& tokens) {
        report_usage("command", CommandKey(tokens));
        const int rc = host.run_tokens(tokens);
        refresh_recent();
        return rc;
    };

    LineState st;
    for (;;) {
        std::string prompt =
            Style::Dim("[") + Style::Green(current_mod.empty() ? "-" : current_mod) +
            Style::Dim("]") + Style::BoldCyan("› ");
        std::string line;
        if (interactive) {
            st.buffer.clear();
            st.history_pos = history.size();
#ifdef _WIN32
            line = ReadLineWin(prompt, st, history, complete);
#else
            line = ReadLinePosix(prompt, st, history, complete);
#endif
        } else {
            std::fputs(prompt.c_str(), stdout);
            std::fflush(stdout);
            if (!std::getline(std::cin, line)) {
                std::fputs("\n", stdout);
                break;  // EOF: clean exit
            }
            // Piped mode never echoes the keystrokes back, so log the line
            // (dim) to keep transcripts readable.
            std::fputs((Style::Dim(Trim(line)) + "\n").c_str(), stdout);
        }

        ReplLine cl = classify_repl_line(line);
        if (cl.kind == ReplLine::Empty) {
            if (last_tokens.empty()) continue;
            std::fputs((Style::Dim("↻ " + last_tokens[0] +
                                   (last_tokens.size() > 1 ? " …" : "")) + "\n")
                           .c_str(),
                       stdout);
            cl = ReplLine{ReplLine::Command, ""};
            exec_tokens(last_tokens);
            continue;
        }
        if (cl.kind == ReplLine::Quit) break;
        if (interactive && !Trim(line).empty() && (history.empty() || history.back() != line)) {
            history.push_back(Trim(line));
            st.history_pos = history.size();
        }
        if (cl.kind == ReplLine::Shell) {
            RunShell(cl.payload);
            continue;
        }
        if (cl.kind == ReplLine::Slash) {
            std::string word = cl.payload;
            size_t sp = word.find_first_of(" \t");
            std::string head = LowerAscii(sp == std::string::npos ? word : word.substr(0, sp));
            std::string rest = sp == std::string::npos ? "" : Trim(word.substr(sp + 1));
            bool passthrough = false;
            for (const char* p : kPassThrough)
                if (head == p) passthrough = true;
            if (passthrough) {
                std::vector<std::string> tokens = split_repl_tokens(rest);
                tokens.insert(tokens.begin(),
                              head == "plugins" ? std::string("plugin") : head);
                last_tokens = tokens;
                exec_tokens(tokens);
            } else if (head == "help") {
                PrintHelp();
            } else if (head == "clear") {
                std::fputs("\x1b[2J\x1b[H", stdout);  // no-op styling-wise, harmless piped
            } else if (head == "use") {
                if (rest.empty()) {
                    std::fputs((Style::Yellow("warning: 用法 /use <模组名>") + "\n").c_str(),
                               stdout);
                    continue;
                }
                std::vector<std::string> tokens{"mods", "select", rest};
                last_tokens = tokens;
                int rc = exec_tokens(tokens);
                if (rc == 0) current_mod = rest;
            } else if (head == "status") {
                PrintStatus(workspace, mod_names.size(), cfg_count, current_mod, no_code_text());
            } else if (head == "settings") {
                // 无参 = show；`/settings no-code on|off` 走正常语法（渲染/退出码一致）。
                std::vector<std::string> args = split_repl_tokens(rest);
                std::vector<std::string> tokens{"settings"};
                if (!args.empty() && (LowerAscii(args[0]) == "no-code" ||
                                      LowerAscii(args[0]) == "nocode")) {
                    tokens.insert(tokens.end(), args.begin(), args.end());
                } else {
                    tokens.push_back("no-code");
                    tokens.insert(tokens.end(), args.begin(), args.end());
                }
                if (args.empty()) tokens.push_back("show");
                last_tokens = tokens;
                int rc = exec_tokens(tokens);
                if (rc == 0 && !args.empty()) {
                    // `/settings no-code on` 与 `/settings on` 都取最后一个词。
                    const std::string v = LowerAscii(args.back());
                    if (v == "on" || v == "off") {
                        no_code = v == "on";
                        no_code_known = true;
                    }
                }
            } else {
                std::fputs((Style::Yellow("warning: 未知命令 /" + head) + " — " +
                            Style::Dim("/help 查看全部") + "\n")
                               .c_str(),
                           stdout);
            }
            continue;
        }

        // Plain command — with the Alpha's @提及 shorthand.
        std::vector<std::string> tokens = split_repl_tokens(cl.payload);
        if (!tokens.empty() && tokens[0].size() > 1 && tokens[0][0] == '@') {
            std::string name = tokens[0].substr(1);
            std::string id;
            size_t colon = name.find(':');
            if (colon != std::string::npos) {
                id = name.substr(colon + 1);
                name = name.substr(0, colon);
            }
            if (LowerAscii(name) == "role") {
                // @role:<名字|id> → cfg get PersonCfg --id <id>
                ensure_roles();
                std::string rid;
                for (const auto& r : role_pool) {
                    if (r.value == id || (!r.hint.empty() && r.hint == id)) {
                        rid = r.value;
                        break;
                    }
                }
                if (rid.empty() && !id.empty()) {
                    std::vector<std::string> hits;
                    for (const auto& r : role_pool)
                        if (!r.hint.empty() && FuzzyScore(id, r.hint) > 0) hits.push_back(r.value);
                    if (hits.size() == 1) rid = hits[0];
                }
                if (rid.empty()) {
                    std::fputs((Style::Yellow("warning: 未知人物 " + id) + "\n").c_str(), stdout);
                    continue;
                }
                tokens = {"cfg", "get", "PersonCfg", "--id", rid};
            } else {
                bool is_mod = false;
                for (const auto& m : mod_names)
                    if (LowerAscii(m) == LowerAscii(name)) is_mod = true;
                if (is_mod) {
                    tokens = {"mods", "select", name};
                } else {
                    tokens = {"cfg", "get", name};
                    if (!id.empty()) tokens.push_back("--id"), tokens.push_back(id);
                }
            }
        }
        if (tokens.empty()) continue;
        last_tokens = tokens;
        exec_tokens(tokens);
        // A `mods select` inside a plain command updates the prompt context too.
        if (tokens.size() >= 3 && tokens[0] == "mods" && tokens[1] == "select")
            current_mod = tokens[2];
    }
    SaveHistory(host.history_path, history);
    std::fputs(Style::Dim("再见") .c_str(), stdout);
    std::fputs("\n", stdout);
    return 0;
}

}  // namespace sa_cli
