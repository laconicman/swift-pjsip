/* Umbrella for the PJSUA2 C++ API. The consuming Swift target must enable C++
 * interop (.interoperabilityMode(.Cxx)). pjsua2 headers include <pjsua-lib/pjsua.h>,
 * so the full C API is reachable from C++ contexts as well. */
#define PJ_AUTOCONF 1
#include <pjsua2.hpp>
