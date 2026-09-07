#include "sa_core/sha1.h"

#include <array>
#include <cstdint>
#include <cstring>

namespace sa_core {
namespace {

inline uint32_t rol(uint32_t v, int b) { return (v << b) | (v >> (32 - b)); }

struct Ctx {
    uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u,
                     0xC3D2E1F0u};
    uint64_t length_bits = 0;
    std::array<uint8_t, 64> buf{};
    size_t buf_len = 0;

    void transform(const uint8_t* p) {
        uint32_t w[80];
        for (int i = 0; i < 16; ++i) {
            w[i] = (static_cast<uint32_t>(p[i * 4]) << 24) |
                   (static_cast<uint32_t>(p[i * 4 + 1]) << 16) |
                   (static_cast<uint32_t>(p[i * 4 + 2]) << 8) |
                   static_cast<uint32_t>(p[i * 4 + 3]);
        }
        for (int i = 16; i < 80; ++i) {
            w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; ++i) {
            uint32_t f, k;
            if (i < 20) {
                f = (b & c) | ((~b) & d);
                k = 0x5A827999u;
            } else if (i < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1u;
            } else if (i < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDCu;
            } else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6u;
            }
            uint32_t tmp = rol(a, 5) + f + e + k + w[i];
            e = d;
            d = c;
            c = rol(b, 30);
            b = a;
            a = tmp;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
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

    void finalize(uint8_t out[20]) {
        uint64_t bits = length_bits;
        uint8_t pad = 0x80;
        update(&pad, 1);
        pad = 0;
        while (buf_len != 56) update(&pad, 1);
        uint8_t lenbe[8];
        for (int i = 0; i < 8; ++i) lenbe[i] = static_cast<uint8_t>(bits >> (56 - i * 8));
        update(lenbe, 8);
        for (int i = 0; i < 5; ++i) {
            out[i * 4] = static_cast<uint8_t>(h[i] >> 24);
            out[i * 4 + 1] = static_cast<uint8_t>(h[i] >> 16);
            out[i * 4 + 2] = static_cast<uint8_t>(h[i] >> 8);
            out[i * 4 + 3] = static_cast<uint8_t>(h[i]);
        }
    }
};

}  // namespace

std::string sha1_hex(std::string_view data) {
    Ctx ctx;
    ctx.update(reinterpret_cast<const uint8_t*>(data.data()), data.size());
    uint8_t digest[20];
    ctx.finalize(digest);
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.resize(40);
    for (int i = 0; i < 20; ++i) {
        out[i * 2] = hexd[digest[i] >> 4];
        out[i * 2 + 1] = hexd[digest[i] & 0xF];
    }
    return out;
}

}  // namespace sa_core
