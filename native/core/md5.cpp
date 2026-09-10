#include "sa_core/md5.h"

#include <array>
#include <cstdint>
#include <cstring>

namespace sa_core {
namespace {

// RFC 1321 MD5 in the per-round rotating-variable form. The operand roles
// are easy to get wrong from memory (a first attempt that mirrored the usual
// one-loop snippet produced digests matching nothing); the loop below was
// derived from the RFC's FF/GG/HH/II macro argument rotation and validated
// against CPython 3.12 hashlib.md5 (empty/abc/55/56/64/'message digest'/
// 1e6 bytes) before landing here. Little-endian words — the opposite of
// sha1.cpp above; do not copy that byte order.
const uint32_t kInit[4] = {0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u};

// Target variable per step position within the 4-step cycle (a,d,c,b).
const int kTarget[4] = {0, 3, 2, 1};
// Per-round shift tables, indexed by step%4.
const int kShift[4][4] = {{7, 12, 17, 22}, {5, 9, 14, 20},
                          {4, 11, 16, 23}, {6, 10, 15, 21}};

// Sine-derived K constants (K1..K64, in global step order).
const uint32_t kK[64] = {
    0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu, 0xf57c0fafu,
    0x4787c62au, 0xa8304613u, 0xfd469501u, 0x698098d8u, 0x8b44f7afu,
    0xffff5bb1u, 0x895cd7beu, 0x6b901122u, 0xfd987193u, 0xa679438eu,
    0x49b40821u, 0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
    0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u, 0x21e1cde6u,
    0xc33707d6u, 0xf4d50d87u, 0x455a14edu, 0xa9e3e905u, 0xfcefa3f8u,
    0x676f02d9u, 0x8d2a4c8au, 0xfffa3942u, 0x8771f681u, 0x6d9d6122u,
    0xfde5380cu, 0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
    0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u, 0xd9d4d039u,
    0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u, 0xf4292244u, 0x432aff97u,
    0xab9423a7u, 0xfc93a039u, 0x655b59c3u, 0x8f0ccc92u, 0xffeff47du,
    0x85845dd1u, 0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
    0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u};

inline uint32_t rot(uint32_t x, int c) { return (x << c) | (x >> (32 - c)); }

uint32_t le32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

inline int word_index(int round, int i) {
    switch (round) {
        case 0: return i;
        case 1: return (5 * i + 1) % 16;
        case 2: return (3 * i + 5) % 16;
        default: return (7 * i) % 16;
    }
}

struct Ctx {
    uint32_t h[4] = {kInit[0], kInit[1], kInit[2], kInit[3]};
    uint64_t length_bits = 0;
    std::array<uint8_t, 64> buf{};
    size_t buf_len = 0;

    void transform(const uint8_t* p) {
        uint32_t m[16];
        for (int i = 0; i < 16; ++i) m[i] = le32(p + i * 4);
        uint32_t w[4] = {h[0], h[1], h[2], h[3]};
        for (int i = 0; i < 64; ++i) {
            const int r = i / 16;
            const int t = kTarget[i % 4];
            const int o1 = (t + 1) % 4, o2 = (t + 2) % 4, o3 = (t + 3) % 4;
            const uint32_t x = w[o1], y = w[o2], z = w[o3];
            uint32_t f;
            if (r == 0) {
                f = (x & y) | (~x & z);            // F
            } else if (r == 1) {
                f = (x & z) | (y & ~z);            // G
            } else if (r == 2) {
                f = x ^ y ^ z;                     // H
            } else {
                f = y ^ (x | ~z);                  // I
            }
            const uint32_t tmp = w[t] + f + kK[i] + m[word_index(r, i)];
            w[t] = rot(tmp, kShift[r][i % 4]) + x;
        }
        for (int j = 0; j < 4; ++j) h[j] += w[j];
    }

    void update(const uint8_t* data, size_t len) {
        length_bits += static_cast<uint64_t>(len) * 8;
        while (len) {
            size_t take = 64 - buf_len;
            if (take > len) take = len;
            std::memcpy(buf.data() + buf_len, data, take);
            buf_len += take;
            data += take;
            len -= take;
            if (buf_len == 64) {
                transform(buf.data());
                buf_len = 0;
            }
        }
    }

    void finalize(uint8_t out[16]) {
        uint64_t bits = length_bits;
        uint8_t pad = 0x80;
        update(&pad, 1);
        pad = 0;
        while (buf_len != 56) update(&pad, 1);
        uint8_t lenle[8];
        for (int i = 0; i < 8; ++i)
            lenle[i] = static_cast<uint8_t>(bits >> (i * 8));
        update(lenle, 8);
        for (int i = 0; i < 4; ++i) {
            out[i * 4] = static_cast<uint8_t>(h[i]);
            out[i * 4 + 1] = static_cast<uint8_t>(h[i] >> 8);
            out[i * 4 + 2] = static_cast<uint8_t>(h[i] >> 16);
            out[i * 4 + 3] = static_cast<uint8_t>(h[i] >> 24);
        }
    }
};

}  // namespace

std::string md5_hex(std::string_view data) {
    Ctx ctx;
    ctx.update(reinterpret_cast<const uint8_t*>(data.data()), data.size());
    uint8_t digest[16];
    ctx.finalize(digest);
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.resize(32);
    for (int i = 0; i < 16; ++i) {
        out[i * 2] = hexd[digest[i] >> 4];
        out[i * 2 + 1] = hexd[digest[i] & 0xF];
    }
    return out;
}

}  // namespace sa_core
