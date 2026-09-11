// W4-4 Android build shim — DECLARATIONS ONLY (never active in Windows/POSIX
// builds: this directory only joins the include path via
// native/android/group.cmake, included only when ANDROID is defined).
//
// Why: server/services/p3b_fs_tools.cpp (W4-3 landed, don't-touch surface)
// includes <iconv.h> on any non-Windows platform, and bionic has none. The
// paired iconv_shim.cpp makes iconv_open fail immediately, which the file's
// own documented degradation path handles by falling back to
// sa_core::decode_utf8_sig_replace — exactly the pre-W4-3 POSIX behaviour.
// Android therefore ships a working /api/tools with utf8/ascii files; GBK
// legacy mod files read as replacement chars until a real GBK decoder lands
// (W4-6 note).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* iconv_t;

iconv_t iconv_open(const char* tocode, const char* fromcode);
size_t iconv(iconv_t cd, char** inbuf, size_t* inbytesleft,
             char** outbuf, size_t* outbytesleft);
int iconv_close(iconv_t cd);

#ifdef __cplusplus
}  // extern "C"
#endif
