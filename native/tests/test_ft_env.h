// test_ft_env.h — 文件流转相关测试的共享脚手架：临时数据根 + COS 环境变量 +
// 内存对象存储 seam（test_file_transfer.cpp 有自己的 CosEnv/CDN 变体，保持独立；
// 模组线（import_staged / add_ref / export_staged）用这一份，避免多 TU 各抄一遍）。
#pragma once

#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "sa_core/paths.h"
#include "server/services/file_transfer.h"
#include "test_support.h"

namespace satft {

// 单个环境变量的 RAII 覆盖（析构还原原值，测试用例间零串扰）。
struct EnvSet {
    std::string key;
    std::string saved;
    bool had = false;
    EnvSet(std::string k, std::string v) : key(std::move(k)) {
        saved = sa_core::paths::getenv_utf8(key.c_str());
        had = !saved.empty();
        sa_core::paths::setenv_utf8(key.c_str(), v, true);
    }
    ~EnvSet() { sa_core::paths::setenv_utf8(key.c_str(), had ? saved : "", true); }
    EnvSet(const EnvSet&) = delete;
    EnvSet& operator=(const EnvSet&) = delete;
};

// 临时 EDITOR_DATA_ROOT（文件流转记录/对象落盘处）+ COS 凭据环境。
struct FtEnv {
    std::filesystem::path data_root = sat::make_temp_dir("ftenv");
    std::unique_ptr<EnvSet> guards[6] = {};
    FtEnv() {
        guards[0] = std::make_unique<EnvSet>("EDITOR_DATA_ROOT",
                                             sa_core::paths::path_to_utf8(data_root));
        guards[1] = std::make_unique<EnvSet>("EDITOR_FILE_COS_SECRET_ID", "AKIDTEST");
        guards[2] = std::make_unique<EnvSet>("EDITOR_FILE_COS_SECRET_KEY", "SECRETKEY");
        guards[3] = std::make_unique<EnvSet>("EDITOR_FILE_COS_BUCKET", "testbucket-1250000000");
        guards[4] = std::make_unique<EnvSet>("EDITOR_FILE_COS_REGION", "ap-guangzhou");
        guards[5] = std::make_unique<EnvSet>(
            "EDITOR_FILE_COS_PUBLIC_ENDPOINT", "https://cos.ap-guangzhou.myqcloud.com");
    }
    std::string root() const { return sa_core::paths::path_to_utf8(data_root); }
};

// 内存 COS：key -> bytes。
struct MemCos {
    std::mutex mu;
    std::map<std::string, std::string> objects;
};

// 把 MemCos 接进 file_transfer 的下载/上传/删除 seam。
inline sa::file_transfer::CosOps mem_ops(const std::shared_ptr<MemCos>& m) {
    using namespace sa::file_transfer;
    CosOps ops;
    ops.download = [m](const CosConfig&, const std::string& key, const std::string& local,
                       std::string* err) -> bool {
        std::lock_guard<std::mutex> lk(m->mu);
        auto it = m->objects.find(key);
        if (it == m->objects.end()) {
            if (err) *err = "404 " + key;
            return false;
        }
        sa_core::paths::create_dirs(sa_core::paths::dirname(local));
        return sa_core::paths::write_bytes_simple(local, it->second);
    };
    ops.upload = [m](const CosConfig&, const std::string& local, const std::string& key,
                     std::string* err) -> bool {
        auto data = sa_core::paths::read_bytes(local);
        if (!data) {
            if (err) *err = "read failed";
            return false;
        }
        std::lock_guard<std::mutex> lk(m->mu);
        m->objects[key] = *data;
        return true;
    };
    ops.remove = [m](const CosConfig&, const std::string& key, std::string*) -> bool {
        std::lock_guard<std::mutex> lk(m->mu);
        m->objects.erase(key);
        return true;
    };
    return ops;
}

// 用例结束时恢复默认（真实 HTTP）ops。
struct OpsReset {
    ~OpsReset() { sa::file_transfer::reset_cos_ops_for_test(); }
};

}  // namespace satft
