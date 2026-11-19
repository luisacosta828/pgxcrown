import std/strutils

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len >
    0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") & " -I" & (
    if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql") &
    " -include postgres.h".}

import std/unittest

{.emit: """
#include "postgres.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "storage/spin.h"
#include "storage/condition_variable.h"
#include "storage/shmem.h"
#include "storage/ipc.h"
#include "storage/dsm.h"
#include "storage/shm_toc.h"
#include "utils/palloc.h"
#include "utils/timestamp.h"
#include "pgx_ipc.h"
#include <stdlib.h>
#include <string.h>

TimestampTz GetCurrentTimestamp(void) {
    static TimestampTz mockTs = 1000000;
    mockTs += 1000;
    return mockTs;
}

/* Allocator & error state mocks */
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

bool errstart(int elevel, const char *domain) { (void)elevel; (void)domain; return false; }
void errfinish(const char *filename, int lineno, const char *funcname) { (void)filename; (void)lineno; (void)funcname; }
int errcode(int sqlerrcode) { (void)sqlerrcode; return 0; }
int errmsg(const char *fmt, ...) { (void)fmt; return 0; }
int errdetail(const char *fmt, ...) { (void)fmt; return 0; }
int errhint(const char *fmt, ...) { (void)fmt; return 0; }
ErrorData *CopyErrorData(void) { return NULL; }
void FlushErrorState(void) {}
void pg_re_throw(void) { abort(); }
void FreeErrorData(ErrorData *edata) { (void)edata; }
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void *palloc(Size size) { return malloc(size); }
void pfree(void *ptr) { if (ptr) free(ptr); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size); }

int s_lock(volatile slock_t *lock, const char *file, int line, const char *func) {
    (void)file; (void)line; (void)func;
    while (TAS(lock)) {}
    return 0;
}

/* LWLock mocks */
LWLockPadded mockMainArray[32];
LWLockPadded *MainLWLockArray = mockMainArray;
LWLock *mockHeldLock = NULL;
int mockAddinLockCount = 0;

bool LWLockAcquire(LWLock *lock, LWLockMode mode) {
    (void)mode;
    mockHeldLock = lock;
    if (lock == AddinShmemInitLock) mockAddinLockCount++;
    return true;
}
bool LWLockConditionalAcquire(LWLock *lock, LWLockMode mode) {
    return LWLockAcquire(lock, mode);
}
void LWLockRelease(LWLock *lock) {
    if (mockHeldLock == lock) mockHeldLock = NULL;
}
bool LWLockHeldByMe(LWLock *lock) {
    return lock != NULL && mockHeldLock == lock;
}

/* Shmem static hooks mocks */
bool process_shared_preload_libraries_in_progress = false;
shmem_startup_hook_type shmem_startup_hook = NULL;
#if PG_VERSION_NUM >= 150000
shmem_request_hook_type shmem_request_hook = NULL;
#endif

Size mockRequestedBytes = 0;
char mockLastStructName[64] = {0};
Size mockLastStructSize = 0;
bool mockForceStructFound = false;
int mockStructLockHeld = 0;
unsigned char mockStructStorage[1024];

void RequestAddinShmemSpace(Size size) {
    mockRequestedBytes += size;
}

void *ShmemInitStruct(const char *name, Size size, bool *foundPtr) {
    mockStructLockHeld = (mockHeldLock == AddinShmemInitLock) ? 1 : 0;
    mockLastStructSize = size;
    mockLastStructName[0] = '\0';
    if (name) strncpy(mockLastStructName, name, sizeof(mockLastStructName) - 1);
    if (foundPtr) *foundPtr = mockForceStructFound;
    if (!mockForceStructFound) {
        memset(mockStructStorage, 0xAA, sizeof(mockStructStorage));
    }
    return (void *)mockStructStorage;
}

Size add_size(Size s1, Size s2) { return s1 + s2; }
Size mul_size(Size s1, Size s2) { return s1 * s2; }

int mockPrevReqCalls = 0;
int mockPrevStartCalls = 0;
void mockPrevRequestFn(void) { mockPrevReqCalls++; }
void mockPrevStartupFn(void) { mockPrevStartCalls++; }

/* DSM & shm_toc stateful in-memory mocks */
struct dsm_segment {
    dsm_handle handle;
    void *addr;
    Size len;
    int pinnedMapping;
    int pinnedSegment;
    int attachedCount;
};

#define MAX_MOCK_DSM 8
struct dsm_segment mockDsmSlots[MAX_MOCK_DSM];
int mockDsmAttachCalls = 0;
int mockDsmFindCalls = 0;
int mockDsmDetachCalls = 0;

struct FakeTocEntry {
    uint64 key;
    void *ptr;
};
struct shm_toc {
    uint64 magic;
    unsigned char *base;
    Size total;
    Size offset;
    struct FakeTocEntry entries[32];
    int count;
};
struct shm_toc mockTocObj;

dsm_segment *dsm_create(Size size, int flags) {
    (void)flags;
    for (int i = 0; i < MAX_MOCK_DSM; i++) {
        if (mockDsmSlots[i].handle == 0) {
            mockDsmSlots[i].handle = (dsm_handle)(100 + i);
            mockDsmSlots[i].addr = calloc(1, size);
            mockDsmSlots[i].len = size;
            mockDsmSlots[i].attachedCount = 1;
            return &mockDsmSlots[i];
        }
    }
    return NULL;
}

dsm_segment *dsm_find_mapping(dsm_handle h) {
    mockDsmFindCalls++;
    for (int i = 0; i < MAX_MOCK_DSM; i++) {
        if (mockDsmSlots[i].handle == h && mockDsmSlots[i].attachedCount > 0) {
            return &mockDsmSlots[i];
        }
    }
    return NULL;
}

dsm_segment *dsm_attach(dsm_handle h) {
    mockDsmAttachCalls++;
    for (int i = 0; i < MAX_MOCK_DSM; i++) {
        if (mockDsmSlots[i].handle == h) {
            mockDsmSlots[i].attachedCount++;
            return &mockDsmSlots[i];
        }
    }
    return NULL;
}

void dsm_detach(dsm_segment *seg) {
    if (!seg) return;
    mockDsmDetachCalls++;
    if (seg->attachedCount > 0) seg->attachedCount--;
    if (seg->attachedCount == 0 && !seg->pinnedSegment) {
        free(seg->addr);
        seg->addr = NULL;
        seg->handle = 0;
    }
}

void dsm_pin_mapping(dsm_segment *seg) { if (seg) seg->pinnedMapping = 1; }
void dsm_unpin_mapping(dsm_segment *seg) { if (seg) seg->pinnedMapping = 0; }
void dsm_pin_segment(dsm_segment *seg) { if (seg) seg->pinnedSegment = 1; }
void dsm_unpin_segment(dsm_handle h) {
    for (int i = 0; i < MAX_MOCK_DSM; i++) {
        if (mockDsmSlots[i].handle == h) {
            mockDsmSlots[i].pinnedSegment = 0;
            if (mockDsmSlots[i].attachedCount == 0) {
                free(mockDsmSlots[i].addr);
                mockDsmSlots[i].addr = NULL;
                mockDsmSlots[i].handle = 0;
            }
        }
    }
}
void *dsm_segment_address(dsm_segment *seg) { return seg ? seg->addr : NULL; }
Size dsm_segment_map_length(dsm_segment *seg) { return seg ? seg->len : 0; }
dsm_handle dsm_segment_handle(dsm_segment *seg) { return seg ? seg->handle : 0; }
void on_dsm_detach(dsm_segment *seg, on_dsm_detach_callback fn, Datum arg) { (void)seg; (void)fn; (void)arg; }
void cancel_on_dsm_detach(dsm_segment *seg, on_dsm_detach_callback fn, Datum arg) { (void)seg; (void)fn; (void)arg; }

shm_toc *shm_toc_create(uint64 magic, void *address, Size nbytes) {
    memset(&mockTocObj, 0, sizeof(mockTocObj));
    mockTocObj.magic = magic;
    mockTocObj.base = (unsigned char *)address;
    mockTocObj.total = nbytes;
    mockTocObj.offset = 64;
    return &mockTocObj;
}

shm_toc *shm_toc_attach(uint64 magic, void *address) {
    if (mockTocObj.magic == magic && mockTocObj.base == (unsigned char *)address) {
        return &mockTocObj;
    }
    return NULL;
}

void *shm_toc_allocate(shm_toc *toc, Size nbytes) {
    Size aligned = BUFFERALIGN(nbytes);
    if (toc->offset + aligned > toc->total) return NULL;
    void *res = toc->base + toc->offset;
    toc->offset += aligned;
    return res;
}

Size shm_toc_freespace(shm_toc *toc) {
    return (toc->total > toc->offset) ? (toc->total - toc->offset) : 0;
}

void shm_toc_insert(shm_toc *toc, uint64 key, void *address) {
    toc->entries[toc->count].key = key;
    toc->entries[toc->count].ptr = address;
    toc->count++;
}

void *shm_toc_lookup(shm_toc *toc, uint64 key, bool noError) {
    (void)noError;
    for (int i = 0; i < toc->count; i++) {
        if (toc->entries[i].key == key) return toc->entries[i].ptr;
    }
    return NULL;
}

Size shm_toc_estimate(shm_toc_estimator *e) {
    return 64 + e->space_for_chunks + (e->number_of_keys * 32);
}

#if PG_VERSION_NUM >= 170000
unsigned char mockNamedDsm[256];
void *GetNamedDSMSegment(const char *name, size_t size, void (*init_callback)(void *ptr), bool *found) {
    (void)name; (void)size;
    if (found) *found = false;
    if (init_callback) init_callback(mockNamedDsm);
    return mockNamedDsm;
}
#endif

void pgx_reset_shmem_mocks(void) {
    memset(mockMainArray, 0, sizeof(mockMainArray));
    mockHeldLock = NULL;
    mockAddinLockCount = 0;
    process_shared_preload_libraries_in_progress = false;
    shmem_startup_hook = NULL;
#if PG_VERSION_NUM >= 150000
    shmem_request_hook = NULL;
#endif
    mockRequestedBytes = 0;
    mockLastStructName[0] = '\0';
    mockLastStructSize = 0;
    mockForceStructFound = false;
    mockStructLockHeld = 0;
    mockPrevReqCalls = 0;
    mockPrevStartCalls = 0;
    for (int i = 0; i < MAX_MOCK_DSM; i++) {
        if (mockDsmSlots[i].addr) free(mockDsmSlots[i].addr);
    }
    memset(mockDsmSlots, 0, sizeof(mockDsmSlots));
    mockDsmAttachCalls = 0;
    mockDsmFindCalls = 0;
    mockDsmDetachCalls = 0;
}

void pgx_setup_prev_hooks(void) {
    shmem_startup_hook = mockPrevStartupFn;
#if PG_VERSION_NUM >= 150000
    shmem_request_hook = mockPrevRequestFn;
#endif
}

void pgx_fire_hooks(void) {
#if PG_VERSION_NUM >= 150000
    if (shmem_request_hook) shmem_request_hook();
#endif
    if (shmem_startup_hook) shmem_startup_hook();
}

int pgx_is_pg15_plus(void) {
#if PG_VERSION_NUM >= 150000
    return 1;
#else
    return 0;
#endif
}

int pgx_is_pg17_plus(void) {
#if PG_VERSION_NUM >= 170000
    return 1;
#else
    return 0;
#endif
}
""".}

