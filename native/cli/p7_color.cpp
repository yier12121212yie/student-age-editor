#include "p7_color.h"

#include <cstdio>
#include <optional>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif

namespace sa_cli {

bool Style::enabled_ = false;
bool Style::light_ = false;

// 两张 SGR 码表；下标即 Style::Role 枚举顺序（kBold..kPrompt）。
// 暗底表是既有行为（测试与管道消费方断言逐字节不变的基准）；亮底表只借终端
// 调色板里最稳的高对比槽位：浅底几乎不可读的黄/青走加粗变体，青色角色
// （kColumn/kPrompt）改用蓝色系 34/1;34。公开 helper 与签名零改动。
const char* const kDarkCodes[] = {
    "1",     // kBold
    "2",     // kDim
    "31",    // kErr
    "32",    // kOk
    "33",    // kWarn
    "36",    // kColumn
    "1;32",  // kId
    "1;36",  // kPrompt
};
const char* const kLightCodes[] = {
    "1",     // kBold
    "2",     // kDim
    "1;31",  // kErr
    "1;32",  // kOk
    "1;33",  // kWarn
    "34",    // kColumn
    "1;32",  // kId
    "1;34",  // kPrompt
};
static_assert(sizeof(kDarkCodes) / sizeof(kDarkCodes[0]) == 8,
              "kDarkCodes must stay index-aligned with Style::Role");
static_assert(sizeof(kLightCodes) / sizeof(kLightCodes[0]) == 8,
              "kLightCodes must stay index-aligned with Style::Role");

const char* Style::Code(Role role) {
    return (light_ ? kLightCodes : kDarkCodes)[role];
}

namespace {

// 单个外观取值 → 可选浅底判定。"light"/"dark" 明确表态；空串、"system"、
// 非法值返回 nullopt 落穿到优先级下一级（终端读不到 OS 调色板，
// "system" 只能交给 COLORFGBG 探测兜底）。
std::optional<bool> ParseAppearanceValue(const std::string& v) {
    if (v == "light") return true;
    if (v == "dark") return false;
    return std::nullopt;
}

}  // namespace

bool ResolveLightMode(const std::string& flag, const std::string& env,
                      const std::string& server, const std::string& colorfgbg) {
    for (const std::string* level : {&flag, &env, &server}) {
        if (auto decided = ParseAppearanceValue(*level)) return *decided;
    }
    // COLORFGBG 形如 "fg;bg"（部分终端 "fg;x;bg"）：读末字段，7(白)/15(亮白)
    // 视为浅底；缺失、非数字、其他值一律暗色。
    std::string bg = colorfgbg;
    const auto sep = bg.find_last_of(';');
    if (sep != std::string::npos) bg = bg.substr(sep + 1);
    if (bg.empty() || bg.size() > 2) return false;
    for (char ch : bg)
        if (ch < '0' || ch > '9') return false;
    const int index = std::stoi(bg);
    return index == 7 || index == 15;
}

void Style::Init(int mode) {
    if (mode == 0) {
        enabled_ = false;
        return;
    }
    bool tty = false;
#ifdef _WIN32
    tty = _isatty(_fileno(stdout)) != 0;
#else
    tty = ::isatty(::fileno(stdout)) != 0;
#endif
    enabled_ = mode == 1 || tty;
    if (!enabled_) return;
#ifdef _WIN32
    // Win10+ consoles ship the VT renderer behind a mode flag; without it the
    // SGR bytes print literally. (Windows Terminal / VSCode terminals have it
    // on already and the call is a no-op there.)
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode_flags = 0;
    if (out != INVALID_HANDLE_VALUE && GetConsoleMode(out, &mode_flags))
        SetConsoleMode(out, mode_flags | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
#endif
}

std::string Style::Wrap(const char* code, const std::string& s) {
    if (!enabled_ || s.empty()) return s;
    return "\x1b[" + std::string(code) + "m" + s + "\x1b[0m";
}

}  // namespace sa_cli
