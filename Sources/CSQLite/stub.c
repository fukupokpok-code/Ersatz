#include <sqlite3.h>

// A header-only target emits no object file. Xcode's libtool step then
// fails looking for CSQLite.o. This anchor keeps the target a real C library
// on both macOS and Linux.
void ersatz_csqlite_anchor(void) {
    (void)sqlite3_libversion();
}
