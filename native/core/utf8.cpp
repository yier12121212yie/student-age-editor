#include "sa_core/utf8.h"

#include <cstdint>

namespace sa_core {
namespace {

using byte = unsigned char;

bool cont(byte b) { return b >= 0x80 && b <= 0xBF; }

// Length of the maximal subpart starting at s[i]: how many bytes form a valid
// *prefix* of a UTF-8 sequence (including the first byte) before the first
// violation.  Returns 1 for a standalone-invalid lead byte.  A truncated
// sequence (prefix valid but runs off the end) counts the whole remainder.
size_t maximal_subpart(const std::string& s, size_t i, bool* complete,
                       uint32_t* cp) {
    byte b0 = static_cast<byte>(s[i]);
    size_t n = s.size() - i;  // bytes remaining
    *complete = false;
    *cp = 0xFFFFFFFFu;

    auto need = [&](size_t len, byte lo, byte hi) -> size_t {
        // validate continuations beyond b0 (first range = [lo,hi])
        for (size_t k = 1; k < len; ++k) {
            if (k >= n) return n;  // truncated: whole remainder is the subpart
            byte b = static_cast<byte>(s[i + k]);
            bool ok = (k == 1) ? (b >= lo && b <= hi) : cont(b);
            if (!ok) return k;
        }
        // full sequence present: final acceptance check of decoded cp ranges
        // is folded into the per-position ranges above.
        *complete = true;
        return len;
    };

    if (b0 < 0x80) {
        *complete = true;
        *cp = b0;
        return 1;
    }
    if (b0 >= 0xC2 && b0 <= 0xDF) {
        size_t k = need(2, 0x80, 0xBF);
        if (*complete) *cp = ((b0 & 0x1Fu) << 6) | (static_cast<byte>(s[i + 1]) & 0x3Fu);
        return k;
    }
    if (b0 == 0xE0) {
        size_t k = need(3, 0xA0, 0xBF);
        if (*complete) {
            *cp = ((b0 & 0x0Fu) << 12) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 2]) & 0x3Fu);
        }
        return k;
    }
    if (b0 >= 0xE1 && b0 <= 0xEC) {
        size_t k = need(3, 0x80, 0xBF);
        if (*complete) {
            *cp = ((b0 & 0x0Fu) << 12) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 2]) & 0x3Fu);
        }
        return k;
    }
    if (b0 == 0xED) {  // surrogates D800-DFFF excluded: second byte 80..9F
        size_t k = need(3, 0x80, 0x9F);
        if (*complete) {
            *cp = ((b0 & 0x0Fu) << 12) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 2]) & 0x3Fu);
        }
        return k;
    }
    if (b0 >= 0xEE && b0 <= 0xEF) {
        size_t k = need(3, 0x80, 0xBF);
        if (*complete) {
            *cp = ((b0 & 0x0Fu) << 12) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 2]) & 0x3Fu);
        }
        return k;
    }
    if (b0 == 0xF0) {
        size_t k = need(4, 0x90, 0xBF);
        if (*complete) {
            *cp = ((b0 & 0x07u) << 18) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 12) |
                  ((static_cast<byte>(s[i + 2]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 3]) & 0x3Fu);
        }
        return k;
    }
    if (b0 >= 0xF1 && b0 <= 0xF3) {
        size_t k = need(4, 0x80, 0xBF);
        if (*complete) {
            *cp = ((b0 & 0x07u) << 18) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 12) |
                  ((static_cast<byte>(s[i + 2]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 3]) & 0x3Fu);
        }
        return k;
    }
    if (b0 == 0xF4) {
        size_t k = need(4, 0x80, 0x8F);
        if (*complete) {
            *cp = ((b0 & 0x07u) << 18) | ((static_cast<byte>(s[i + 1]) & 0x3Fu) << 12) |
                  ((static_cast<byte>(s[i + 2]) & 0x3Fu) << 6) |
                  (static_cast<byte>(s[i + 3]) & 0x3Fu);
        }
        return k;
    }
    return 1;  // 0x80-0xBF stray continuation, 0xC0/0xC1 overlong, 0xF5+ invalid
}

}  // namespace

std::string_view lstrip_bom(std::string_view raw) {
    if (starts_with_bom(raw)) return raw.substr(3);
    return raw;
}

bool starts_with_bom(std::string_view raw) {
    return raw.size() >= 3 && static_cast<byte>(raw[0]) == 0xEF &&
           static_cast<byte>(raw[1]) == 0xBB && static_cast<byte>(raw[2]) == 0xBF;
}

bool is_utf8(std::string_view raw) {
    const std::string s(raw);
    size_t i = 0;
    while (i < s.size()) {
        bool complete = false;
        uint32_t cp = 0;
        size_t k = maximal_subpart(s, i, &complete, &cp);
        if (!complete) return false;
        i += k;
    }
    return true;
}

std::optional<std::string> decode_utf8_sig_strict(std::string_view raw) {
    std::string body(lstrip_bom(raw));
    if (!is_utf8(body)) return std::nullopt;
    return body;
}

void append_codepoint(std::string& out, unsigned cp) {
    if (cp <= 0x7F) {
        out.push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FF) {
        out.push_back(static_cast<char>(0xC0u | (cp >> 6)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else if (cp <= 0xFFFF) {
        out.push_back(static_cast<char>(0xE0u | (cp >> 12)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else {
        out.push_back(static_cast<char>(0xF0u | (cp >> 18)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    }
}

std::string decode_utf8_sig_replace(std::string_view raw) {
    const std::string s(lstrip_bom(raw));
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        bool complete = false;
        uint32_t cp = 0;
        size_t k = maximal_subpart(s, i, &complete, &cp);
        if (complete) {
            append_codepoint(out, cp);
        } else {
            append_codepoint(out, 0xFFFDu);
        }
        if (k == 0) k = 1;  // paranoia: never loop forever
        i += k;
    }
    return out;
}

}  // namespace sa_core
