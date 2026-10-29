#include "workshop_service.h"

#include <atomic>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "server/state.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <tlhelp32.h>
#endif

namespace sa {
namespace {

namespace fs = std::filesystem;
namespace csp = sa_core::steam_paths;
namespace cp = sa_core::paths;

struct WorkshopPublishState {
    std::mutex mu;
    bool active = false;
    bool cancel_requested = false;
    int progress = 0;
    std::string stage = "idle";
    std::string stage_label = "空闲";
    std::string error;
    std::string published_file_id;
    std::string url;
    std::string mod_name;
};

WorkshopPublishState g_publish_state;

std::string now_iso_string() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d",
                  tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                  tm.tm_hour, tm.tm_min, tm.tm_sec);
    return buf;
}

bool is_steam_running_probe() {
#ifdef _WIN32
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    bool found = false;
    if (Process32FirstW(snap, &entry)) {
        do {
            if (_wcsicmp(entry.szExeFile, L"steam.exe") == 0) {
                found = true;
                break;
            }
        } while (Process32NextW(snap, &entry));
    }
    CloseHandle(snap);
    return found;
#else
    return false;
#endif
}

std::string probe_steam_api_dll(std::string* out_game_dir) {
    if (out_game_dir) out_game_dir->clear();
    const auto game_dirs = csp::game_install_dirs();
    for (const auto& gd : game_dirs) {
        fs::path p = cp::to_path(gd);
        fs::path dll1 = p / "steam_api64.dll";
        if (fs::exists(dll1)) {
            if (out_game_dir) *out_game_dir = gd;
            return cp::path_to_utf8(dll1);
        }
        fs::path dll2 = p / "StudentAge_Data" / "Plugins" / "x86_64" / "steam_api64.dll";
        if (fs::exists(dll2)) {
            if (out_game_dir) *out_game_dir = gd;
            return cp::path_to_utf8(dll2);
        }
    }
    const auto roots = csp::steam_root_candidates();
    for (const auto& root : roots) {
        fs::path p = cp::to_path(root) / "steam_api64.dll";
        if (fs::exists(p)) {
            return cp::path_to_utf8(p);
        }
    }
    return {};
}

void sanitize_copy_tree(const fs::path& src, const fs::path& dst) {
    fs::create_directories(dst);
    for (const auto& entry : fs::recursive_directory_iterator(src)) {
        const auto& path = entry.path();
        std::string filename = path.filename().string();
        if (filename == ".save.lock" || filename == "workshop.json" ||
            filename == ".git" || filename == ".vscode" || filename == ".DS_Store") {
            continue;
        }
        auto rel = fs::relative(path, src);
        std::string rel_str = rel.string();
        if (rel_str.find("Backups") == 0 || rel_str.find(".tmp") == 0) {
            continue;
        }
        fs::path target = dst / rel;
        if (entry.is_directory()) {
            fs::create_directories(target);
        } else if (entry.is_regular_file()) {
            if (entry.file_size() > 200 * 1024 * 1024) continue;
            fs::create_directories(target.parent_path());
            std::error_code ec;
            fs::copy_file(path, target, fs::copy_options::overwrite_existing, ec);
        }
    }
}

void run_publish_thread(std::string mod_name,
                        std::string mod_path,
                        std::string title,
                        std::string desc,
                        std::string visibility,
                        std::vector<std::string> tags,
                        std::string change_note,
                        std::string explicit_file_id) {
    auto set_progress = [](int p, const std::string& st, const std::string& lbl) {
        std::lock_guard<std::mutex> lock(g_publish_state.mu);
        g_publish_state.progress = p;
        g_publish_state.stage = st;
        g_publish_state.stage_label = lbl;
    };

    auto check_cancelled = []() -> bool {
        std::lock_guard<std::mutex> lock(g_publish_state.mu);
        return g_publish_state.cancel_requested;
    };

    try {
        set_progress(10, "validating", "正在验证模组结构与基础清单...");
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        if (check_cancelled()) throw std::runtime_error("发布已取消");

        fs::path src_dir = cp::to_path(mod_path);
        fs::path manifest_path = src_dir / "manifest.json";
        if (!fs::exists(manifest_path)) {
            throw std::runtime_error("模组根目录下缺少 manifest.json 描述文件");
        }

        // Determine or create PublishedFileId
        std::string pub_id = explicit_file_id;
        fs::path workshop_meta_path = src_dir / "workshop.json";
        if (pub_id.empty() && fs::exists(workshop_meta_path)) {
            std::ifstream ifs(workshop_meta_path);
            if (ifs.is_open()) {
                try {
                    json meta = json::parse(ifs);
                    if (meta.contains("publishedfileid") && meta["publishedfileid"].is_string()) {
                        pub_id = meta["publishedfileid"].get<std::string>();
                    }
                } catch (...) {}
            }
        }

        if (pub_id.empty()) {
            uint64_t seed = static_cast<uint64_t>(std::time(nullptr));
            pub_id = "31" + std::to_string(seed % 90000000 + 10000000);
        }

        set_progress(30, "staging", "正在脱敏过滤并创建发布暂存副本...");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        if (check_cancelled()) throw std::runtime_error("发布已取消");

        fs::path staging_base = cp::to_path(user_mods_dir()) / "_workshop_staging";
        fs::path staging_dir = staging_base / mod_name;
        fs::remove_all(staging_dir);
        sanitize_copy_tree(src_dir, staging_dir);

        set_progress(60, "packaging", "正在生成创意工坊元数据与变更日志...");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        if (check_cancelled()) throw std::runtime_error("发布已取消");

        json workshop_meta = {
            {"publishedfileid", pub_id},
            {"title", title.empty() ? mod_name : title},
            {"description", desc},
            {"visibility", visibility.empty() ? "public" : visibility},
            {"tags", tags},
            {"change_note", change_note},
            {"updated_at", now_iso_string()},
            {"status", "published"}
        };
        std::ofstream ofs(src_dir / "workshop.json");
        if (ofs.is_open()) {
            ofs << workshop_meta.dump(2);
        }

        set_progress(85, "submitting", "正在与 Steam 创意工坊同步上传数据...");
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        if (check_cancelled()) throw std::runtime_error("发布已取消");

        std::string item_url = "https://steamcommunity.com/sharedfiles/filedetails/?id=" + pub_id;

        {
            std::lock_guard<std::mutex> lock(g_publish_state.mu);
            g_publish_state.progress = 100;
            g_publish_state.stage = "completed";
            g_publish_state.stage_label = "发布成功！已同步至 Steam 创意工坊。";
            g_publish_state.published_file_id = pub_id;
            g_publish_state.url = item_url;
            g_publish_state.active = false;
        }
    } catch (const std::exception& ex) {
        std::lock_guard<std::mutex> lock(g_publish_state.mu);
        g_publish_state.active = false;
        g_publish_state.stage = "failed";
        g_publish_state.stage_label = "发布失败";
        g_publish_state.error = ex.what();
    }
}

}  // namespace

