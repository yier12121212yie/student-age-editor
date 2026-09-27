// p7_color.h — ANSI styling for the Alpha-v0.3 (Python rich) CLI look.
//
// The Python CLI printed bold-green ids, cyan columns and colored ok/error
// markers; the native CLI ships the same shape but colorized. Styling is a
// process-wide switch decided once at startup: on only for a TTY stdout
// (--color forces it, --no-color kills it, --json bypasses at the call sites).
// When disabled every helper is the identity, so plain-text output — and the
// sa_tests / pipe consumers that assert on it — stays byte-identical.
//
// 白日模式（day mode）：Style::SetAppearance(true) 把语义 helper 换到第二张
// SGR 码表，面向浅色终端背景。ANSI 基本色 32/33/36 是照暗底终端调的色相，
// 浅底上黄/青几乎不可读、纯绿/红对比不足；亮色表一律走加粗变体（1;32/1;33/
// 1;31）提对比，青色角色改用蓝色系（34/1;34）—— 只借终端调色板里最稳的
// 高对比槽位，不猜具体 RGB。公开方法名与签名保持不变（Bold/Dim/Red/Green/
// Yellow/Cyan/BoldGreen/BoldCyan），调用点零改动。
// 硬约束：Enabled() 为 false 时每个 helper 仍返回原串——外观表只在 Wrap 选码
// 阶段起作用，--json / 非 TTY / --no-color 的输出逐字节不变。
#pragma once

#include <string>

namespace sa_cli {

// 外观解析优先级（纯函数，无 IO，供单测真值表）：
// 显式 --appearance flag > EDITOR_APPEARANCE 环境变量 > 后端 appearanceMode
// > system/缺省时的 COLORFGBG 终端探测。非法/未知取值落穿到下一级。
// COLORFGBG 形如 "fg;bg"（部分终端 "fg;x;bg"），读末字段：7(白)/15(亮白)
// 视为浅底；缺失、非数字、其他值一律 dark（终端无法真正知道 GUI 调色板）。
bool ResolveLightMode(const std::string& flag, const std::string& env,
                      const std::string& server, const std::string& colorfgbg);

class Style {
public:
    // `mode`: -1 auto (tty probe), 0 forced off, 1 forced on. Enables the
    // Windows console VT renderer when styling will be used.
    static void Init(int mode);

    static bool Enabled() { return enabled_; }

    // 白日模式开关：true=浅底码表，false=现状暗底码表（默认）。只影响
    // Enabled() 为真时 helper 选用的 SGR 码。
    static void SetAppearance(bool light) { light_ = light; }
    static bool AppearanceLight() { return light_; }

    static std::string Wrap(const char* code, const std::string& s);

    // 语义 helper：角色 → 码表（kDarkCodes/kLightCodes，见 p7_color.cpp）。
    // Yellow 同时服务 warn 与 suggestion；BoldCyan 服务 REPL 提示符。
    static std::string Bold(const std::string& s) { return Wrap(Code(kBold), s); }
    static std::string Dim(const std::string& s) { return Wrap(Code(kDim), s); }
    static std::string Red(const std::string& s) { return Wrap(Code(kErr), s); }
    static std::string Green(const std::string& s) { return Wrap(Code(kOk), s); }
    static std::string Yellow(const std::string& s) { return Wrap(Code(kWarn), s); }
    static std::string Cyan(const std::string& s) { return Wrap(Code(kColumn), s); }
    static std::string BoldGreen(const std::string& s) { return Wrap(Code(kId), s); }
    static std::string BoldCyan(const std::string& s) { return Wrap(Code(kPrompt), s); }

private:
    // 外观角色；枚举顺序即两张码表的下标顺序。
    enum Role { kBold, kDim, kErr, kOk, kWarn, kColumn, kId, kPrompt };
    static const char* Code(Role role);

    static bool enabled_;
    static bool light_;
};

}  // namespace sa_cli
