// wip/P7/cli/p7_cli_main.cpp — backend_cli entry (P7).
//
// Architecture (see STATUS.md for the full rationale): the CLI embeds the real
// server in-process by default — sa::init_state + sa::build_router +
// sa::Httpd (the exact trio sa::server_main composes) — then talks to itself
// over loopback HTTP via sa_core::http. server_main itself is NOT used: it
// blocks in a signal loop, prints a banner to stdout and POST /api/shutdown
// self-exits with status 0, none of which is compatible with a CLI that must
// print machine-parsable output and control its own exit code. Every business
// decision still runs through the identical desktop route handlers.
//
// --url switches to pure-client mode against a running instance; env sub-
// commands are always local file operations (editor_env.json has no HTTP
// route — sa_core::env_store is the shared layer behind oobe/workspace).
//
// This file is deliberately thin: grammar, planning, rendering and exit
// policy all live in p7_cli_logic.{h,cpp} where sa_tests can reach them.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include "shellapi.h"
#endif

#include "p7_cli_logic.h"

#include "p3b_miniz_config.h"  // vendored reader-only miniz (linked via sa_server)

#include "sa_core/env_store.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/util.h"

#include "server/api_router.h"
#include "server/httpd.h"
#include "server/state.h"
#include "semantic_assets.h"  // p1::find_asset (services dir is on the include path)

namespace fs = std::filesystem;
using namespace sa_cli;

namespace {

// ---------------------------------------------------------------------------
// UTF-8 argv (Windows main() hands us the ANSI codepage — Chinese mod names
// in argv must survive, so re-read the wide command line).
// ---------------------------------------------------------------------------
std::vector<std::string> utf8_args(int argc, char** argv) {
#ifdef _WIN32
    int nw = 0;
    LPWSTR* wv = CommandLineToArgvW(GetCommandLineW(), &nw);
    if (wv) {
        std::vector<std::string> out;
        for (int i = 1; i < nw; ++i) {
            int need = WideCharToMultiByte(CP_UTF8, 0, wv[i], -1, nullptr, 0, nullptr, nullptr);
            std::string s(need > 0 ? need - 1 : 0, '\0');
            if (need > 1)
                WideCharToMultiByte(CP_UTF8, 0, wv[i], -1, s.data(), need, nullptr, nullptr);
            out.push_back(std::move(s));
        }
        LocalFree(wv);
        return out;
    }
#endif
    return std::vector<std::string>(argv + (argc > 0 ? 1 : 0), argv + argc);
}

// ---------------------------------------------------------------------------
// Embedded server
// ---------------------------------------------------------------------------
struct Embedded {
    bool active = false;
    sa::Router router;
    std::unique_ptr<sa::Httpd> httpd;
    std::string base_url;

