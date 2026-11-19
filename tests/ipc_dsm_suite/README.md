# ipc_dsm_suite

End-to-end regression suite verifying Pgxcrown dynamic IPC without `shared_preload_libraries`:

- Dynamic Shared Memory (`dsmCreate`, `dsmAttachOrFind`, `dsmDetach`, `ensureResourceOwner`)
- `shm_toc` typed struct + bidirectional `shm_mq` RPC layout (`estimateRpcQueues`, `createRpcQueues`, `lookupRpcQueues`)
- Dynamic `LWLock` tranche (`newTrancheId`, `registerTrancheCopy`, `initLock`, `withLock`)
- Single-Producer Single-Consumer `shm_mq` queues across PG 14–17
- `WaitEventSet` multiplexing `MyLatch` + non-blocking POSIX `socketpair` (`setSocketNonBlocking`, `withWaitEventSet`)
- Dynamic shmem-only background worker lifecycle (`registerDynamicWorker`, `waitForStartup`, `terminate`, `waitForShutdown`)
