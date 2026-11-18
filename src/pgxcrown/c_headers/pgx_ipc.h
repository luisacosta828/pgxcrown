#ifndef PGXCROWN_PGX_IPC_H
#define PGXCROWN_PGX_IPC_H

#include "postgres.h"
#include "storage/lwlock.h"
#include "storage/spin.h"
#include "storage/condition_variable.h"
#include "port/atomics.h"
#include "utils/memutils.h"
#include "utils/palloc.h"

static inline LWLock *pgx_addin_shmem_init_lock(void) {
    return AddinShmemInitLock;
}

static inline LWLock *pgx_lwlock_tranche_at(LWLockPadded *arr, int index) {
    return &(arr[index].lock);
}

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

static inline void pgx_cv_cancel_sleep(void) {
    (void)ConditionVariableCancelSleep();
}

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

#endif /* PGXCROWN_PGX_IPC_H */