    bool start(const std::string& workspace, std::string* err) {
        sa::init_state(workspace, std::string(), std::string());
        router = sa::build_router();
        httpd = std::make_unique<sa::Httpd>(&router);
        if (!httpd->bind_to("127.0.0.1", 0, err)) return false;
        httpd->start();
        base_url = "http://127.0.0.1:" + std::to_string(httpd->port());
        active = true;
        return true;
    }
    ~Embedded() {
        if (httpd) httpd->stop();
    }
};

// ---------------------------------------------------------------------------
// HTTP execution
// ---------------------------------------------------------------------------
struct Executed {
    bool transport_ok = false;
    int status = 0;
    std::string raw_body;
    sa_cli::json body;  // parsed (null on non-JSON)
    std::string transport_error;
};

Executed do_http(const std::string& base_url, const HttpRequestSpec& spec, double timeout) {
    Executed ex;
    sa_core::http::Request req;
    req.method = spec.method;
    req.url = build_url(base_url, spec);
    req.timeout_seconds = timeout;
    if (!spec.body.is_null()) {
        req.body = sa_core::py_dumps(spec.body);
        req.headers.emplace_back("Content-Type", "application/json");
    }
    sa_core::http::Response resp = sa_core::http::request(req);
    ex.transport_ok = resp.transport_ok();
    ex.transport_error = resp.error_message;
    if (!ex.transport_ok) return ex;
    ex.status = resp.status;
    ex.raw_body = resp.body;
    sa_cli::json parsed = sa_cli::json::parse(resp.body, nullptr, false);
    if (parsed.is_discarded()) {
        ex.body = sa_cli::json{{"_raw", resp.body}};
    } else {
        ex.body = std::move(parsed);
    }
    return ex;
}

// ---------------------------------------------------------------------------
// Local import steps (mods add --path / --zip)
// ---------------------------------------------------------------------------

bool write_text_file(const std::string& path, const std::string& text, std::string* err) {
    std::error_code ec;
    fs::path p = fs::u8path(path);
    if (p.has_parent_path()) fs::create_directories(p.parent_path(), ec);
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    if (!f) {
        if (err) *err = "cannot write: " + path;
        return false;
    }
    f.write(text.data(), static_cast<std::streamsize>(text.size()));
    return true;
}

// Zip archives frequently wrap everything in one folder. When dst itself is
// not mod-shaped but holds exactly one mod-shaped directory, lift it.
// With allow_rename (no explicit --name) and no sibling clutter, the inner
// dir is RENAMED next to dst instead — "ws/zipmod/ZipMod/" becomes
// "ws/ZipMod/" — so the imported mod carries the archive's inner directory
// name rather than the zip-file stem (what users see on disk and what
// list_mods should print). Otherwise fall back to moving contents up, which
// keeps the pre-decided target name. Returns the final mod dir, or "" when
// no lift applies/succeeded.
std::string lift_single_top_dir(const std::string& dst, bool allow_rename) {
    if (looks_like_mod_dir(dst)) return {};
    std::error_code ec;
    std::vector<std::string> dirs;
    size_t files = 0;
    for (fs::directory_iterator it(fs::u8path(dst), ec), end; it != end; it.increment(ec)) {
        if (it->is_directory(ec))
            dirs.push_back(sa_core::paths::path_to_utf8(it->path()));
        else
            ++files;
    }
    if (dirs.size() != 1 || !looks_like_mod_dir(dirs[0])) return {};
    if (allow_rename && files == 0) {
        fs::path husk = fs::u8path(dst);
        fs::path inner = fs::u8path(dirs[0]);
        fs::path target = husk.parent_path() / inner.filename();
        // The only FS we ship on is case-INsensitive: an inner dir that
        // differs from the archive-stem husk only in case ("zipmod/ZipMod")
        // makes `target` resolve to the husk itself, so the husk must be
        // staged aside before the real name frees up. A genuinely different
        // name that is already taken falls through to the in-place lift.
        bool case_collide =
            sa_core::paths::normcase(sa_core::paths::path_to_utf8(target)) ==
            sa_core::paths::normcase(dst);
        std::error_code rec;
        if ((case_collide || !fs::exists(target, rec)) && !rec) {
            fs::path moved_husk = husk;
            fs::path src_inner = inner;
            bool staged = false;
            bool ok = true;
            if (case_collide) {
                moved_husk = fs::path(dst + ".p7stage");
                std::error_code sec;
                fs::rename(husk, moved_husk, sec);
                if (sec) {
                    ok = false;
                } else {
                    staged = true;
                    src_inner = moved_husk / inner.filename();
                }
            }
            if (ok) fs::rename(src_inner, target, rec);
            if (ok && !rec) {
                std::error_code rmec;
                fs::remove(moved_husk, rmec);  // empty husk; a leftover is inert
                return sa_core::paths::path_to_utf8(target);
            }
            if (staged) {  // undo the staging for the in-place fallback
                std::error_code brec;
                fs::rename(moved_husk, husk, brec);
            }
        }
    }
    fs::path dstdir = fs::u8path(dst);
    for (fs::directory_iterator it(fs::u8path(dirs[0]), ec), end; it != end; it.increment(ec)) {
        fs::rename(it->path(), dstdir / it->path().filename(), ec);
        if (ec) return {};
    }
    std::error_code ec2;
    fs::remove(fs::u8path(dirs[0]), ec2);
    return dst;
}

bool import_path_into_workspace(const std::string& src, const std::string& workspace,
                                const std::string& name, std::string* dst_out, std::string* err) {
    std::error_code ec;
    if (!fs::is_directory(fs::u8path(src), ec)) {
        *err = "not a directory: " + src;
        return false;
    }
    if (!looks_like_mod_dir(src)) {
        *err = "源目录不是模组（缺 Cfgs/zh-cn 与 manifest.json）: " + src;
        return false;
    }
    std::string dst = sa_core::paths::join(workspace, name);
    if (sa_core::paths::exists(dst)) {
        *err = "目标已存在: " + dst;
        return false;
    }
    fs::create_directories(fs::u8path(sa_core::paths::dirname(dst)), ec);
    fs::copy(fs::u8path(src), fs::u8path(dst),
             fs::copy_options::recursive | fs::copy_options::skip_existing, ec);
    if (ec) {
        *err = "复制失败: " + ec.message();
        sa_core::paths::remove_tree(dst);
        return false;
    }
    if (dst_out) *dst_out = dst;
    return true;
}

bool import_zip_into_workspace(const std::string& zip_path, const std::string& workspace,
                               const std::string& name, bool had_name_override,
                               std::string* dst_out, std::string* err) {
    std::string dst = sa_core::paths::join(workspace, name);
    if (sa_core::paths::exists(dst)) {
        *err = "目标已存在: " + dst;
        return false;
    }
    std::error_code ec;
    fs::create_directories(fs::u8path(dst), ec);
    mz_zip_archive za;
    memset(&za, 0, sizeof(za));
    if (!mz_zip_reader_init_file(&za, zip_path.c_str(), 0)) {
        *err = "cannot open zip: " + zip_path;
        return false;
    }
    mz_uint total = mz_zip_reader_get_num_files(&za);
    for (mz_uint i = 0; i < total; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&za, i, &st)) continue;
        std::string entry = st.m_filename;
        for (auto& ch : entry)
            if (ch == '\\') ch = '/';
        while (!entry.empty() && entry.back() == '/') entry.pop_back();
        if (entry.empty() || zip_entry_reject(entry)) continue;
        std::string full = sa_core::paths::join(dst, entry);
        if (st.m_is_directory) {
            fs::create_directories(fs::u8path(full), ec);
            continue;
        }
        size_t out_size = 0;
        void* data = mz_zip_reader_extract_to_heap(&za, i, &out_size, 0);
        if (!data) {
            *err = "解压失败: " + entry;
            mz_zip_reader_end(&za);
            sa_core::paths::remove_tree(dst);
            return false;
        }
        bool ok = write_text_file(full, std::string(static_cast<char*>(data), out_size), err);
        mz_free(data);
        if (!ok) {
            mz_zip_reader_end(&za);
            sa_core::paths::remove_tree(dst);
            *err = "cannot write: " + full;
            return false;
        }
    }
    mz_zip_reader_end(&za);
    std::string lifted = lift_single_top_dir(dst, !had_name_override);
    std::string final_dir = lifted.empty() ? dst : lifted;
    if (!looks_like_mod_dir(final_dir)) {
        sa_core::paths::remove_tree(dst);
        *err = "zip 里没找到模组结构（Cfgs/zh-cn 或 manifest.json）: " + zip_path;
        return false;
    }
    if (dst_out) *dst_out = final_dir;
    return true;
}

