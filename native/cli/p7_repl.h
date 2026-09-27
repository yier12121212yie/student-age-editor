// p7_repl.h — the Alpha-v0.3 "类 Claude Code" interactive CLI mode.
//
// The Python CLI's no-args run opened a prompt_toolkit REPL: cyan welcome
// panel, ` {当前模组}› ` prompt, slash commands, @提及, !shell, empty-line
// repeat. This port keeps that surface on top of the native execution path —
// every real command still goes through parse_command_line/make_plan via the
// host's run_tokens (embedded server or --url, exactly like a one-shot run).
// Only the line editor/stdio live here; parsing and rendering stay in
// p7_cli_logic where sa_tests can reach them. Compiled into backend_cli only.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "p7_cli_logic.h"

namespace sa_cli {

struct ReplHost {
    // Execute one tokenized command line through the normal CLI path (embedded
    // server / --url), printing like a one-shot run. Returns the exit code.
    std::function<int(const std::vector<std::string>& tokens)> run_tokens;
    // Raw HTTP for the banner/status surfaces (state, mods, cfg listings).
    std::function<json(const HttpRequestSpec& spec, int* status)> http;
    // Best-effort history file ("" = memory only). Created on save, never fatal.
    std::string history_path;
};

// Enter the interactive loop. Returns 0 on clean exit (/exit, Ctrl-D, EOF).
int RunRepl(const GlobalFlags& flags, const ReplHost& host);

}  // namespace sa_cli
