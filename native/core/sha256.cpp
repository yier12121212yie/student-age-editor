// sa_core/sha256.cpp: FIPS 180-4 SHA-256.
//
// ★ 安全审计发现（安全批次 A，详见 SECURITY_AUDIT_REPORT.md）：本文件历史
// 版本的轮常数表 K[27] 被写错（0xbf53c9d2，真值 0xbf597fc7），产出的摘要
// 是「自洽但非标准」的变体 —— 与 Python hashlib / 任何外部实现都不互通，
// 连本头文件注释里的 sha256("abc") 示例值都对不上。该变体的全部产出早已
// 落盘（workspace 修订指纹、cfg 冲突指纹、gateway.json 旧版口令哈希），
// 直接换表会让所有指纹一夜失效、旧账号无法登录。
//
// 因此这里并存两张表：
//   * sha256_hex()          —— 继续用 legacy 表（与历史落盘值逐位一致），
//                              仅限「仓库内部自洽比对」的场景。
//   * sha256_hex_strict()   —— 真 FIPS 表，供任何需要与外部世界互通或
//                              承担密码学强度的场景使用。
//   * pbkdf2_hmac_sha256()  —— 网关口令 KDF（安全批次 A），构建在 FIPS
//                              表之上；legacy 表绝不允许参与口令哈希。
// 指纹整体迁移到 strict 表列入 SECURITY_AUDIT_REPORT 批次 C 待办。

#include "sa_core/sha256.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace sa_core {

