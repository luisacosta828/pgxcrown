#ifndef PGXCROWN_PGX_IPC_H
#define PGXCROWN_PGX_IPC_H

#include "postgres.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "storage/spin.h"
#include "storage/condition_variable.h"
#include "storage/shmem.h"
#include "storage/ipc.h"
#include "storage/dsm.h"
#include "storage/shm_toc.h"
#if PG_VERSION_NUM >= 170000
#include "storage/dsm_registry.h"
#endif
#include "port/atomics.h"
#include "utils/memutils.h"
#include "utils/palloc.h"
#include "utils/timestamp.h"

static inline int64 pgx_current_time_ms(void) {
    return (int64)(GetCurrentTimestamp() / 1000);
}

/* LWLock & Addin Init Lock helpers */
static inline LWLock *pgx_addin_shmem_init_lock(void) {
    return AddinShmemInitLock;
}

static inline LWLock *pgx_lwlock_tranche_at(LWLockPadded *arr, int index) {
    return &(arr[index].lock);
}

/* SpinLock macro wrappers */
static inline void pgx_spin_init(volatile slock_t *lock) {
    SpinLockInit(lock);
}

static inline void pgx_spin_acquire(volatile slock_t *lock) {
    SpinLockAcquire(lock);
}

static inline void pgx_spin_release(volatile slock_t *lock) {
    SpinLockRelease(lock);
}

static inline bool pgx_spin_free(slock_t *lock) {
    return SpinLockFree(lock);
}

/* ConditionVariable cancel compatibility (void PG 14-15, bool PG 16+) */
static inline void pgx_cv_cancel_sleep(void) {
    (void)ConditionVariableCancelSleep();
}

/* Atomics wrappers */
static inline void pgx_atomic_init_flag(pg_atomic_flag *ptr) {
    pg_atomic_init_flag((volatile pg_atomic_flag *)ptr);
}

static inline bool pgx_atomic_test_set_flag(pg_atomic_flag *ptr) {
    return pg_atomic_test_set_flag((volatile pg_atomic_flag *)ptr);
}

static inline bool pgx_atomic_unlocked_test_flag(pg_atomic_flag *ptr) {
    return pg_atomic_unlocked_test_flag((volatile pg_atomic_flag *)ptr);
}

static inline void pgx_atomic_clear_flag(pg_atomic_flag *ptr) {
    pg_atomic_clear_flag((volatile pg_atomic_flag *)ptr);
}

static inline void pgx_atomic_init_u32(pg_atomic_uint32 *ptr, uint32 val) {
    pg_atomic_init_u32((volatile pg_atomic_uint32 *)ptr, val);
}

static inline uint32 pgx_atomic_read_u32(pg_atomic_uint32 *ptr) {
    return pg_atomic_read_u32((volatile pg_atomic_uint32 *)ptr);
}

static inline void pgx_atomic_write_u32(pg_atomic_uint32 *ptr, uint32 val) {
    pg_atomic_write_u32((volatile pg_atomic_uint32 *)ptr, val);
}

static inline uint32 pgx_atomic_exchange_u32(pg_atomic_uint32 *ptr, uint32 newval) {
    return pg_atomic_exchange_u32((volatile pg_atomic_uint32 *)ptr, newval);
}

static inline bool pgx_atomic_compare_exchange_u32(pg_atomic_uint32 *ptr, uint32 *expected, uint32 newval) {
    return pg_atomic_compare_exchange_u32((volatile pg_atomic_uint32 *)ptr, expected, newval);
}

static inline uint32 pgx_atomic_fetch_add_u32(pg_atomic_uint32 *ptr, int32 addval) {
    return pg_atomic_fetch_add_u32((volatile pg_atomic_uint32 *)ptr, addval);
}

static inline uint32 pgx_atomic_fetch_sub_u32(pg_atomic_uint32 *ptr, int32 subval) {
    return pg_atomic_fetch_sub_u32((volatile pg_atomic_uint32 *)ptr, subval);
}

static inline uint32 pgx_atomic_add_fetch_u32(pg_atomic_uint32 *ptr, int32 addval) {
    return pg_atomic_add_fetch_u32((volatile pg_atomic_uint32 *)ptr, addval);
}

static inline uint32 pgx_atomic_sub_fetch_u32(pg_atomic_uint32 *ptr, int32 subval) {
    return pg_atomic_sub_fetch_u32((volatile pg_atomic_uint32 *)ptr, subval);
}

static inline uint32 pgx_atomic_fetch_and_u32(pg_atomic_uint32 *ptr, uint32 andval) {
    return pg_atomic_fetch_and_u32((volatile pg_atomic_uint32 *)ptr, andval);
}

static inline uint32 pgx_atomic_fetch_or_u32(pg_atomic_uint32 *ptr, uint32 orval) {
    return pg_atomic_fetch_or_u32((volatile pg_atomic_uint32 *)ptr, orval);
}

static inline void pgx_atomic_init_u64(pg_atomic_uint64 *ptr, uint64 val) {
    pg_atomic_init_u64((volatile pg_atomic_uint64 *)ptr, val);
}

