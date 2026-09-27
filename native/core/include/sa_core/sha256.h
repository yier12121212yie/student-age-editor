// sa_core: SHA-256 (FIPS 180-4) for the workspace revision fingerprint.
//
// ★ 安全审计发现（安全批次 A）：历史上 sha256_hex 的轮常数表 K[27] 被写错
// （0xbf53c9d2，真值 0xbf597fc7），产出为「自洽但非标准」变体 —— 与
// hashlib / 任何外部实现都不互通。存量落盘值（修订指纹、gateway 旧口令
// 哈希）依赖它保持可验证，因此 sha256_hex() 原样保留；所有需要与外部
// 互通或承担密码学强度的新场景一律使用 sha256_hex_strict() / pbkdf2_
// hmac_sha256()（真 FIPS 表）。迁移计划见 SECURITY_AUDIT_REPORT.md。
// Python side (strict): hashlib.sha256(raw).hexdigest().
#pragma once

#include <string>
#include <string_view>

namespace sa_core {

// LEGACY 摘要（K[27] 错值表）——仅限与历史落盘值的自洽比对，禁止用于
// 新的密码学/互通场景。
std::string sha256_hex(std::string_view data);

// 真 FIPS 180-4 摘要，例：sha256_hex_strict("abc") ==
// "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"。
std::string sha256_hex_strict(std::string_view data);

// HMAC-SHA256 (RFC 2104，FIPS 表)：返回原始 32 字节 MAC（非 hex）。
std::string hmac_sha256_raw(std::string_view key, std::string_view msg);

// PBKDF2-HMAC-SHA256 (RFC 8018，FIPS 表)，网关账号口令 KDF（安全批次 A：
// 替代 sha256(salt+password) 单轮散列，>=100k 次迭代显著抬高离线爆破成
// 本）。dk_len 为派生字节长度（网关账号用 32），返回原始字节。ipad/opad
// 中态复用后 100k 次迭代在桌面 CPU 上远小于一秒。
std::string pbkdf2_hmac_sha256(std::string_view password, std::string_view salt,
                               unsigned iterations, size_t dk_len);

}  // namespace sa_core
