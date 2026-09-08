#include "sa_core/steam_paths.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <set>

#include "sa_core/env_store.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace sa_core {
namespace steam_paths {
namespace {

namespace fs = std::filesystem;

std::string getenv_str(const char* name) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
}

// os.path.expanduser("~"): USERPROFILE wins on Windows, then HOME; POSIX HOME.
std::string home_dir() {
#ifdef _WIN32
    std::string up = getenv_str("USERPROFILE");
    if (!up.empty()) return up;
    return getenv_str("HOME");
#else
    return getenv_str("HOME");
#endif
}

// normcase(normpath(x)) — the Python dedup key. Unlike paths::path_key this
// never prepends the cwd (a relative value stays relative), so it matches
// os.path.normpath semantics on odd vdf payloads.
std::string norm_key(const std::string& p) {
    std::error_code ec;
    fs::path n = paths::to_path(p).lexically_normal();
    // normpath("C:\a\..\") == "C:\a"; lexically_normal keeps a trailing dot
    // marker only for "x/.." forms — close enough, both sides of every
    // comparison run through this same function.
    return paths::normcase(paths::path_to_utf8(n));
}

// steam_paths.py:75 — open(vdf, "r", encoding="utf-8", errors="replace").
// The sig variant additionally tolerates a leading BOM (superset; real Valve
// files have none).
std::string read_text_replace(const std::string& p) {
    auto raw = paths::read_bytes(p);
    if (!raw) return {};
    return decode_utf8_sig_replace(*raw);
}

}  // namespace

// ---------------------------------------------------------------------------
// VDF enumeration (Valve KeyValue text)
// ---------------------------------------------------------------------------

namespace {

struct VdfScanner {
    const std::string& s;
    size_t i = 0;

    explicit VdfScanner(const std::string& text) : s(text) {}

    void skip_trivia() {
        while (i < s.size()) {
            char c = s[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                ++i;
            } else if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') {
                while (i < s.size() && s[i] != '\n') ++i;  // line comment
            } else {
                break;
            }
        }
    }

    // One token: "" (EOF / unmatched '}'), "{", "}", or a (possibly quoted)
    // word. Quoted strings honour \\ and \" escapes; any other backslash
    // sequence passes through verbatim (matches Valve's own KeyValue reader
    // and Python's val.replace("\\\\", "\\") on realistic content).
    std::string next_token(bool* quoted_out = nullptr) {
        skip_trivia();
        if (quoted_out) *quoted_out = false;
        if (i >= s.size()) return {};
        char c = s[i];
        if (c == '{' || c == '}') {
            ++i;
            return std::string(1, c);
        }
        std::string tok;
        if (c == '"') {
            ++i;
            if (quoted_out) *quoted_out = true;
            while (i < s.size()) {
                char ch = s[i++];
                if (ch == '"') break;
                if (ch == '\\' && i < s.size()) {
                    char nx = s[i];
                    if (nx == '\\' || nx == '"') {
                        tok += nx;
                        ++i;
                        continue;
                    }
                    tok += ch;  // unknown escape: keep the backslash
                    continue;
                }
                tok += ch;
            }
            return tok;
        }
        // bare word: up to whitespace / brace / quote
        while (i < s.size()) {
            char ch = s[i];
            if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '{' ||
                ch == '}' || ch == '"') {
                break;
            }
            tok += ch;
            ++i;
        }
        return tok;
    }
};

// One block: consume tokens until the matching "}" (or EOF). A NAME followed
// by a string contributes its value when NAME == key; a NAME (or a bare "{")
// followed by "{" recurses, so "path" entries are collected at any nesting
// depth — same effective behaviour as the Python line heuristic on real
// libraryfolders.vdf files.
void collect(VdfScanner& sc, const std::string& key, std::vector<std::string>& out) {
    std::string pending;
    bool have_pending = false;
    for (;;) {
        std::string tok = sc.next_token();
        if (tok.empty() && sc.i >= sc.s.size()) {
            break;  // EOF
        }
        if (tok == "}") {
            break;  // end of this block (the caller's loop resumes)
        }
        if (tok == "{") {
            // unnamed block: recurse (the pending name, if any, is irrelevant
            // to value collection — only the leaf "path" strings matter)
            collect(sc, key, out);
            have_pending = false;
            continue;
        }
        if (!have_pending) {
            pending = tok;
            have_pending = true;
            continue;
        }
        // pending NAME followed by a scalar value
        if (pending == key) out.push_back(tok);
        have_pending = false;
    }
}

}  // namespace