// ---------------------------------------------------------------------------
// env subcommands (local editor_env.json)
// ---------------------------------------------------------------------------
// sa_cli:: qualification: <windows.h> also declares a GlobalFlags function.
int run_env(const Command& c, const sa_cli::GlobalFlags& g) {
    const std::string root = sa::editor_root();
    sa_cli::json env = sa_core::env_store::read_editor_env(root);
    if (c.kind == Kind::EnvGet) {
        if (!env.is_object() || !env.contains(c.env_key)) {
            std::fprintf(stderr, "error: no such key: %s\n", c.env_key.c_str());
            return 1;
        }
        const sa_cli::json& v = env.at(c.env_key);
        if (g.json) std::printf("%s\n", sa_core::py_dumps(v).c_str());
        else std::printf("%s\n", env_value_text(v).c_str());
        return 0;
    }
    sa_cli::json value;
    if (c.json_value) {
        value = sa_cli::json::parse(c.env_value, nullptr, false);
        if (value.is_discarded()) {
            std::fprintf(stderr, "error: --json-value 需要合法 JSON: %s\n", c.env_value.c_str());
            return 2;
        }
    } else {
        value = c.env_value;
    }
    try {
        sa_core::env_store::merge_editor_env(root, sa_cli::json{{c.env_key, value}});
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
    if (g.json) {
        sa_cli::json out;
        out["ok"] = true;
        out["key"] = c.env_key;
        out["value"] = value;
        std::printf("%s\n", sa_core::py_dumps(out).c_str());
    } else {
        std::printf("ok: %s = %s\n", c.env_key.c_str(), env_value_text(value).c_str());
    }
    return 0;
}

void print_utf8(const std::string& s) {
    // Raw bytes: the Git Bash pipe and CP_UTF8 consoles both take UTF-8.
    std::fwrite(s.data(), 1, s.size(), stdout);
    std::fflush(stdout);
}

void print_utf8_err(const std::string& s) {
    std::fwrite(s.data(), 1, s.size(), stderr);
    std::fflush(stderr);
}

int real_main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    sa_cli::GlobalFlags g;
    Command c;
    std::string err;
    ParseResult pr = parse_command_line(utf8_args(argc, argv), g, c, err);
    if (pr == ParseResult::Help) {
        print_utf8(err);  // help text carried in err
        return 0;
    }
    if (pr == ParseResult::UsageError) {
        print_utf8_err("error: " + err + "\n(try --help)\n");
        return 2;
    }
    if (!g.data_root.empty()) {
        // CLI flag wins over the ambient environment (CONVENTIONS 11).
#ifdef _WIN32
        _putenv_s("EDITOR_DATA_ROOT", g.data_root.c_str());
#else
        setenv("EDITOR_DATA_ROOT", g.data_root.c_str(), 1);
#endif
    }

    if (c.kind == Kind::EnvGet || c.kind == Kind::EnvSet) return run_env(c, g);

    // Build the pure plan first: plan errors are usage errors and must not
    // spin up a server.
    std::vector<HttpRequestSpec> plan;
    if (!make_plan(c, plan, err)) {
        print_utf8_err("error: " + err + "\n");
        return 2;
    }

    std::string base_url = g.url;
    Embedded embedded;
    if (base_url.empty()) {
        // The main-tree schema loader (system_routes) only probes exe_dir/..
        // and cwd; the CLI exe lives in build-P7/bin, so point
        // EDITOR_ASSETS_ROOT at the assets dir p1's deeper search finds.
        if (!getenv("EDITOR_ASSETS_ROOT")) {
            std::string asset = sa::p1::find_asset("schema.json");
            if (!asset.empty()) {
#ifdef _WIN32
                _putenv_s("EDITOR_ASSETS_ROOT", sa_core::paths::dirname(asset).c_str());
#else
                setenv("EDITOR_ASSETS_ROOT", sa_core::paths::dirname(asset).c_str(), 1);
#endif
            }
        }
        std::string bind_err;
        if (!embedded.start(g.workspace, &bind_err)) {
            print_utf8_err("error: cannot start embedded server: " + bind_err + "\n");
            return 1;
        }
        base_url = embedded.base_url;
    }

    auto exec = [&](const HttpRequestSpec& spec) { return do_http(base_url, spec, g.timeout); };

    // ---- mod selection pre-step -------------------------------------------
    // The backend keeps the selection in process memory; every embedded run
    // starts at the auto-selected first mod. --mod is the Python CLI's
    // per-command --mod parity; the persisted `cli_selected_mod` (written by
    // select/add/create) re-establishes the desktop UX of a stable
    // selection across one-shot invocations. Persisted selections that no
    // longer resolve fall back to the server default silently.
    const bool is_selecting = c.kind == Kind::ModsCreate || c.kind == Kind::ModsSelect ||
                              c.kind == Kind::ModsAddPath || c.kind == Kind::ModsAddZip;
    std::string want_mod = g.mod;
    const bool required = !want_mod.empty();
    std::string saved_root;
    if (want_mod.empty() && embedded.active && !is_selecting) {
        sa_cli::json env = sa_core::env_store::read_editor_env(sa::editor_root());
        if (env.is_object() && env.contains(kCliSelectedModKey) &&
            env.at(kCliSelectedModKey).is_object()) {
            const sa_cli::json& s = env.at(kCliSelectedModKey);
            want_mod = s.value("name", "");
            saved_root = s.value("root", "");
        }
    }
    if (!want_mod.empty()) {
        Executed sr = exec(mod_select_request(want_mod, saved_root));
        bool ok = sr.transport_ok && sr.status >= 200 && sr.status <= 299;
        if (!ok && !required && !saved_root.empty()) {
            sr = exec(mod_select_request(want_mod));  // stale root -> name lookup
            ok = sr.transport_ok && sr.status >= 200 && sr.status <= 299;
        }
        if (!ok) {
            if (required) {
                if (!sr.transport_ok) {
                    print_utf8_err("error: transport: " + sr.transport_error + "\n");
                    return 3;
                }
                if (g.json) print_utf8(sr.raw_body + "\n");
                print_utf8_err(error_text(sr.body) + "\n");
                return 1;
            }
            // stale persisted selection: proceed with the server default.
        }
    }

    // Multi-step commands: imports interleave a local FS step between
    // GET /api/state (plan[0]) and POST select (plan[1]); validate-auto mode
    // derives its POST from the plan[0] GET response.
    const bool is_import = c.kind == Kind::ModsAddPath || c.kind == Kind::ModsAddZip;
    const bool validate_auto = c.kind == Kind::Validate && !c.has_data;
    auto bail = [](const Executed& ex) {
        if (!ex.transport_ok) {
            print_utf8_err("error: transport: " + ex.transport_error + "\n");
            return 3;
        }
        return 0;
    };
    auto bail_http = [&](const Executed& ex) {
        if (ex.status >= 200 && ex.status <= 299) return 0;
        if (g.json) print_utf8(ex.raw_body + "\n");
        print_utf8_err(error_text(ex.body) + "\n");
        return 1;
    };
    HttpRequestSpec final_spec = plan.empty() ? HttpRequestSpec{} : plan[0];
    if (is_import) {
        Executed st = exec(plan[0]);
        int ec = bail(st);
        if (ec) return ec;
        ec = bail_http(st);
        if (ec) return ec;
        std::string workspace = st.body.value("workspace_root", "");
        std::string name = import_target_name(c.kind == Kind::ModsAddPath ? c.path : c.zip,
                                              c.kind == Kind::ModsAddZip, c.mod_name);
        std::string ierr, dst;
        bool ok = c.kind == Kind::ModsAddPath
                      ? import_path_into_workspace(c.path, workspace, name, &dst, &ierr)
                      : import_zip_into_workspace(c.zip, workspace, name, !c.mod_name.empty(),
                                                  &dst, &ierr);
        if (!ok) {
            print_utf8_err("error: " + ierr + "\n");
            return 2;
        }
        // Select by explicit root: A15's 2s mods TTL can still serve the
        // pre-import listing (GET /api/state above populated it), so the
        // name-lookup branch of /api/mods/select would spuriously 404.
        // Name comes from the FINAL directory: a zip whose archive-root husk
        // was renamed away during the lift carries the inner dir's name.
        final_spec = mod_select_request(sa_core::paths::basename(dst), dst);
    } else if (validate_auto) {
        Executed fetched = exec(plan[0]);
        int ec = bail(fetched);
        if (ec) return ec;
        ec = bail_http(fetched);
        if (ec) return ec;
        std::string cfg = fetched.body.value("cfg", c.cfg);
        sa_cli::json data =
            fetched.body.contains("data") && fetched.body.at("data").is_object()
                ? fetched.body.at("data")
                : sa_cli::json::object();
        final_spec = validate_post(cfg, data);
    }
    Executed last = exec(final_spec);

    // Persist explicit selection choices so the next one-shot run re-selects
    // the same mod. Only when the data root is known (embedded run or an
    // explicit --data-root): never scribble editor_env.json next to the exe.
    bool ok_status_now = last.transport_ok && last.status >= 200 && last.status <= 299;
    if (ok_status_now && is_selecting && last.body.is_object() &&
        last.body.contains("mod") && last.body["mod"].is_object() &&
        (embedded.active || !g.data_root.empty())) {
        const sa_cli::json& m = last.body["mod"];
        std::string mname = m.value("name", "");
        std::string mroot = m.value("root", "");
        if (!mname.empty()) {
            try {
                sa_core::env_store::merge_editor_env(
                    sa::editor_root(),
                    sa_cli::json{{kCliSelectedModKey,
                                  sa_cli::json{{"name", mname}, {"root", mroot}}}});
            } catch (const std::exception&) {
                // persistence is best-effort; the command itself succeeded
            }
        }
    }

    if (!last.transport_ok) {
        print_utf8_err("error: transport: " + last.transport_error + "\n");
        return 3;
    }
    bool ok_status = last.status >= 200 && last.status <= 299;
    if (g.json) {
        print_utf8(last.raw_body);
        if (!last.raw_body.empty() && last.raw_body.back() != '\n') print_utf8("\n");
    } else if (ok_status) {
        // story export --out writes the text to a file instead of stdout.
        if (c.kind == Kind::StoryExport && !c.out.empty() && last.body.contains("text") &&
            last.body.at("text").is_string()) {
            std::string e;
            if (!write_text_file(c.out, last.body.at("text").get<std::string>(), &e)) {
                print_utf8_err("error: " + e + "\n");
                return 2;
            }
            print_utf8("written: " + c.out + "\n");
        } else {
            print_utf8(format_text(c, last.body));
        }
    } else {
        print_utf8_err(error_text(last.body) + "\n");
    }
    return compute_exit(last.status, last.body, c);
}

}  // namespace

int main(int argc, char** argv) { return real_main(argc, argv); }
