// wip/P5/cloud_sync.h — C++ port of backend/editor/server/cloud_sync.py
// (OpenList-style cloud sync: Driver abstraction + single-file/folder sync
// engine). Wave-3 P5; ownership rules per the brief: everything lives under
// native/wip/P5/ until the orchestrator merges.
//
// Semantic anchors (Python line numbers, cloud_sync.py):
//   * _norm_remote            62-71
//   * Obj / BaseDriver        129-159
//   * LocalDriver             163-233
//   * WebDAVDriver            237-387
//   * OpenListDriver          391-536
//   * BaiduNetdiskDriver      543-741
//   * Pan123Driver            743-1083
//   * GoogleDriveDriver       1085-1511
//   * OneDriveDriver          1513-1703
//   * REMOVED_DRIVERS/DRIVERS 1707-1724, get_driver 1726-1736
//   * provider config CRUD    1740-1832
//   * sync engine             1836-2346
//
// Degradation note (brief-sanctioned): the four net-disk drivers (baidu /
// 123 / google_drive / onedrive) fully support their `root` (LocalDriver
// delegation) and `openlist_url` (OpenListDriver proxy) branches — those are
// the locally/mocably testable paths. Their *direct* OAuth/REST legs target
// fixed third-party hosts and answer a deterministic ValueError envelope
// instead (documented in STATUS.md); routes, fields and error codes stay
// Python-shaped either way.
#pragma once

#include <exception>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace cloud {

using json = nlohmann::ordered_json;

// ---------------------------------------------------------------------------
// Python-flavoured exceptions. `what()` is exactly `"%s: %s" % (type, str(e))`
// so per-file sync result strings ("ValueError: ...") come out byte-identical
// to the Python engine (cloud_sync.py:2226,2337).
// ---------------------------------------------------------------------------
struct PyError : std::runtime_error {
    std::string type_name;  // "ValueError" / "FileNotFoundError" / "URLError" / ...
    std::string str_msg;    // Python str(e) — the message WITHOUT the type prefix

    PyError(std::string type, std::string message)
        : std::runtime_error(type + ": " + message),
          type_name(std::move(type)),
          str_msg(std::move(message)) {}
};

// `raise ValueError(msg)`
[[noreturn]] void raise_value_error(const std::string& msg);
// `raise FileNotFoundError(msg)`
[[noreturn]] void raise_file_not_found(const std::string& msg);
// Generic `type(e).__name__`-carrying failure (NotImplementedError, OSError…).
[[noreturn]] void raise_typed(const std::string& type_name, const std::string& msg);

// ---------------------------------------------------------------------------
// cloud_sync.py:62-71 _norm_remote. Throws PyError("ValueError",
// "invalid remote path: <p>") on '..' segments.
// ---------------------------------------------------------------------------
std::string norm_remote(const std::string& p);

// cloud_sync.py:74-95 _parse_http_date (RFC1123 / RFC3339 'Z' → epoch seconds,
// 0 on failure). Exposed for tests.
long long parse_http_date(const std::string& s);

// datetime.fromisoformat(x.replace("Z","+00:00")).timestamp() (alist / drive
// "modified" fields; naive inputs are interpreted in LOCAL time like Python).
// nullopt on parse failure. Exposed for tests.
std::optional<long long> parse_iso_time(const std::string& s);

// ---------------------------------------------------------------------------
// Obj (cloud_sync.py:129-138)
// ---------------------------------------------------------------------------
struct Obj {
    std::string name;
    std::string path;
    bool is_dir = false;
    long long size = 0;
    long long mtime = 0;
    std::string sha1;

    json to_dict() const;  // {"name","path","is_dir","size","mtime","sha1"}
};

// ---------------------------------------------------------------------------
// Driver abstraction (BaseDriver, cloud_sync.py:140-159)
// ---------------------------------------------------------------------------
class Driver {
  public:
    explicit Driver(json config) : config_(std::move(config)) {}
    virtual ~Driver() = default;

    virtual void test() = 0;
    virtual std::vector<Obj> list(const std::string& remote_path) = 0;
    virtual std::optional<Obj> stat(const std::string& remote_path) = 0;
    virtual void get(const std::string& remote_path, const std::string& local_path) = 0;
    virtual void put(const std::string& local_path, const std::string& remote_path) = 0;
    virtual void remove(const std::string& remote_path) = 0;
    virtual void mkdir(const std::string& remote_path) = 0;
    virtual json config_schema() { return json::object(); }

