import std/[unittest, strutils]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

{.emit: """
#include "postgres.h"
#include "storage/shm_mq.h"
#include "storage/shm_toc.h"
#include "storage/proc.h"
#include "postmaster/bgworker.h"
#include <stdlib.h>
#include <string.h>

const Size shm_mq_minimum_size = 64;
static PGPROC mockProcStorage;
PGPROC *MyProc = &mockProcStorage;

typedef struct MockShmMq {
    PGPROC *sender;
    PGPROC *receiver;
    bool detached;
    Size cap;
    char buf[4096];
    Size msgLen;
    bool hasMsg;
    int forceFlushCalls;
} MockShmMq;

typedef struct MockShmMqHandle {
    MockShmMq *mq;
    BackgroundWorkerHandle *bgw;
    bool detached;
} MockShmMqHandle;

shm_mq *shm_mq_create(void *address, Size size) {
    MockShmMq *m = (MockShmMq *)address;
    memset(m, 0, sizeof(MockShmMq));
    m->cap = size;
    return (shm_mq *)m;
}

void shm_mq_set_sender(shm_mq *mq, PGPROC *proc) {
    ((MockShmMq *)mq)->sender = proc;
}

void shm_mq_set_receiver(shm_mq *mq, PGPROC *proc) {
    ((MockShmMq *)mq)->receiver = proc;
}

shm_mq_handle *shm_mq_attach(shm_mq *mq, dsm_segment *seg, BackgroundWorkerHandle *bgw_handle) {
    (void)seg;
    MockShmMqHandle *h = (MockShmMqHandle *)calloc(1, sizeof(MockShmMqHandle));
    h->mq = (MockShmMq *)mq;
    h->bgw = bgw_handle;
    return (shm_mq_handle *)h;
}

void shm_mq_set_handle(shm_mq_handle *mqh, BackgroundWorkerHandle *bgw_handle) {
    ((MockShmMqHandle *)mqh)->bgw = bgw_handle;
}

void shm_mq_detach(shm_mq_handle *mqh) {
    MockShmMqHandle *h = (MockShmMqHandle *)mqh;
    if (h != NULL) {
        if (h->mq != NULL) h->mq->detached = true;
        h->detached = true;
        free(h);
    }
}

shm_mq_result shm_mq_wait_for_attach(shm_mq_handle *mqh) {
    MockShmMqHandle *h = (MockShmMqHandle *)mqh;
    if (h == NULL || h->mq == NULL || h->mq->detached) return SHM_MQ_DETACHED;
    return SHM_MQ_SUCCESS;
}

#if PG_VERSION_NUM >= 150000
shm_mq_result shm_mq_send(shm_mq_handle *mqh, Size nbytes, const void *data, bool nowait, bool force_flush)
#else
shm_mq_result shm_mq_send(shm_mq_handle *mqh, Size nbytes, const void *data, bool nowait)
#endif
{
    MockShmMqHandle *h = (MockShmMqHandle *)mqh;
    if (h == NULL || h->mq == NULL || h->mq->detached) return SHM_MQ_DETACHED;
#if PG_VERSION_NUM >= 150000
    if (force_flush) h->mq->forceFlushCalls++;
#endif
    if (h->mq->hasMsg) {
        if (nowait) return SHM_MQ_WOULD_BLOCK;
        return SHM_MQ_WOULD_BLOCK;
    }
    if (nbytes > sizeof(h->mq->buf)) return SHM_MQ_WOULD_BLOCK;
    if (nbytes > 0 && data != NULL) {
        memcpy(h->mq->buf, data, nbytes);
    }
    h->mq->msgLen = nbytes;
    h->mq->hasMsg = true;
    return SHM_MQ_SUCCESS;
}

#if PG_VERSION_NUM >= 150000
shm_mq_result shm_mq_sendv(shm_mq_handle *mqh, shm_mq_iovec *iov, int iovcnt, bool nowait, bool force_flush)
#else
shm_mq_result shm_mq_sendv(shm_mq_handle *mqh, shm_mq_iovec *iov, int iovcnt, bool nowait)
#endif
{
    MockShmMqHandle *h = (MockShmMqHandle *)mqh;
    if (h == NULL || h->mq == NULL || h->mq->detached) return SHM_MQ_DETACHED;
#if PG_VERSION_NUM >= 150000
    if (force_flush) h->mq->forceFlushCalls++;
#endif
    if (h->mq->hasMsg) {
        (void)nowait;
        return SHM_MQ_WOULD_BLOCK;
    }
    Size total = 0;
    for (int i = 0; i < iovcnt; i++) {
        if (total + iov[i].len > sizeof(h->mq->buf)) return SHM_MQ_WOULD_BLOCK;
        if (iov[i].len > 0 && iov[i].data != NULL) {
            memcpy(h->mq->buf + total, iov[i].data, iov[i].len);
            total += iov[i].len;
        }
    }
    h->mq->msgLen = total;
    h->mq->hasMsg = true;
    return SHM_MQ_SUCCESS;
}

shm_mq_result shm_mq_receive(shm_mq_handle *mqh, Size *nbytesp, void **datap, bool nowait) {
    MockShmMqHandle *h = (MockShmMqHandle *)mqh;
    if (h == NULL || h->mq == NULL) return SHM_MQ_DETACHED;
    if (!h->mq->hasMsg) {
        if (h->mq->detached) return SHM_MQ_DETACHED;
        if (nowait) return SHM_MQ_WOULD_BLOCK;
        return SHM_MQ_WOULD_BLOCK;
    }
    *nbytesp = h->mq->msgLen;
    *datap = h->mq->buf;
    h->mq->hasMsg = false;
    return SHM_MQ_SUCCESS;
}

/* Minimal shm_toc mock for RPC channel layout helper */
typedef struct MockTocEntry {
    uint64 key;
    void *ptr;
} MockTocEntry;

typedef struct MockToc {
    uint64 magic;
    char *base;
    Size used;
    Size cap;
    int count;
    MockTocEntry entries[16];
} MockToc;

typedef struct MockDsmSeg {
    void *addr;
    Size len;
} MockDsmSeg;

void *dsm_segment_address(dsm_segment *seg) {
    return ((MockDsmSeg *)seg)->addr;
}

Size dsm_segment_map_length(dsm_segment *seg) {
    return ((MockDsmSeg *)seg)->len;
}

Size add_size(Size s1, Size s2) { return s1 + s2; }
Size shm_toc_estimate(shm_toc_estimator *e) {
    return e->space_for_chunks + (e->number_of_keys * 32) + 64;
}

shm_toc *shm_toc_create(uint64 magic, void *address, Size nbytes) {
    MockToc *t = (MockToc *)address;
    memset(t, 0, sizeof(MockToc));
    t->magic = magic;
    t->base = (char *)address + MAXALIGN(sizeof(MockToc));
    t->used = 0;
    t->cap = nbytes - MAXALIGN(sizeof(MockToc));
    return (shm_toc *)t;
}

void *shm_toc_allocate(shm_toc *toc, Size nbytes) {
    MockToc *t = (MockToc *)toc;
    Size aligned = MAXALIGN(nbytes);
    void *p = t->base + t->used;
    t->used += aligned;
    return p;
}

void shm_toc_insert(shm_toc *toc, uint64 key, void *address) {
    MockToc *t = (MockToc *)toc;
    t->entries[t->count].key = key;
    t->entries[t->count].ptr = address;
    t->count++;
}

void *shm_toc_lookup(shm_toc *toc, uint64 key, bool noError) {
    MockToc *t = (MockToc *)toc;
    for (int i = 0; i < t->count; i++) {
        if (t->entries[i].key == key) return t->entries[i].ptr;
    }
    (void)noError;
    return NULL;
}

int mock_get_force_flush_calls(shm_mq *mq) {
    return ((MockShmMq *)mq)->forceFlushCalls;
}

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
void pfree(void *ptr) { if (ptr) free(ptr); }
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
""".}

