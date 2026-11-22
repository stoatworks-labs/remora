// SQLite for SuperRack's session off macOS: Windows' own winsqlite3 (in the Windows SDK, and in
// System32 since Windows 10), or the system's libsqlite3 on Linux. macOS uses the SDK's SQLite3
// module and never builds this target (Package.swift).
#ifndef REMORA_CSQLITE_H
#define REMORA_CSQLITE_H

#if defined(_WIN32)
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif

#endif
