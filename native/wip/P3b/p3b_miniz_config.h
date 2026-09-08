// Single place that configures the vendored miniz build (reader-only).
//
// Both miniz_reader_tu.cpp (the implementation TU) and every consumer must
// include THIS header instead of <miniz/miniz.h>, so the two translation units
// cannot disagree about which declarations exist.
#pragma once

#define MINIZ_NO_DEFLATE_APIS
#define MINIZ_NO_ARCHIVE_WRITING_APIS
#include "miniz/miniz.h"