import pgxcrown/lwlock
import pgxcrown/shmem
import pgxcrown/shm_mq

type
  RpcOrderPod {.bycopy.} = object
    orderId*: int64
    amountCents*: int64
    code*: uint32

  NonPodRpc = object
    badStr*: string

proc mockGetForceFlushCalls(mq: ShmMqPtr): cint {.importc: "mock_get_force_flush_calls", nodecl.}

suite "Pgxcrown - Shared Memory Message Queue (shm_mq) Suite":
  test "createMq validates non-nil address and shm_mq_minimum_size":
    check shmMqMinimumSize() == 64.csize_t
    expect(ValueError):
      discard createMq(nil, 256.csize_t)
    var rawMem: array[8192, byte]
    expect(ValueError):
      discard createMq(addr rawMem[0], 32.csize_t)

  test "send, receive, receiveBytes, sendv, and mqWouldBlock/mqDetached semantics":
    var rawMem: array[8192, byte]
    let mq = createMq(addr rawMem[0], 4096.csize_t)
    check mq != nil
    check myProc() != nil

    mq.setSender()
    mq.setReceiver()

    let senderH = attachMq(mq)
    let recvH = attachMq(mq)
    check waitForAttach(senderH) == mqSuccess

    # Empty queue non-blocking receive returns mqWouldBlock
    let emptyRes = recvH.receive(nowait = true)
    check emptyRes.status == mqWouldBlock
    check emptyRes.payload == ""

    # String round-trip
    check senderH.send("hello pgxcrown", nowait = true) == mqSuccess
    let r1 = recvH.receive(nowait = true)
    check r1.status == mqSuccess
    check r1.payload == "hello pgxcrown"

    # Empty string round-trip
    check senderH.send("", nowait = true) == mqSuccess
    let rEmpty = recvH.receive(nowait = true)
    check rEmpty.status == mqSuccess
    check rEmpty.payload == ""

    # Byte slice round-trip
    let rawBytes: seq[byte] = @[0x01'u8, 0x00'u8, 0xFE'u8, 0x7F'u8]
    check senderH.send(rawBytes, nowait = true) == mqSuccess
    let rBytes = recvH.receiveBytes(nowait = true)
    check rBytes.status == mqSuccess
    check rBytes.payload == rawBytes

    # Scatter-gather sendv round-trip
    let p1 = "rpc:"
    let p2 = "42"
    let iovs = [
      ShmMqIovec(data: cstring(p1), len: csize_t(p1.len)),
      ShmMqIovec(data: cstring(p2), len: csize_t(p2.len))
    ]
    check senderH.sendv(iovs, nowait = true) == mqSuccess
    let rVec = recvH.receive(nowait = true)
    check rVec.status == mqSuccess
    check rVec.payload == "rpc:42"

    # Detach notifies peer
    check mockGetForceFlushCalls(mq) >= 0
    detachMq(senderH)
    let rDetached = recvH.receive(nowait = true)
    check rDetached.status == mqDetached
    detachMq(recvH)

  test "Bidirectional RPC channel helper over shm_toc":
    var est = initEstimator()
    est.estimateRpcQueues(4096.csize_t, 4096.csize_t)
    let totalBytes = est.estimate()
    check totalBytes >= 8192.csize_t

    var arena = newSeq[byte](int(totalBytes) + 16384)
    type MockDsmObj = object
      address: pointer
      length: csize_t
    var mockSeg = MockDsmObj(address: addr arena[0], length: csize_t(arena.len))
    let toc = createToc(cast[DsmSegment](addr mockSeg), 0x52504331'u64)
    let rpc = createRpcQueues(toc, 1'u64, 2'u64, 4608.csize_t, 4608.csize_t)
    check rpc.reqMq != nil
    check rpc.respMq != nil

    let lookedUp = lookupRpcQueues(toc, 1'u64, 2'u64)
    check lookedUp.reqMq == rpc.reqMq
    check lookedUp.respMq == rpc.respMq

    let reqH = attachMq(lookedUp.reqMq)
    let respH = attachMq(lookedUp.respMq)
    check reqH.send("ping", nowait = true) == mqSuccess
    let gotReq = reqH.receive(nowait = true)
    check gotReq.status == mqSuccess and gotReq.payload == "ping"
    check respH.send("pong", nowait = true) == mqSuccess
    let gotResp = respH.receive(nowait = true)
    check gotResp.status == mqSuccess and gotResp.payload == "pong"
    detachMq(reqH)
    detachMq(respH)

  test "Generic typed ShmChannel[T] enforces POD safety, size match, and round-trip":
    check compiles(openSendChannel[RpcOrderPod](nil)) == true
    check compiles(openSendChannel[NonPodRpc](nil)) == false
    check compiles(openSendChannel[string](nil)) == false

    var rawMem: array[8192, byte]
    let mq = createMq(addr rawMem[0], 4096.csize_t)
    var tx = openSendChannel[RpcOrderPod](mq)
    var rx = openRecvChannel[RpcOrderPod](mq)
    check tx.waitForAttach() == mqSuccess

    var emptyOrder: RpcOrderPod
    check rx.tryReceive(emptyOrder) == mqWouldBlock

    let sent = RpcOrderPod(orderId: 9001, amountCents: 12345, code: 77'u32)
    check tx.send(sent, nowait = true) == mqSuccess
    let got = rx.receive(nowait = true)
    check got.status == mqSuccess
    check got.value.orderId == 9001
    check got.value.amountCents == 12345
    check got.value.code == 77'u32

    # tryReceive non-blocking path
    check tx.send(RpcOrderPod(orderId: 42, amountCents: 99, code: 3'u32), nowait = true) == mqSuccess
    var outVal: RpcOrderPod
    check rx.tryReceive(outVal) == mqSuccess
    check outVal.orderId == 42 and outVal.amountCents == 99

    # Mismatched byte size fails loudly with ValueError
    let rawTx = tx.handle
    check rawTx.send("wrong_size", nowait = true) == mqSuccess
    expect(ValueError):
      discard rx.receive(nowait = true)

    tx.close()
    let detachedRes = rx.receive(nowait = true)
    check detachedRes.status == mqDetached
    rx.close()
