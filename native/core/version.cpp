#include "sa_core/version.h"

namespace sa_core {

const char* version() noexcept { return "0.1.0"; }

// Configure-time release version (see version.h). The #ifndef keeps a bare
// compiler invocation (no CMake definition) working.
#ifndef SA_APP_VERSION
#define SA_APP_VERSION "dev"
#endif
const char* app_version() noexcept { return SA_APP_VERSION; }

const char* app_name() noexcept { return "student-age-editor"; }

}  // namespace sa_core
