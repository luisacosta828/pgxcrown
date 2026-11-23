#ifndef PGXCROWN_PGX_XACT_H
#define PGXCROWN_PGX_XACT_H

#include "postgres.h"
#include "access/xact.h"
#include "utils/elog.h"

#if defined(__GNUC__) || defined(__clang__)
#define PGX_XACT_WEAK __attribute__((weak))
#else
#define PGX_XACT_WEAK
#endif

typedef void (*PgxXactDispatchFn)(int event, void *arg);
typedef void (*PgxSubXactDispatchFn)(int event, unsigned int mySubid,
                                     unsigned int parentSubid, void *arg);

/* pgx_force_libc_alloc is defined in allocator.nim / pgx.nim */
extern int pgx_force_libc_alloc;

/* Shared weak process-local flags & dispatchers across translation units */
PGX_XACT_WEAK int pgx_xact_registered = 0;
PGX_XACT_WEAK int pgx_subxact_registered = 0;
PGX_XACT_WEAK PgxXactDispatchFn pgx_xact_dispatch_fn = NULL;
PGX_XACT_WEAK PgxSubXactDispatchFn pgx_subxact_dispatch_fn = NULL;

static inline void pgx_push_libc_alloc(void) {
    pgx_force_libc_alloc++;
}

static inline void pgx_pop_libc_alloc(void) {
    if (pgx_force_libc_alloc > 0) {
        pgx_force_libc_alloc--;
    }
}

static inline void pgx_set_xact_dispatcher(PgxXactDispatchFn fn) {
    pgx_xact_dispatch_fn = fn;
}

static inline void pgx_set_subxact_dispatcher(PgxSubXactDispatchFn fn) {
    pgx_subxact_dispatch_fn = fn;
}

static inline void pgx_xact_trampoline(XactEvent event, void *arg) {
    if (pgx_xact_dispatch_fn != NULL) {
        pgx_xact_dispatch_fn((int)event, arg);
    }
}

static inline void pgx_subxact_trampoline(SubXactEvent event, SubTransactionId mySubid,
                                          SubTransactionId parentSubid, void *arg) {
    if (pgx_subxact_dispatch_fn != NULL) {
        pgx_subxact_dispatch_fn((int)event, (unsigned int)mySubid, (unsigned int)parentSubid, arg);
    }
}

static inline void pgx_ensure_xact_registered(void) {
    if (!pgx_xact_registered) {
        RegisterXactCallback(pgx_xact_trampoline, NULL);
        pgx_xact_registered = 1;
    }
}

static inline void pgx_ensure_subxact_registered(void) {
    if (!pgx_subxact_registered) {
        RegisterSubXactCallback(pgx_subxact_trampoline, NULL);
        pgx_subxact_registered = 1;
    }
}

static inline void pgx_xact_emit_warning(const char *msg) {
    ereport(WARNING,
            (errmsg("%s", msg != NULL ? msg : "pgxcrown xact callback warning")));
}

static inline SubTransactionId pgx_current_subxact_id(void) {
    return GetCurrentSubTransactionId();
}

#endif /* PGXCROWN_PGX_XACT_H */