import ../src/pgxcrown/lwlock
import ../src/pgxcrown/shmem

type
  GoodPodState* {.bycopy.} = object
    lock*: LWLock
    counter*: pg_atomic_uint64
    magic*: uint64
    label*: FixedString[16]

  BadHeapShmem* {.bycopy.} = object
    lock*: LWLock
    oops*: string

  BadSeqShmem* {.bycopy.} = object
    vals*: seq[int32]

proc resetShmemMocks() {.importc: "pgx_reset_shmem_mocks", nodecl.}
proc setupPrevHooks() {.importc: "pgx_setup_prev_hooks", nodecl.}
proc fireHooks() {.importc: "pgx_fire_hooks", nodecl.}
proc isPg15Plus(): cint {.importc: "pgx_is_pg15_plus", nodecl.}
proc isPg17Plus(): cint {.importc: "pgx_is_pg17_plus", nodecl.}

suite "Pgxcrown - Shared Memory & Dynamic Shared Memory (DSM / shm_toc) Suite":

  test "Compile-time POD enforcement in shmem allocators and estimators":
    var seg: DsmSegment = nil
    var est = initEstimator()
    check compiles(est.estimateChunk[:GoodPodState]()) == true
    check compiles(est.estimateChunk[:BadHeapShmem]()) == false
    check compiles(est.estimateChunk[:BadSeqShmem]()) == false

    var toc: ShmTocPtr = nil
    check compiles(toc.allocStruct[:BadHeapShmem](1'u64)) == false
    check compiles(initShmemStruct[BadHeapShmem]("bad")) == false
    check compiles(requestShmemSpace[BadHeapShmem]()) == false
    discard seg
    discard toc

  test "Alignment, size arithmetic, and shm_toc_estimator wrappers":
    check maxAlign(1.csize_t) >= 8.csize_t
    check maxAlign(9.csize_t) >= 16.csize_t
    check bufferAlign(1.csize_t) >= 8.csize_t
    check addSize(10.csize_t, 22.csize_t) == 32.csize_t
    check mulSize(4.csize_t, 8.csize_t) == 32.csize_t

    var est = initEstimator()
    est.estimateChunk[:GoodPodState]()
    est.estimateChunk(128.csize_t)
    est.estimateKeys(2.csize_t)
    let needed = est.estimate()
    check needed >= pgSizeOf[GoodPodState]() + 128.csize_t

  test "Static shmem hooks enforce preload and chain prev hooks safely across PG 14-17":
    resetShmemMocks()
    var preloadInProgress {.importc: "process_shared_preload_libraries_in_progress".}: bool
    var mockRequestedBytes {.importc.}: csize_t
    var mockPrevReqCalls {.importc.}: cint
    var mockPrevStartCalls {.importc.}: cint

    # Reject requesting shmem outside shared_preload_libraries
    preloadInProgress = false
    expect(ValueError):
      installShmemHooks(
        proc() = requestShmemSpace[GoodPodState](),
        proc() = discard
      )

    # Enable preload and install pre-existing hooks before ours
    resetShmemMocks()
    preloadInProgress = true
    setupPrevHooks()

    var reqCount = 0
    var startCount = 0
    let onReq = proc() =
      inc reqCount
      requestShmemSpace[GoodPodState](64.csize_t)
    let onStart = proc() =
      inc startCount

    installShmemHooks(onReq, onStart)
    # Re-installing must NOT self-loop previous hook
    installShmemHooks(onReq, onStart)

    fireHooks()

    if isPg15Plus() == 1:
      check mockPrevReqCalls == 1
      check reqCount == 1
    else:
      # PG 14 fires onReq immediately during installShmemHooks calls
      check reqCount == 2

    check mockPrevStartCalls == 1
    check startCount == 1
    check mockRequestedBytes >= pgSizeOf[GoodPodState]() + 64.csize_t

  test "initShmemStruct locks AddinShmemInitLock, zeroes first allocation, and skips re-init":
    resetShmemMocks()
    var mockStructLockHeld {.importc.}: cint
    var mockForceStructFound {.importc.}: bool
    var mockLastStructSize {.importc.}: csize_t

    expect(ValueError):
      discard initShmemStruct[GoodPodState]("")
    expect(ValueError):
      discard initShmemStruct[GoodPodState](repeat('x', SHMEM_INDEX_KEYSIZE))

    var initCalls = 0
    mockForceStructFound = false
    let (p1, found1) = initShmemStruct[GoodPodState]("pgx_test_state",
      proc(s: ptr GoodPodState) =
        inc initCalls
        check s.magic == 0'u64 # zeroed even though mock filled 0xAA
        s.magic = 0xCAFEBABE'u64
        s.label.setStr("first")
    )
    check found1 == false
    check initCalls == 1
    check mockStructLockHeld == 1
    check mockLastStructSize == pgSizeOf[GoodPodState]()
    check p1.magic == 0xCAFEBABE'u64
    check $p1.label == "first"

    # Second process lookup finds existing struct without zeroing or calling initCb
    mockForceStructFound = true
    let (p2, found2) = initShmemStruct[GoodPodState]("pgx_test_state",
      proc(s: ptr GoodPodState) =
        inc initCalls
    )
    check found2 == true
    check initCalls == 1
    check p2 == p1
    check p2.magic == 0xCAFEBABE'u64

  test "DSM create, attachOrFind, pinning, and shm_toc typed round-trip":
    resetShmemMocks()
    var mockDsmAttachCalls {.importc.}: cint
    var mockDsmFindCalls {.importc.}: cint
    var mockDsmDetachCalls {.importc.}: cint

    expect(ValueError):
      discard dsmAttach(DSM_HANDLE_INVALID)
    expect(ValueError):
      discard dsmAttachOrFind(DSM_HANDLE_INVALID)

    var est = initEstimator()
    est.estimateChunk[:GoodPodState]()
    est.estimateChunk(64.csize_t)
    est.estimateKeys(2.csize_t)
    let totalSize = est.estimate()

    let seg = dsmCreate(totalSize)
    check seg != nil
    let h = dsmHandle(seg)
    check h >= 100'u32
    dsmPinMapping(seg)
    dsmPinSegment(seg)

    let toc = seg.createToc(0x50475831'u64)
    check toc.tocFreespace() > 0.csize_t

    let state = toc.allocStruct[:GoodPodState](1'u64)
    check state.magic == 0'u64
    state.magic = 0xDEADBEEF'u64
    (addr state.counter).init(77'u64)
    state.label.setStr("dsm_ok")

    let rawBuf = toc.allocBytes(2'u64, 32.csize_t)
    cast[ptr uint32](rawBuf)[] = 999'u32

    # Same-process dsmAttachOrFind reuses mapping without invoking dsm_attach
    let segSame = dsmAttachOrFind(h)
    check segSame == seg
    check mockDsmFindCalls == 1
    check mockDsmAttachCalls == 0

    let attachedToc = segSame.attachToc(0x50475831'u64)
    let foundState = attachedToc.lookupStruct[:GoodPodState](1'u64)
    check foundState == state
    check foundState.magic == 0xDEADBEEF'u64
    check (addr foundState.counter).load() == 77'u64
    check $foundState.label == "dsm_ok"
    check cast[ptr uint32](attachedToc.lookupBytes(2'u64))[] == 999'u32

    dsmDetach(seg)
    check mockDsmDetachCalls == 1
    dsmUnpinSegment(h)

  test "PG 17 Named DSM Registry guard behaves properly across PG 14-17":
    var found = false
    if isPg17Plus() == 1:
      var dummy = getNamedDsmSegment("pgx_named_test", 128.csize_t, nil, found)
      check dummy != nil
      check found == false
    else:
      expect(ValueError):
        discard getNamedDsmSegment("pgx_named_test", 128.csize_t, nil, found)