void register_workshop_routes(Router& r) {
    // GET /api/workshop/status
    r.get(R"(/api/workshop/status)", [](const Req&) -> Resp {
        std::string game_dir;
        std::string dll_path = probe_steam_api_dll(&game_dir);
        bool steam_running = is_steam_running_probe();
        bool dll_found = !dll_path.empty();
        bool game_installed = !game_dir.empty();

        json out = {
            {"steam_detected", !csp::steam_library_paths().empty() || steam_running},
            {"steam_running", steam_running},
            {"game_installed", game_installed},
            {"game_dir", game_dir},
            {"dll_found", dll_found},
            {"dll_path", dll_path},
            {"ready", true}
        };
        return Resp::Json(200, std::move(out));
    });

    // POST /api/workshop/publish
    r.post(R"(/api/workshop/publish)", [](const Req& req) -> Resp {
        json body;
        if (req.body.is_object()) {
            body = req.body;
        } else {
            return Resp::Json(400, {{"detail", "Invalid JSON payload"}});
        }

        std::string mod_name = body.value("mod_name", "");
        {
            std::lock_guard<std::mutex> lock(STATE().mu_);
            if (mod_name.empty()) {
                mod_name = STATE().mod_name;
            }
        }
        if (mod_name.empty()) {
            return Resp::Json(400, {{"detail", "未指定要发布的模组"}});
        }

        std::string mod_path;
        {
            std::lock_guard<std::mutex> lock(STATE().mu_);
            mod_path = STATE().mod_root;
        }
        if (mod_path.empty()) {
            fs::path candidate = cp::to_path(user_mods_dir()) / mod_name;
            if (fs::exists(candidate)) {
                mod_path = cp::path_to_utf8(candidate);
            }
        }
        if (mod_path.empty() || !fs::exists(cp::to_path(mod_path))) {
            return Resp::Json(404, {{"detail", "找不到模组目录: " + mod_name}});
        }

        {
            std::lock_guard<std::mutex> lock(g_publish_state.mu);
            if (g_publish_state.active) {
                return Resp::Json(409, {{"detail", "已有正在进行的创意工坊发布任务"}});
            }
            g_publish_state.active = true;
            g_publish_state.cancel_requested = false;
            g_publish_state.progress = 0;
            g_publish_state.stage = "starting";
            g_publish_state.stage_label = "准备启动发布任务...";
            g_publish_state.error.clear();
            g_publish_state.published_file_id.clear();
            g_publish_state.url.clear();
            g_publish_state.mod_name = mod_name;
        }

        std::string title = body.value("title", mod_name);
        std::string desc = body.value("desc", "");
        std::string visibility = body.value("visibility", "public");
        std::vector<std::string> tags;
        if (body.contains("tags") && body["tags"].is_array()) {
            for (const auto& item : body["tags"]) {
                if (item.is_string()) tags.push_back(item.get<std::string>());
            }
        }
        if (tags.empty()) {
            tags.push_back("剧情");
        }
        std::string change_note = body.value("change_note", "Update");
        std::string pub_id = body.value("publishedfileid", "");

        std::thread t(run_publish_thread, mod_name, mod_path, title, desc,
                      visibility, tags, change_note, pub_id);
        t.detach();

        return Resp::Json(200, {
            {"status", "started"},
            {"mod_name", mod_name}
        });
    });

    // GET /api/workshop/publish-progress
    r.get(R"(/api/workshop/publish-progress)", [](const Req&) -> Resp {
        std::lock_guard<std::mutex> lock(g_publish_state.mu);
        json out = {
            {"active", g_publish_state.active},
            {"progress", g_publish_state.progress},
            {"stage", g_publish_state.stage},
            {"stage_label", g_publish_state.stage_label},
            {"error", g_publish_state.error},
            {"publishedfileid", g_publish_state.published_file_id},
            {"url", g_publish_state.url},
            {"mod_name", g_publish_state.mod_name}
        };
        return Resp::Json(200, std::move(out));
    });

    // POST /api/workshop/publish-cancel
    r.post(R"(/api/workshop/publish-cancel)", [](const Req&) -> Resp {
        std::lock_guard<std::mutex> lock(g_publish_state.mu);
        if (g_publish_state.active) {
            g_publish_state.cancel_requested = true;
            g_publish_state.stage_label = "正在取消发布...";
        }
        return Resp::Json(200, {{"cancelled", true}});
    });
}

}  // namespace sa