std::vector<std::string> vdf_collect_string_values(const std::string& text,
                                                   const std::string& key) {
    std::vector<std::string> out;
    VdfScanner sc(text);
    collect(sc, key, out);
    return out;
}

std::vector<std::string> parse_libraryfolders_vdf(const std::string& text) {
    return vdf_collect_string_values(text, "path");
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------

bool steam_detect_disabled() {
    std::string v = str::trim(getenv_str("EDITOR_DISABLE_STEAM_DETECT"));
    if (v.empty()) return false;
    v = str::lower(v);
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

std::vector<std::string> steam_root_candidates() {
    std::vector<std::string> out;
#ifdef _WIN32
    // winreg.OpenKey(HKCU, "Software\\Valve\\Steam") -> QueryValueEx("SteamPath")
    HKEY hkey = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", 0, KEY_READ,
                      &hkey) == ERROR_SUCCESS) {
        wchar_t buf[4096];
        DWORD size = sizeof(buf);
        DWORD type = 0;
        if (RegQueryValueExW(hkey, L"SteamPath", nullptr, &type,
                             reinterpret_cast<LPBYTE>(buf), &size) == ERROR_SUCCESS &&
            (type == REG_SZ || type == REG_EXPAND_SZ)) {
            int chars = static_cast<int>(size / sizeof(wchar_t));
            std::wstring w(buf, chars);
            // trim the NUL the registry may include
            while (!w.empty() && w.back() == L'\0') w.pop_back();
            int u8 = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                                         nullptr, 0, nullptr, nullptr);
            if (u8 > 0) {
                std::string s(static_cast<size_t>(u8), '\0');
                WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                                    s.data(), u8, nullptr, nullptr);
                out.push_back(s);
            }
        }
        RegCloseKey(hkey);
    }
    for (const char* env_name : {"ProgramFiles(x86)", "ProgramFiles"}) {
        std::string base = getenv_str(env_name);
        if (!base.empty()) {
            std::string p = paths::join(base, "Steam");
            if (paths::is_dir(p)) out.push_back(p);
        }
    }
    return out;
#else
    // TODO(P2-port): non-Windows hosts only run the contract isolation tests
    // here; HOME-based probing kept best-effort per the wave-2 brief.
    std::string home = home_dir();
    if (home.empty()) return out;
#if defined(SA_TARGET_MACOS)
    std::string mac = paths::join(paths::join(home, "Library"), "Application Support");
    out.push_back(paths::join(mac, "Steam"));
#else
    out.push_back(paths::join(paths::join(home, ".steam"), "steam"));
    out.push_back(paths::join(paths::join(home, ".steam"), "root"));
    out.push_back(paths::join(paths::join(paths::join(home, ".local"), "share"), "Steam"));
    std::string flatpak = paths::join(paths::join(home, ".var"), "app");
    flatpak = paths::join(flatpak, "com.valvesoftware.Steam");
    flatpak = paths::join(paths::join(paths::join(flatpak, ".local"), "share"), "Steam");
    out.push_back(flatpak);
#endif
    return out;
#endif
}

std::vector<std::string> steam_library_paths() {
    std::vector<std::string> out;
    if (steam_detect_disabled()) return out;
    std::vector<std::string> roots;
    for (const auto& r : steam_root_candidates()) {
        if (!r.empty() && paths::is_dir(r)) roots.push_back(r);
    }
    std::vector<std::string> libs;
    for (const auto& sp : roots) {
        std::string vdf = paths::join(paths::join(sp, "steamapps"), "libraryfolders.vdf");
        if (!paths::is_file(vdf)) {
            vdf = paths::join(paths::join(sp, "config"), "libraryfolders.vdf");
        }
        if (!paths::is_file(vdf)) continue;
        std::string text = read_text_replace(vdf);
        if (text.empty()) continue;
        for (const auto& val : parse_libraryfolders_vdf(text)) {
            if (!val.empty() && paths::is_dir(val)) libs.push_back(val);
        }
    }
    std::set<std::string> seen;
    for (const auto* list : {&libs, &roots}) {
        for (const auto& lib : *list) {
            if (lib.empty() || !paths::is_dir(lib)) continue;
            std::string key = norm_key(lib);
            if (seen.count(key)) continue;
            seen.insert(key);
            out.push_back(lib);
        }
    }
    return out;
}

