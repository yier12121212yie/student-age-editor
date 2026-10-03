// zip_store_writer.h — 最小 STORE(不压缩) zip 打包器，只为「导出模组」用。
//
// 为什么不用 miniz：vendored miniz 按 reader-only 配置编译
// （p3b_miniz_config.h 定义 MINIZ_NO_DEFLATE_APIS + MINIZ_NO_ARCHIVE_WRITING_APIS），
// 后端根本没有可用的 zip 写入符号。这里手写方法 0（store）的 zip：结构简单、
// 无第三方依赖；图片/音频本身已压缩，JSON 体积也在可接受范围内。
//
// 约束：单条目 < 4 GiB、条目名 < 64 KiB、条目数 < 65536（不生成 zip64）。
// 文件名统一 '/' 分隔、UTF-8（general purpose flag bit 11）。
#pragma once

#include <cstdint>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <vector>

#include "sa_core/paths.h"

namespace sa {
namespace zipstore {

struct Entry {
    std::string name;  // 归档内相对路径（'/' 分隔）
    std::string data;
};

inline void put_u16(std::string& out, uint16_t v) {
    out.push_back(static_cast<char>(v & 0xff));
    out.push_back(static_cast<char>((v >> 8) & 0xff));
}

inline void put_u32(std::string& out, uint32_t v) {
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
}

// CRC-32 (IEEE 802.3, zip 用多项式 0xEDB88320)，惰性建表（C++11 起函数内
// static 初始化线程安全）。
inline uint32_t* crc32_table() {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        init = true;
    }
    return table;
}

// 增量 CRC-32：分块读大文件（贴图/配乐/视频）时逐块喂入，避免整包进内存。
inline uint32_t crc32_update(uint32_t c, const void* data, size_t len) {
    const uint32_t* table = crc32_table();
    const unsigned char* p = static_cast<const unsigned char*>(data);
    for (size_t i = 0; i < len; ++i) c = table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c;
}

inline uint32_t crc32(const void* data, size_t len) {
    return crc32_update(0xFFFFFFFFu, data, len) ^ 0xFFFFFFFFu;
}

inline void dos_datetime(uint16_t& out_time, uint16_t& out_date) {
    std::time_t now = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &now);
#else
    localtime_r(&now, &tm);
#endif
    out_time = static_cast<uint16_t>(((tm.tm_hour & 0x1f) << 11) | ((tm.tm_min & 0x3f) << 5) |
                                     ((tm.tm_sec / 2) & 0x1f));
    out_date = static_cast<uint16_t>(((tm.tm_year + 1900 - 1980) << 9) |
                                     (((tm.tm_mon + 1) & 0xf) << 5) | (tm.tm_mday & 0x1f));
}

// 生成 store-only zip；任何条目超限返回 false（调用方据此回 413）。
inline bool build(const std::vector<Entry>& entries, std::string& out) {    out.clear();
    if (entries.size() > 0xFFFF) return false;
    std::string central;
    uint16_t dtime = 0, ddate = 0;
    dos_datetime(dtime, ddate);
    for (const auto& e : entries) {
        if (e.name.empty() || e.name.size() > 0xFFFF) return false;
        if (e.data.size() > 0xFFFFFFFFull) return false;
        const uint32_t crc = crc32(e.data.data(), e.data.size());
        const uint32_t size = static_cast<uint32_t>(e.data.size());
        const uint32_t offset = static_cast<uint32_t>(out.size());
        const uint16_t nlen = static_cast<uint16_t>(e.name.size());

        // local file header
        put_u32(out, 0x04034b50);
        put_u16(out, 20);      // version needed to extract
        put_u16(out, 0x0800);  // general purpose flag: UTF-8 文件名
        put_u16(out, 0);       // compression method = store
        put_u16(out, dtime);
        put_u16(out, ddate);
        put_u32(out, crc);
        put_u32(out, size);    // compressed size
        put_u32(out, size);    // uncompressed size
        put_u16(out, nlen);
        put_u16(out, 0);       // extra field length
        out.append(e.name);
        out.append(e.data);

        // central directory record
        put_u32(central, 0x02014b50);
        put_u16(central, 20);  // version made by
        put_u16(central, 20);  // version needed
        put_u16(central, 0x0800);
        put_u16(central, 0);
        put_u16(central, dtime);
        put_u16(central, ddate);
        put_u32(central, crc);
        put_u32(central, size);
        put_u32(central, size);
        put_u16(central, nlen);
        put_u16(central, 0);   // extra field length
        put_u16(central, 0);   // file comment length
        put_u16(central, 0);   // disk number start
        put_u16(central, 0);   // internal file attributes
        put_u32(central, 0);   // external file attributes
        put_u32(central, offset);
        central.append(e.name);
    }

    const uint32_t cd_offset = static_cast<uint32_t>(out.size());
    const uint32_t cd_size = static_cast<uint32_t>(central.size());
    out.append(central);

    // end of central directory
    put_u32(out, 0x06054b50);
    put_u16(out, 0);  // number of this disk
    put_u16(out, 0);  // disk where central directory starts
    put_u16(out, static_cast<uint16_t>(entries.size()));  // entries on this disk
    put_u16(out, static_cast<uint16_t>(entries.size()));  // total entries
    put_u32(out, cd_size);
    put_u32(out, cd_offset);
    put_u16(out, 0);  // comment length
    return true;
}

