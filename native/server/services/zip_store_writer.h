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
#include <string>
#include <vector>

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
inline uint32_t crc32(const void* data, size_t len) {
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
    const unsigned char* p = static_cast<const unsigned char*>(data);
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) c = table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
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
inline bool build(const std::vector<Entry>& entries, std::string& out) {
    out.clear();
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

}  // namespace zipstore
}  // namespace sa