std::vector<std::string> game_install_dirs() {
    std::vector<std::string> out;
    for (const auto& lib : steam_library_paths()) {
        out.push_back(paths::join(paths::join(lib, "steamapps"),
                                  paths::join("common", kGameDirName)));
    }
    return out;
}

std::string detect_game_aa_dir() {
    static const char* kPlatforms[] = {"StandaloneWindows64", "StandaloneLinux64",
                                       "StandaloneOSX"};
    for (const auto& game_dir : game_install_dirs()) {
        std::string aa_base = paths::join(
            paths::join(game_dir, std::string(kGameDirName) + "_Data"), "StreamingAssets");
        aa_base = paths::join(aa_base, "aa");
        for (const char* plat : kPlatforms) {
            std::string p = paths::join(aa_base, plat);
            if (paths::is_dir(p)) return p;
        }
    }
    return {};
}

std::vector<std::string> proton_mods_dirs() {
#ifdef _WIN32
    return {};  // sys.platform in ("win32","darwin") -> []
#else
    std::vector<std::string> out;
    for (const auto& lib : steam_library_paths()) {
        std::string p = paths::join(paths::join(lib, "steamapps"), "compatdata");
        p = paths::join(p, kGameAppid);
        p = paths::join(p, "pfx");
        p = paths::join(p, "drive_c");
        p = paths::join(p, "users");
        p = paths::join(p, "steamuser");
        p = paths::join(p, "AppData");
        p = paths::join(p, "LocalLow");
        p = paths::join(p, kGamePublisher);
        p = paths::join(p, kGameDirName);
        p = paths::join(p, "Mods");
        if (paths::is_dir(p)) out.push_back(p);
    }
    return out;
#endif
}

std::string user_mods_dir() {
#ifdef _WIN32
    // Windows: %USERPROFILE%\AppData\LocalLow\PakyiGame\StudentAge\Mods
    // (abspath applied; USERPROFILE missing falls back to ~, never relative).
    std::string base = getenv_str("USERPROFILE");
    if (base.empty()) base = home_dir();
    std::string p = paths::join(base, "AppData");
    p = paths::join(p, "LocalLow");
    p = paths::join(p, kGamePublisher);
    p = paths::join(p, kGameDirName);
    p = paths::join(p, "Mods");
    return paths::abs_path(p);
#else
    // darwin branch (kept behind the same #else for this build):
#if defined(SA_TARGET_MACOS)
    std::string p = paths::join(home_dir(), "Library");
    p = paths::join(p, "Application Support");
    p = paths::join(p, kGamePublisher);
    p = paths::join(p, kGameDirName);
    return paths::join(p, "Mods");
#else
    auto proton = proton_mods_dirs();
    if (!proton.empty()) return proton.front();
    // paths.platform_data_dir()/Mods (XDG_DATA_HOME or ~/.local/share).
    std::string base = getenv_str("XDG_DATA_HOME");
    if (base.empty()) base = paths::join(paths::join(home_dir(), ".local"), "share");
    return paths::join(paths::join(base, "student-age-editor"), "Mods");
#endif
#endif
}

bool workshop_override_warned = false;  // steam_paths._workshop_override_warned

std::vector<std::string> workshop_mods_roots(const std::string& editor_root) {
    std::vector<std::string> roots;
    std::string custom = env_store::read_workshop_override(editor_root);
    if (!custom.empty()) {
        if (paths::is_dir(custom)) {
            roots.push_back(custom);
        } else if (!workshop_override_warned) {
            workshop_override_warned = true;
            std::fprintf(stderr, "[editor] workshop_root 配置无效（目录不存在），已忽略：%s\n",
                         custom.c_str());
        }
    }
    // The switch suppresses discovery only: the configured override above is
    // still honoured (a user-set path is not a machine probe).
    for (const auto& lib : steam_library_paths()) {
        std::string p = paths::join(paths::join(lib, "steamapps"), "workshop");
        p = paths::join(p, "content");
        p = paths::join(p, kGameAppid);
        if (paths::is_dir(p) &&
            std::find(roots.begin(), roots.end(), p) == roots.end()) {
            roots.push_back(p);
        }
    }
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (const auto& r : roots) {
        std::string key = norm_key(r);
        if (seen.count(key)) continue;
        seen.insert(key);
        out.push_back(r);
    }
    return out;
}

}  // namespace steam_paths
}  // namespace sa_core