static inline uint64 pgx_atomic_read_u64(pg_atomic_uint64 *ptr) {
    return pg_atomic_read_u64((volatile pg_atomic_uint64 *)ptr);
}

static inline void pgx_atomic_write_u64(pg_atomic_uint64 *ptr, uint64 val) {
    pg_atomic_write_u64((volatile pg_atomic_uint64 *)ptr, val);
}

static inline uint64 pgx_atomic_exchange_u64(pg_atomic_uint64 *ptr, uint64 newval) {
    return pg_atomic_exchange_u64((volatile pg_atomic_uint64 *)ptr, newval);
}

static inline bool pgx_atomic_compare_exchange_u64(pg_atomic_uint64 *ptr, uint64 *expected, uint64 newval) {
    return pg_atomic_compare_exchange_u64((volatile pg_atomic_uint64 *)ptr, expected, newval);
}

static inline uint64 pgx_atomic_fetch_add_u64(pg_atomic_uint64 *ptr, int64 addval) {
    return pg_atomic_fetch_add_u64((volatile pg_atomic_uint64 *)ptr, addval);
}

static inline uint64 pgx_atomic_fetch_sub_u64(pg_atomic_uint64 *ptr, int64 subval) {
    return pg_atomic_fetch_sub_u64((volatile pg_atomic_uint64 *)ptr, subval);
}

static inline uint64 pgx_atomic_add_fetch_u64(pg_atomic_uint64 *ptr, int64 addval) {
    return pg_atomic_add_fetch_u64((volatile pg_atomic_uint64 *)ptr, addval);
}

static inline uint64 pgx_atomic_sub_fetch_u64(pg_atomic_uint64 *ptr, int64 subval) {
    return pg_atomic_sub_fetch_u64((volatile pg_atomic_uint64 *)ptr, subval);
}

static inline uint64 pgx_atomic_fetch_and_u64(pg_atomic_uint64 *ptr, uint64 andval) {
    return pg_atomic_fetch_and_u64((volatile pg_atomic_uint64 *)ptr, andval);
}

static inline uint64 pgx_atomic_fetch_or_u64(pg_atomic_uint64 *ptr, uint64 orval) {
    return pg_atomic_fetch_or_u64((volatile pg_atomic_uint64 *)ptr, orval);
}

/* Shmem alignment and shm_toc macro wrappers */
static inline Size pgx_maxalign(Size sz) {
    return (Size)MAXALIGN(sz);
}

static inline Size pgx_bufferalign(Size sz) {
    return (Size)BUFFERALIGN(sz);
}

static inline void pgx_shm_toc_init_estimator(shm_toc_estimator *e) {
    shm_toc_initialize_estimator(e);
}

static inline void pgx_shm_toc_estimate_chunk(shm_toc_estimator *e, Size sz) {
    shm_toc_estimate_chunk(e, sz);
}

static inline void pgx_shm_toc_estimate_keys(shm_toc_estimator *e, Size cnt) {
    shm_toc_estimate_keys(e, cnt);
}

#if PG_VERSION_NUM >= 170000
typedef void (*PgxNamedDsmInitFn)(void *ptr);
static inline void *pgx_get_named_dsm_segment(const char *name, size_t size, PgxNamedDsmInitFn init_cb, bool *found) {
    return GetNamedDSMSegment(name, size, init_cb, found);
}
static inline bool pgx_has_named_dsm_registry(void) {
    return true;
}
#else
typedef void (*PgxNamedDsmInitFn)(void *ptr);
static inline void *pgx_get_named_dsm_segment(const char *name, size_t size, PgxNamedDsmInitFn init_cb, bool *found) {
    (void)name; (void)size; (void)init_cb;
    if (found != NULL) *found = false;
    return NULL;
}
static inline bool pgx_has_named_dsm_registry(void) {
    return false;
}
#endif

/* Static shared memory hook helpers (stateless inline; safe across PG 14-17 and unused unit tests) */
typedef void (*PgxShmemHookFn)(void);

static inline bool pgx_has_shmem_request_hook(void) {
#if PG_VERSION_NUM >= 150000
    return true;
#else
    return false;
#endif
}

static inline bool pgx_is_shared_preload_in_progress(void) {
    return process_shared_preload_libraries_in_progress;
}

static inline PgxShmemHookFn pgx_get_shmem_startup_hook(void) {
    return (PgxShmemHookFn)shmem_startup_hook;
}

static inline void pgx_set_shmem_startup_hook(PgxShmemHookFn fn) {
    shmem_startup_hook = (shmem_startup_hook_type)fn;
}

static inline PgxShmemHookFn pgx_get_shmem_request_hook(void) {
#if PG_VERSION_NUM >= 150000
    return (PgxShmemHookFn)shmem_request_hook;
#else
    return NULL;
#endif
}

static inline void pgx_set_shmem_request_hook(PgxShmemHookFn fn) {
#if PG_VERSION_NUM >= 150000
    shmem_request_hook = (shmem_request_hook_type)fn;
#else
    (void)fn;
#endif
}

#endif /* PGXCROWN_PGX_IPC_H */
