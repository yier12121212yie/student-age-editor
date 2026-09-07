// Shared test scaffolding: temp workspaces, router dispatch helpers and the
// per-case state isolation mirroring the Python unittest setUp/tearDown
// (test_s1_read_exit.py:54-78).
#pragma once

#include <cstdio>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

#include "sa_core/paths.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/state.h"

namespace sat {

inline std::filesystem::path make_temp_dir(const std::string& tag) {
    static std::map<std::string, int> counters;
    std::string name = "sa_test_" + tag + "_" + std::to_string(++counters[tag]) + "_" +
                       std::to_string(
                           std::chrono::steady_clock::now().time_since_epoch().count());
    auto p = std::filesystem::temp_directory_path() / std::filesystem::u8path(name);
    std::error_code ec;
    std::filesystem::remove_all(p, ec);
    std::filesystem::create_directories(p);
    return p;
}

// A dispatchable in-process stand-in for Python's MockClient(router.dispatch).
inline sa::Resp call_router(sa::Router& r, const std::string& method, const std::string& path,
                            std::map<std::string, std::string> query = {},
                            const sa::json& body = sa::json()) {
    sa::Req req;
    req.method = method;
    // Paths in tests are given verbatim (already decoded), matching how
    // router.dispatch is called in the Python tests.
    req.path = path;
    req.query = std::move(query);
    req.body = body;
    req.host_header = "127.0.0.1:1234";  // origin check passes (loopback host)
    return r.dispatch(req);
}

// The per-case fixture: temp <tmp>/mod/Cfgs/zh-cn workspace wired into STATE,
// counters/stacks/table-cache isolation identical to the Python setUp.
class CfgFixture {
  public:
    explicit CfgFixture(const std::string& tag = "cfg") : root_(make_temp_dir(tag)) {
        mod_root_ = root_ / "mod";
        cfg_dir_ = mod_root_ / "Cfgs" / "zh-cn";
        std::filesystem::create_directories(cfg_dir_);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            saved_ws_ = st.workspace_root;
            saved_mod_root_ = st.mod_root;
            saved_mod_name_ = st.mod_name;
            st.workspace_root = sa_core::paths::path_to_utf8(root_);
            st.mod_root = sa_core::paths::path_to_utf8(mod_root_);
            st.mod_name = "mod";
            st.mods_cache_valid = false;
        }
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        sa::cfg_store::debug_reset_stacks();
        sa::cfg_store::set_parse_provider(nullptr);
        sa::reset();
        router_ = std::make_unique<sa::Router>(sa::build_router());
    }
    ~CfgFixture() {
        auto& st = sa::STATE();
        std::lock_guard<std::mutex> lk(st.mu_);
        st.workspace_root = saved_ws_;
        st.mod_root = saved_mod_root_;
        st.mod_name = saved_mod_name_;
        std::error_code ec;
        std::filesystem::remove_all(root_, ec);
    }
    CfgFixture(const CfgFixture&) = delete;
    CfgFixture& operator=(const CfgFixture&) = delete;

    sa::Router& router() { return *router_; }
    const std::filesystem::path& root() const { return root_; }
    const std::filesystem::path& mod_root() const { return mod_root_; }
    const std::filesystem::path& cfg_dir() const { return cfg_dir_; }
    std::string cfg_path_str(const std::string& name) const {
        return sa_core::paths::path_to_utf8(cfg_dir_ / std::filesystem::u8path(name + ".json"));
    }

    void write_cfg_file(const std::string& name, const std::string& content) {
        std::ofstream f(cfg_dir_ / std::filesystem::u8path(name + ".json"), std::ios::binary);
        f << content;
    }

  private:
    std::filesystem::path root_, mod_root_, cfg_dir_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_;
    std::unique_ptr<sa::Router> router_;
};

// cfg_store.py's big-table fixture generator (test_s1_read_exit.py:26-31):
// ~480KB so it clears the 256KB cache threshold.
inline std::string big_table_text(int n = 1200, char marker = 'x') {
    std::string out = "{";
    for (int i = 0; i < n; ++i) {
        if (i) out += ",";
        std::string pad(190, marker);
        out += "\"" + std::to_string(i) + "\": {\"id\": " + std::to_string(i) +
               ", \"content\": \"" + pad + std::to_string(i) + pad + "\"}";
    }
    out += "}";
    return out;
}

inline std::filesystem::path tmp_path() { return std::filesystem::temp_directory_path(); }

}  // namespace sat