namespace {

// 历史表的忠实拷贝（含 K[27] 的已知错误值）。任何「新」用途都不得引用它。
constexpr uint32_t kLegacyK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf53c9d2, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

// FIPS 180-4 真值（由 floor(frac(cbrt(p)) * 2^32) 对前 64 个素数生成，
// 与 Python hashlib 全量核对）。
constexpr uint32_t kFipsK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

inline uint32_t rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

void compress(const uint32_t K[64], uint32_t h[8], const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = (static_cast<uint32_t>(block[4 * i]) << 24) |
               (static_cast<uint32_t>(block[4 * i + 1]) << 16) |
               (static_cast<uint32_t>(block[4 * i + 2]) << 8) |
               static_cast<uint32_t>(block[4 * i + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
    uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; ++i) {
        const uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const uint32_t ch = (e & f) ^ (~e & g);
        const uint32_t t1 = hh + S1 + ch + K[i] + w[i];
        const uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t t2 = S0 + maj;
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

// Streaming SHA-256 state. sha256_hex/sha256_hex_strict are single-shot
// init/update/final over the whole buffer; PBKDF2 snapshots the midstate
// after absorbing the ipad/opad key block so each iteration costs 4
// compressions instead of 8 plus fresh contexts.
struct Sha256Ctx {
    const uint32_t* k = kFipsK;  // table selected by the digest flavor
    uint32_t h[8];
    uint64_t total_len = 0;  // bytes fed so far
    uint8_t buf[64];
    size_t buf_len = 0;

    void init(const uint32_t* table) {
        k = table;
        h[0] = 0x6a09e667; h[1] = 0xbb67ae85; h[2] = 0x3c6ef372; h[3] = 0xa54ff53a;
        h[4] = 0x510e527f; h[5] = 0x9b05688c; h[6] = 0x1f83d9ab; h[7] = 0x5be0cd19;
        total_len = 0;
        buf_len = 0;
    }

    void update(const uint8_t* d, size_t n) {
        total_len += n;
        if (buf_len > 0) {
            const size_t take = std::min(n, size_t{64} - buf_len);
            std::memcpy(buf + buf_len, d, take);
            buf_len += take;
            d += take;
            n -= take;
            if (buf_len == 64) {
                compress(k, h, buf);
                buf_len = 0;
            }
        }
        while (n >= 64) {
            compress(k, h, d);
            d += 64;
            n -= 64;
        }
        if (n > 0) {
            std::memcpy(buf, d, n);
            buf_len = n;
        }
    }

    void final(uint8_t out[32]) {
        // FIPS 180-4 padding: 0x80, zeros to 56 mod 64, big-endian bit length.
        const uint64_t bitlen = total_len * 8;
        const uint8_t pad80 = 0x80;
        const uint8_t zero = 0x00;
        update(&pad80, 1);
        while (buf_len != 56) update(&zero, 1);
        uint8_t lenb[8];
        for (int i = 0; i < 8; ++i)
            lenb[i] = static_cast<uint8_t>((bitlen >> (56 - 8 * i)) & 0xff);
        update(lenb, 8);
        for (int i = 0; i < 8; ++i) {
            out[i * 4] = static_cast<uint8_t>((h[i] >> 24) & 0xff);
            out[i * 4 + 1] = static_cast<uint8_t>((h[i] >> 16) & 0xff);
            out[i * 4 + 2] = static_cast<uint8_t>((h[i] >> 8) & 0xff);
            out[i * 4 + 3] = static_cast<uint8_t>(h[i] & 0xff);
        }
    }
};

std::string hex_digest(const uint8_t raw[32]) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (int i = 0; i < 32; ++i) {
        out.push_back(kHex[raw[i] >> 4]);
        out.push_back(kHex[raw[i] & 0xf]);
    }
    return out;
}

std::string sha256_hex_with(const uint32_t* table, std::string_view data) {
    Sha256Ctx ctx;
    ctx.init(table);
    ctx.update(reinterpret_cast<const uint8_t*>(data.data()), data.size());
    uint8_t raw[32];
    ctx.final(raw);
    return hex_digest(raw);
}

}  // namespace

std::string sha256_hex(std::string_view data) {
    // LEGACY（K[27] 错值）——仅限与历史落盘指纹/旧口令哈希的自洽比对。
    return sha256_hex_with(kLegacyK, data);
}

std::string sha256_hex_strict(std::string_view data) {
    // 真 FIPS 180-4：sha256_hex_strict("abc") ==
    // ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad。
    return sha256_hex_with(kFipsK, data);
}

std::string hmac_sha256_raw(std::string_view key, std::string_view msg) {
    // RFC 2104（FIPS 表）。Key > block size 先散列；短 key 零填充到 64 字节。
    uint8_t k[64] = {0};
    if (key.size() > 64) {
        Sha256Ctx kh;
        kh.init(kFipsK);
        kh.update(reinterpret_cast<const uint8_t*>(key.data()), key.size());
        uint8_t kraw[32];
        kh.final(kraw);
        std::memcpy(k, kraw, 32);
    } else if (!key.empty()) {
        std::memcpy(k, key.data(), key.size());
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; ++i) {
        ipad[i] = static_cast<uint8_t>(k[i] ^ 0x36);
        opad[i] = static_cast<uint8_t>(k[i] ^ 0x5c);
    }
    uint8_t inner[32];
    {
        Sha256Ctx c;
        c.init(kFipsK);
        c.update(ipad, 64);
        c.update(reinterpret_cast<const uint8_t*>(msg.data()), msg.size());
        c.final(inner);
    }
    Sha256Ctx c;
    c.init(kFipsK);
    c.update(opad, 64);
    c.update(inner, 32);
    uint8_t raw[32];
    c.final(raw);
    return std::string(reinterpret_cast<const char*>(raw), 32);
}

std::string pbkdf2_hmac_sha256(std::string_view password, std::string_view salt,
                               unsigned iterations, size_t dk_len) {
    // RFC 8018（FIPS 表）。ipad/opad 中态只吸收一次，每轮迭代 4 次压缩，
    // 100k 次迭代默认参数在桌面 CPU 上远小于一秒。
    uint8_t k[64] = {0};
    if (password.size() > 64) {
        Sha256Ctx kh;
        kh.init(kFipsK);
        kh.update(reinterpret_cast<const uint8_t*>(password.data()),
                  password.size());
        uint8_t kraw[32];
        kh.final(kraw);
        std::memcpy(k, kraw, 32);
    } else if (!password.empty()) {
        std::memcpy(k, password.data(), password.size());
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; ++i) {
        ipad[i] = static_cast<uint8_t>(k[i] ^ 0x36);
        opad[i] = static_cast<uint8_t>(k[i] ^ 0x5c);
    }
    Sha256Ctx inner_base, outer_base;
    inner_base.init(kFipsK);
    inner_base.update(ipad, 64);
    outer_base.init(kFipsK);
    outer_base.update(opad, 64);

    std::string out;
    out.reserve(dk_len);
    uint32_t block_index = 1;
    while (out.size() < dk_len) {
        // U1 = HMAC(P, S || INT_32_BE(i))。
        uint8_t u[32];
        {
            Sha256Ctx c = inner_base;
            c.update(reinterpret_cast<const uint8_t*>(salt.data()), salt.size());
            const uint8_t idx[4] = {
                static_cast<uint8_t>(block_index >> 24),
                static_cast<uint8_t>(block_index >> 16),
                static_cast<uint8_t>(block_index >> 8),
                static_cast<uint8_t>(block_index)};
            c.update(idx, 4);
            uint8_t inner[32];
            c.final(inner);
            Sha256Ctx o = outer_base;
            o.update(inner, 32);
            o.final(u);
        }
        uint8_t t[32];
        std::memcpy(t, u, 32);
        for (unsigned it = 1; it < iterations; ++it) {
            Sha256Ctx c = inner_base;
            c.update(u, 32);
            uint8_t inner[32];
            c.final(inner);
            Sha256Ctx o = outer_base;
            o.update(inner, 32);
            o.final(u);
            for (int j = 0; j < 32; ++j) t[j] ^= u[j];
        }
        const size_t take = std::min(dk_len - out.size(), size_t{32});
        out.append(reinterpret_cast<const char*>(t), take);
        ++block_index;
    }
    return out;
}

}  // namespace sa_core
