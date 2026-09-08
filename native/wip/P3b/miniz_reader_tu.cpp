// Compile the vendored miniz amalgamation as a C++ translation unit.
//
// Why this file exists: the top-level project() declares LANGUAGES CXX only, so
// third_party/miniz/miniz.c cannot be listed as a source directly. P3b is the
// only group that needs zip (docx/xlsx attachment parsing, resource-pack
// install, manifest archives), and it only ever *reads* archives — so the
// deflate half is compiled out via MINIZ_NO_DEFLATE_APIS, which also sidesteps
// the one C-ism in the amalgamation that C++ rejects (the `const mz_uint
// s_tdefl_num_probes[11];` tentative definition inside the compressor).
//
// At merge the orchestrator either keeps this file or promotes miniz into a
// proper `add_library` once C is enabled project-wide.
// p3b_miniz_config.h carries the reader-only macro set (MINIZ_NO_DEFLATE_APIS
// + MINIZ_NO_ARCHIVE_WRITING_APIS) so this TU and its consumers agree.
#include "p3b_miniz_config.h"
#include "miniz/miniz.c"
