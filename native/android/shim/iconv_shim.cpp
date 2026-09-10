// W4-4 Android build shim implementation: iconv is NOT part of bionic.
// iconv_open always fails so p3b_fs_tools.cpp's existing degrade branch
// (decode_utf8_sig_replace) answers every GBK-decode request — no
// don't-touch file edited, no runtime crash. See shim/iconv.h for the why.
#include "iconv.h"

extern "C" iconv_t iconv_open(const char* /*tocode*/, const char* /*fromcode*/) {
    return reinterpret_cast<iconv_t>(-1);  // the file's `== -1` test
}

extern "C" size_t iconv(iconv_t /*cd*/, char** /*inbuf*/, size_t* /*inbytesleft*/,
                        char** /*outbuf*/, size_t* /*outbytesleft*/) {
    return static_cast<size_t>(-1);
}

extern "C" int iconv_close(iconv_t /*cd*/) { return 0; }
