#include "bench_gen.h"

#include <cstdio>
#include <string>

namespace sat {
namespace {

// benchdata.py:38-60 _generate_row — the format strings and the Chinese base
// content are embedded verbatim (benchdata.py:45-46).
std::string generate_row(long long row_id) {
    std::string key = std::to_string(row_id);
    std::string label = "\"" + key + "\": ";
    std::string prefix = "{\"id\": \"" + key + "\", \"content\": \"";
    char suffix_buf[128];
    std::snprintf(suffix_buf, sizeof(suffix_buf),
                  "\", \"person\": \"P%03lld\", \"bg\": \"BG%02lld\","
                  " \"audio\": \"SE_%03lld\", \"evt_type\": 1}",
                  row_id % 1000, row_id % 100, row_id % 500);
    std::string suffix = suffix_buf;
    char base_buf[256];
    std::snprintf(base_buf, sizeof(base_buf),
                  "这是一个测试对白第%lld行的内容，用于模拟真实的"
                  "TalkCfg 数据结构。每一行都应该有足够的长度来模拟实际使用场景中的文本长度。",
                  row_id);
    std::string content = base_buf;
    long long budget = kRowTargetBytes - static_cast<long long>(label.size()) -
                       static_cast<long long>(prefix.size()) -
                       static_cast<long long>(suffix.size());
    long long deficit = budget - static_cast<long long>(content.size());
    if (deficit > 0) {
        content.append(static_cast<size_t>(deficit), 'x');
    } else if (deficit < 0) {
        // Shrink by CODEPOINTS (bytes would split a UTF-8 char), then pad.
        // utf8 string: drop trailing complete chars until within budget.
        while (static_cast<long long>(content.size()) > budget) {
            size_t cut = content.size();
            // step back over continuation bytes to the char boundary
            while (cut > 0 && (static_cast<unsigned char>(content[cut - 1]) & 0xC0) == 0x80) {
                --cut;
            }
            content.resize(cut - 1);
        }
        content.append(static_cast<size_t>(budget - static_cast<long long>(content.size())), 'x');
    }
    return label + prefix + content + suffix;
}

std::string build() {
    std::string joined = "{\n";
    for (long long i = 0; i < kNumRows; ++i) {
        if (i) joined += ",\n";  // LF separator (benchdata.py:68)
        joined += generate_row(i);
    }
    joined += "\n}";
    long long actual = static_cast<long long>(joined.size());
    double tolerance = kTargetSize * 0.05;
    double delta = static_cast<double>(actual > kTargetSize ? actual - kTargetSize
                                                            : kTargetSize - actual);
    if (delta > tolerance) {
        std::fprintf(stderr, "Generated %lld bytes, expected ~%lld\n", actual, kTargetSize);
        std::abort();
    }
    return joined;
}

}  // namespace

const std::string& synthetic_talk_cfg() {
    static const std::string cache = build();
    return cache;
}

}  // namespace sat
