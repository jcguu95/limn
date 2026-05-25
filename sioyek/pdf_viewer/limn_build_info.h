// limn_build_info.h — runtime-readable build provenance.
//
// All LIMN_BUILD_* symbols are baked into the binary at qmake time by
// pdf_viewer_build_config.pro (the .pro runs $$system(git rev-parse ...)
// etc. and emits matching DEFINES).  Defaults below let local compile
// work even if those -D flags are missing (e.g. someone hand-runs
// `make` outside qmake) — the runtime banner will just show "unknown".
//
// Why this exists: per v0.37 dogfood discipline, every Limn binary
// must be able to print its own git hash + compile time + build
// environment.  Without this, "the binary I'm running was built from
// THIS commit" is unprovable, and any test result becomes ambiguous.
//
// Cost: 5 strings baked into .rodata + one inline banner builder.
// Zero runtime overhead — strings are constants, banner is generated
// on demand.

#pragma once

#ifndef LIMN_BUILD_GIT_HASH
#define LIMN_BUILD_GIT_HASH "unknown"
#endif
#ifndef LIMN_BUILD_GIT_DIRTY
#define LIMN_BUILD_GIT_DIRTY "unknown"
#endif
#ifndef LIMN_BUILD_TIME
#define LIMN_BUILD_TIME "unknown"
#endif
#ifndef LIMN_BUILD_HOST
#define LIMN_BUILD_HOST "unknown"
#endif
#ifndef LIMN_BUILD_QT
#define LIMN_BUILD_QT "unknown"
#endif

// Multi-line banner for stderr / stdout dump.  Caller does not own
// the returned pointer; the string lives in .rodata for process lifetime.
inline const char* limn_build_banner() {
    return
        "── limn build info ─────────────────────────────────────────\n"
        "  git:    " LIMN_BUILD_GIT_HASH " (" LIMN_BUILD_GIT_DIRTY ")\n"
        "  built:  " LIMN_BUILD_TIME "\n"
        "  qt:     " LIMN_BUILD_QT "\n"
        "  host:   " LIMN_BUILD_HOST "\n"
        "────────────────────────────────────────────────────────────\n";
}
