#include <libpq-fe.h>

// Clang does not expose C character macros directly to Swift.
enum { MAKOSH_PG_DIAG_SQLSTATE = PG_DIAG_SQLSTATE };
