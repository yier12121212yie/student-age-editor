// tests/bench_gen.h — C++ port of backend/editor/server/benchdata.py.
//
// Synthetic ~40MB TalkCfg: 98,963 rows, ~405B/row, LF-joined with ",\n",
// built by string concatenation (NOT serialization) exactly like the Python
// generator, so both backends face byte-identical fixtures (still-stone S1:
// json.dumps on the fixture would cost 2.3s and pollute the measurement).
#pragma once

#include <string>

namespace sat {

inline constexpr int kNumRows = 98963;        // benchdata.py:31
inline constexpr long long kTargetSize = 40258490LL;  // benchdata.py:32
inline constexpr int kRowTargetBytes = 405;   // benchdata.py:35

// Full table text, module-cached (benchdata._TEXT_CACHE).
const std::string& synthetic_talk_cfg();

}  // namespace sat
