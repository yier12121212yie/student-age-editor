// [core][sha256][kdf] — sha256_hex_strict / pbkdf2_hmac_sha256 vectors.
//
// 背景（安全批次 A，见 sha256.cpp 头注释与 SECURITY_AUDIT_REPORT.md）：
// 历史 sha256_hex 的轮常数 K[27] 写错（0xbf53c9d2，真值 0xbf597fc7），
// 产出是自洽但非标准的变体。本文件钉死两件事：
//   1. sha256_hex_strict 与 hashlib 完全互通（FIPS 180-4 向量）；
//   2. pbkdf2_hmac_sha256 与 RFC 8018 公开向量逐位一致（由 Python
//      hashlib.pbkdf2_hmac 生成后再人工核对公开文献值）。
// 并反向断言 legacy sha256_hex ≠ strict——防止有人「顺手统一」两张表
// 而悄悄炸掉全部存量指纹。
#include <string>

#include <catch_amalgamated.hpp>

#include "sa_core/http_client.h"
#include "sa_core/sha256.h"

TEST_CASE("sha256_hex_strict matches FIPS 180-4 vectors", "[core][sha256]") {
    CHECK(sa_core::sha256_hex_strict("abc") ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    CHECK(sa_core::sha256_hex_strict("") ==
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    // 448-bit message：跨块 + 单填充场景（FIPS 180-4 示例）。
    CHECK(sa_core::sha256_hex_strict("abcdbcdecdefdefgefghfghighijhi"
                                     "jkijkljklmklmnlmnomnopnopq") ==
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    // 100 万个 'a' 的 FIPS 向量太慢，用 64 字节（恰好一个块）+ 65 字节
    // （跨块边界）的一对哨兵：hashlib.sha256(b'a'*64) / (b'a'*65)。
    CHECK(sa_core::sha256_hex_strict(std::string(64, 'a')) ==
          "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
    CHECK(sa_core::sha256_hex_strict(std::string(65, 'a')) ==
          "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0");
}

TEST_CASE("legacy sha256_hex stays byte-compatible and non-standard",
          "[core][sha256]") {
    // legacy 表必须继续与历史落盘指纹一致（K[27] 错值），且绝不等于
    // strict —— 两个断言分别防「误改表」和「误统一表」。
    CHECK(sa_core::sha256_hex("abc") !=
          sa_core::sha256_hex_strict("abc"));
    // 与迁移前实现逐位一致的锚点（用 legacy 表独立复算验证过；
    // strict/hashlib 给出的是 ba7816bf…）。
    CHECK(sa_core::sha256_hex("abc") ==
          "c1069d1b5825de2353f9bf91a1dd9d3550a675075016ec0a8ea019b06fb0ddd0");
    CHECK(sa_core::sha256_hex("") ==
          "d7dc52670f09d18433b7f9e448c7a3185bae6e4bd277f5d1cab6ba870dd2b999");
}

TEST_CASE("pbkdf2_hmac_sha256 matches RFC 8018 style vectors", "[core][kdf]") {
    // 公开 PBKDF2-HMAC-SHA256 向量（RFC 7914 §11 / 社区测试集同源），
    // 生成后再用 Python hashlib.pbkdf2_hmac 复核。
    CHECK(sa_core::http::bytes_to_hex(
              sa_core::pbkdf2_hmac_sha256("password", "salt", 1, 32)) ==
          "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    CHECK(sa_core::http::bytes_to_hex(
              sa_core::pbkdf2_hmac_sha256("password", "salt", 2, 32)) ==
          "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43");
    CHECK(sa_core::http::bytes_to_hex(
              sa_core::pbkdf2_hmac_sha256("password", "salt", 4096, 32)) ==
          "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
    // 多块派生（dkLen=40 > 32，触发第二个 PBKDF2 块）+ 长盐。
    CHECK(sa_core::http::bytes_to_hex(
              sa_core::pbkdf2_hmac_sha256("passwordPASSWORDpassword",
                                          "saltSALTsaltSALTsaltSALTsaltSALTsalt",
                                          4096, 40)) ==
          "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c"
          "635518c7dac47e9");
}