    json& config() { return config_; }

  protected:
    // self.config — Python drivers mutate it during token refresh; we hand
    // each call-site a fresh instance, so mutation stays request-local.
    json config_;
};

using DriverFactory = std::shared_ptr<Driver> (*)(json config);

// Registry in Python insertion order (DRIVERS, cloud_sync.py:1712-1724):
// local, webdav, openlist, alist, baidu_netdisk, baidu, 123, 123pan,
// google_drive, gdrive, onedrive.
const std::vector<std::pair<std::string, DriverFactory>>& drivers();

// cloud_sync.py:1726-1736 get_driver. type_val is the raw provider/`body` JSON
// value so the `(type or "").lower()` AttributeError shape is preserved.
std::shared_ptr<Driver> get_driver(const json& type_val, const json& config);

// Convenience constructors used by the delegating net-disk drivers.
std::shared_ptr<Driver> make_local(json config);
std::shared_ptr<Driver> make_openlist(json config);

// ---------------------------------------------------------------------------
// Provider config storage (cloud_sync.py:36-45, 1740-1832)
// ---------------------------------------------------------------------------
std::string cloud_config_path();           // _cloud_config_path
json load_config();                        // _load_config -> {"providers":[...]}
void save_config(const json& data);        // _save_config (errors swallowed)
json list_providers();                     // list_providers
json add_provider(const json& info);       // add_provider (ValueError on bad type)
json update_provider(const std::string& pid, const json& patch);
void remove_provider(const std::string& pid);
std::optional<json> get_provider(const std::string& pid);  // None -> nullopt

// ---------------------------------------------------------------------------
// Sync engine (cloud_sync.py:1836-2346)
// ---------------------------------------------------------------------------
std::string local_mods_root();                       // _local_mods_root
std::string get_mod_dir(const std::string& mod_name);  // _get_mod_dir

// _list_local_files: rel -> (size, mtime_int, sha1). std::map ordering
// (codepoint == Python str order) also gives callers `sorted(...)` for free.
using LocalFileMap = std::map<std::string, std::tuple<long long, long long, std::string>>;
LocalFileMap list_local_files(const std::string& mod_name, bool compute_sha);

std::string sha1_file(const std::string& path);   // _sha1_file (errors -> "")
std::string lazy_sha(const std::string& path);    // _lazy_sha (>20MB -> "")

// _need_sync (1942-1969): signature kept identical to the Python positional args.
bool need_sync(long long ls, long long lm, const std::string& lh, long long rs,
               long long rm, const std::string& rsha,
               const std::string& local_path = "");

// _remote_path_for (1864-1874). May throw ValueError on '..' mod/rel.
std::string remote_path_for(const json& provider, const std::string& mod_name,
                            const std::string& rel_path);

std::optional<std::string> safe_rel_join(const std::string& mod_dir,
                                         const std::string& rel);  // 2054-2071

// _list_remote_recursive (1971-2035): rel -> Obj. Throws PyError("ValueError",
// ...) on first-level failure or when every level failed.
std::map<std::string, Obj> list_remote_recursive(Driver* driver,
                                                 const std::string& remote_base);

// _drv_get (2037-2050): driver.get + cfg_store undo-stack forget on Cfgs json.
void drv_get(Driver* driver, const std::string& remote, const std::string& local_path);

// sync_mod_folder / sync_single_file / sync_mod_files (2074-2346).
json sync_mod_folder(const std::string& provider_id, const std::string& direction,
                     const std::string& mod_name, bool dry_run, bool delete_extra);
json sync_single_file(const std::string& provider_id, const std::string& direction,
                      const std::string& mod_name, const std::string& rel_path,
                      bool dry_run);
json sync_mod_files(const std::string& provider_id, const std::string& direction,
                    const std::string& mod_name, const json& rel_paths,
                    bool dry_run);

// _sync_state (1853-1863): copy of the running status dict; set_state merges.
json sync_status();
void set_sync_state(const json& kw);

}  // namespace cloud
}  // namespace sa