// ---------------------------------------------------------------------------
// 流式落盘打包（自托管大模组导出用）：条目可以是内存字节，也可以是本地文件
// ——贴图/配乐/视频整包可达数百 MB，绝不能再走「全量读进 string 再 base64」。
// ---------------------------------------------------------------------------

struct FileSource {
    std::string name;   // 归档内相对路径（'/' 分隔，UTF-8）
    std::string data;   // 非空即以此字节为内容
    std::string path;   // data 为空时：从本地文件流式读取（UTF-8 路径）
};

// 流式组装 store-only zip 写入 out_path。约束同 build()：单条目与总文件均
// < 4 GiB（不产 zip64）、条目数 < 65536、条目名 < 64 KiB。本地条目单趟流读，
// local header 先占位、payload 写完再回填 CRC/大小。成功时 total_bytes 为产物
// 大小；失败返回 false 并给出 err，残损输出文件被删除。
inline bool build_to_file(const std::vector<FileSource>& entries, const std::string& out_path,
                          long long& total_bytes, std::string& err) {
    namespace fsx = std::filesystem;
    err.clear();
    total_bytes = 0;
    if (entries.size() > 0xFFFF) {
        err = "too many entries";
        return false;
    }
    uint16_t dtime = 0, ddate = 0;
    dos_datetime(dtime, ddate);

    std::ofstream out(sa_core::paths::to_path(out_path),
                      std::ios::binary | std::ios::trunc);
    if (!out) {
        err = "cannot open output: " + out_path;
        return false;
    }
    const auto cleanup_fail = [&](const std::string& msg) -> bool {
        out.close();
        std::error_code ec;
        fsx::remove(sa_core::paths::to_path(out_path), ec);
        err = msg;
        return false;
    };

    std::string central;
    std::vector<char> buf(1 << 20);
    for (const auto& e : entries) {
        if (e.name.empty() || e.name.size() > 0xFFFF)
            return cleanup_fail("bad entry name: " + e.name);
        const uint16_t nlen = static_cast<uint16_t>(e.name.size());
        const long long stream_pos = static_cast<long long>(out.tellp());
        if (stream_pos > 0xFFFFFFFFll - 30 - nlen)
            return cleanup_fail("zip exceeds 4 GiB (no zip64)");

        uint32_t crc = 0;
        uint32_t size = 0;
        bool is_file = e.data.empty() && !e.path.empty();
        std::error_code fec;
        long long fsize = is_file ? static_cast<long long>(fsx::file_size(sa_core::paths::to_path(e.path), fec)) : 0;
        if (is_file && (fec || fsize < 0 || fsize > 0xFFFFFFFFll))
            return cleanup_fail("bad entry size: " + e.name);
        size = static_cast<uint32_t>(is_file ? fsize : static_cast<long long>(e.data.size()));

        // local header（crc/size 先占位，流式条目 payload 写完后回填）。
        std::string hdr;
        put_u32(hdr, 0x04034b50);
        put_u16(hdr, 20);
        put_u16(hdr, 0x0800);  // UTF-8 文件名
        put_u16(hdr, 0);       // store
        put_u16(hdr, dtime);
        put_u16(hdr, ddate);
        put_u32(hdr, is_file ? 0 : crc32(e.data.data(), e.data.size()));
        put_u32(hdr, size);
        put_u32(hdr, size);
        put_u16(hdr, nlen);
        put_u16(hdr, 0);
        hdr.append(e.name);
        out.write(hdr.data(), static_cast<std::streamsize>(hdr.size()));
        if (!out) return cleanup_fail("write failed: " + e.name);

        if (!is_file) {
            out.write(e.data.data(), static_cast<std::streamsize>(e.data.size()));
            if (!out) return cleanup_fail("write failed: " + e.name);
            crc = crc32(e.data.data(), e.data.size());
        } else {
            const long long crc_patch_pos = stream_pos + 14;  // crc+csize+usize
            std::ifstream in(sa_core::paths::to_path(e.path), std::ios::binary);
            if (!in) return cleanup_fail("cannot read: " + e.name);
            uint32_t running = 0xFFFFFFFFu;
            long long remaining = fsize;
            while (remaining > 0) {
                const size_t want = static_cast<size_t>(
                    remaining < static_cast<long long>(buf.size()) ? remaining : buf.size());
                in.read(buf.data(), static_cast<std::streamsize>(want));
                const long long got = in.gcount();
                if (got <= 0) {
                    in.close();
                    return cleanup_fail("read failed: " + e.name);
                }
                running = crc32_update(running, buf.data(), static_cast<size_t>(got));
                out.write(buf.data(), static_cast<std::streamsize>(got));
                if (!out) {
                    in.close();
                    return cleanup_fail("write failed: " + e.name);
                }
                remaining -= got;
            }
            in.close();
            crc = running ^ 0xFFFFFFFFu;
            std::string patch;
            put_u32(patch, crc);
            put_u32(patch, size);
            put_u32(patch, size);
            const std::ios::pos_type end_pos = out.tellp();
            out.seekp(crc_patch_pos);
            out.write(patch.data(), static_cast<std::streamsize>(patch.size()));
            out.seekp(end_pos);
            if (!out) return cleanup_fail("patch failed: " + e.name);
        }

        // central directory record
        put_u32(central, 0x02014b50);
        put_u16(central, 20);
        put_u16(central, 20);
        put_u16(central, 0x0800);
        put_u16(central, 0);
        put_u16(central, dtime);
        put_u16(central, ddate);
        put_u32(central, crc);
        put_u32(central, size);
        put_u32(central, size);
        put_u16(central, nlen);
        put_u16(central, 0);
        put_u16(central, 0);
        put_u16(central, 0);
        put_u16(central, 0);
        put_u32(central, 0);
        put_u32(central, static_cast<uint32_t>(stream_pos));
        central.append(e.name);
    }

    const uint32_t cd_offset = static_cast<uint32_t>(out.tellp());
    const uint32_t cd_size = static_cast<uint32_t>(central.size());
    out.write(central.data(), static_cast<std::streamsize>(central.size()));
    std::string eocd;
    put_u32(eocd, 0x06054b50);
    put_u16(eocd, 0);
    put_u16(eocd, 0);
    put_u16(eocd, static_cast<uint16_t>(entries.size()));
    put_u16(eocd, static_cast<uint16_t>(entries.size()));
    put_u32(eocd, cd_size);
    put_u32(eocd, cd_offset);
    put_u16(eocd, 0);
    out.write(eocd.data(), static_cast<std::streamsize>(eocd.size()));
    out.flush();
    if (!out) return cleanup_fail("write failed (central directory)");
    out.close();

    std::error_code sec;
    total_bytes = static_cast<long long>(fsx::file_size(sa_core::paths::to_path(out_path), sec));
    if (sec) {
        err = "cannot stat output";
        return false;
    }
    return true;
}

}  // namespace zipstore
}  // namespace sa
