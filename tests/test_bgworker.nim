{.passC: "-I/usr/include/postgresql/14/server -I/usr/include/postgresql".}
import std/[unittest, strutils]

{.emit: """
#include "postgres.h"
#include "postmaster/bgworker.h"
#include "storage/latch.h"
#include "storage/ipc.h"
#include "utils/guc.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static struct Latch mockLatch;
struct Latch *MyLatch = &mockLatch;
int MyProcPid = 4242;
BackgroundWorker *MyBgworkerEntry = NULL;
#undef vsnprintf

#undef snprintf
#undef sprintf
#undef vsprintf
#undef strerror

int pg_sprintf(char *str, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsprintf(str, fmt, args);
    va_end(args);
    return ret;
}

char *pg_strerror(int errnum) {
    return strerror(errnum);
}

int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsnprintf(str, count, fmt, args);
    va_end(args);
    return ret;
}


void SetLatch(struct Latch *latch) {}
void ResetLatch(struct Latch *latch) {}
pqsigfunc pqsignal(int signo, pqsigfunc func) { return NULL; }
int WaitLatch(struct Latch *latch, int wakeEvents, long timeout, uint32 wait_event_info) { return 0; }
void RegisterBackgroundWorker(BackgroundWorker *worker) {}
bool RegisterDynamicBackgroundWorker(BackgroundWorker *worker, BackgroundWorkerHandle **handle) {
    static int dummy = 1;
    if (handle) *handle = (BackgroundWorkerHandle*) &dummy;
    return true;
}
BgwHandleStatus GetBackgroundWorkerPid(BackgroundWorkerHandle *handle, pid_t *pidp) {
    if (pidp) *pidp = 4242;
    return BGWH_STARTED;
}
BgwHandleStatus WaitForBackgroundWorkerStartup(BackgroundWorkerHandle *handle, pid_t *pid) {
    if (pid) *pid = 4242;
    return BGWH_STARTED;
}
BgwHandleStatus WaitForBackgroundWorkerShutdown(BackgroundWorkerHandle *handle) {
    return BGWH_STOPPED;
}
const char *GetBackgroundWorkerTypeByPid(pid_t pid) {
    return "TestWorker";
}
void TerminateBackgroundWorker(BackgroundWorkerHandle *handle) {}
void BackgroundWorkerInitializeConnection(const char *dbname, const char *username, uint32 flags) {}
void BackgroundWorkerBlockSignals(void) {}
void BackgroundWorkerUnblockSignals(void) {}
void StartTransactionCommand(void) {}
void CommitTransactionCommand(void) {}
void AbortCurrentTransaction(void) {}
void SetCurrentStatementStartTimestamp(void) {}
void ProcessConfigFile(GucContext context) {}
void PushActiveSnapshot(void *snapshot) {}
void *GetTransactionSnapshot(void) { return NULL; }

void PopActiveSnapshot(void) {}
bool ActiveSnapshotSet(void) { return false; }
void proc_exit(int code) {}

void pgstat_report_activity(int state, const char *cmd_str) {}
void BeginInternalSubTransaction(const char *name) {}
void ReleaseCurrentSubTransaction(void) {}
void RollbackAndReleaseCurrentSubTransaction(void) {}
bool IsSubTransaction(void) { return false; }

int SPI_connect(void) { return 0; }
int SPI_finish(void) { return 0; }
int SPI_exec(const char *cmd, long count) { return 0; }
uint64 SPI_processed = 0;
void *SPI_tuptable = NULL;

sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

bool errstart(int elevel, const char *domain) { return false; }
void errfinish(const char *filename, int lineno, const char *funcname) {}
int errcode(int sqlerrcode) { return 0; }
int errmsg(const char *fmt, ...) { return 0; }
int errdetail(const char *fmt, ...) { return 0; }
int errhint(const char *fmt, ...) { return 0; }
ErrorData *CopyErrorData(void) { return NULL; }
void FlushErrorState(void) {}
void FreeErrorData(ErrorData *edata) {}
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
""".}

import ../src/pgxcrown/bgworker
import ../src/pgxcrown/pgxtool

suite "Pgxcrown - PostgreSQL Background Worker (BGWorker) Suite":

  test "bgWorker DSL initialization and automatic flag inference":
    # Scenario A: DB worker (database provided)
    let dbWorker = bgWorker("MetricsCollector"):
      entrypoint "metrics_worker_main"
      database "postgres"
      restart 15

    check $dbWorker.name == "MetricsCollector"
    check $dbWorker.functionName == "metrics_worker_main"
    check $dbWorker.dbName == "postgres"
    check $dbWorker.workerType == "MetricsCollector"
    check (dbWorker.flags and BGWORKER_SHMEM_ACCESS) != 0
    check (dbWorker.flags and BGWORKER_BACKEND_DATABASE_CONNECTION) != 0
    check dbWorker.restartIntervalSec == 15
    check dbWorker.startTime == bwRecoveryFinished

    # Scenario B: Shared-memory-only worker (no DB connection required)
    let shmemWorker = bgWorker("IPCNotifier"):
      entrypoint "ipc_worker_main"

    check (shmemWorker.flags and BGWORKER_SHMEM_ACCESS) != 0
    check (shmemWorker.flags and BGWORKER_BACKEND_DATABASE_CONNECTION) == 0
    check shmemWorker.restartIntervalSec == BGW_NEVER_RESTART

  test "Custom directives: workerType, restart, mainArg, extra":
    let customWorker = bgWorker("CustomSyncWorker"):
      entrypoint "custom_sync"
      workerType "SyncDaemon"
      restart 30
      mainArg 42
      extra "cluster_id=42"

    check $customWorker.workerType == "SyncDaemon"
    check customWorker.restartIntervalSec == 30
    check $customWorker.extra == "cluster_id=42"
    check customWorker.mainArg.int == 42

  test "Conversion to raw PostgreSQL BackgroundWorker C struct":
    let cfg = bgWorker("TaskRunner"):
      entrypoint "task_worker_entry"
      library "task_ext"
      database "production"
      restart 10

    var raw = cfg.toRawWorker()
    check raw.bgw_flags == (BGWORKER_SHMEM_ACCESS or BGWORKER_BACKEND_DATABASE_CONNECTION)
    check raw.bgw_restart_time == 10
    check raw.bgw_start_time == bwRecoveryFinished

    # Check string representation inside the fixed-size C char arrays
    var nameStr = ""
    for ch in raw.bgw_name:
      if ch == '\0': break
      nameStr.add ch
    check nameStr == "TaskRunner"

    var typeStr = ""
    for ch in raw.bgw_type:
      if ch == '\0': break
      typeStr.add ch
    check typeStr == "TaskRunner"

  test "Handle status enums":
    check bgwStarted.int == 0
    check bgwNotYetStarted.int == 1
    check bgwStopped.int == 2
    check bgwPostmasterDied.int == 3

    var nilHandle = WorkerHandle(raw: nil)
    let (stat, pid) = nilHandle.waitForStartup()
    check stat == bgwStopped
    check pid == -1
    check nilHandle.waitForShutdown() == bgwStopped

  test "Worker activity reporting & idle helpers":
    var executed = false
    workerActivity("Archiving test batch"):
      executed = true
    check executed

  test "Subtransaction and worker savepoint isolation semantics":
    # Successful subtransaction
    var step1Done = false
    subTransaction:
      step1Done = true
    check step1Done

    # Savepoint error isolation: outer execution continues despite failure
    var itemsProcessed = 0
    var errorLogged = ""
    for i in 1 .. 3:
      workerSavepoint:
        if i == 2:
          raise newException(ValueError, "Simulated batch failure on item 2")
        itemsProcessed.inc
      do:
        errorLogged = err.msg

    check itemsProcessed == 2
    check "Simulated batch failure on item 2" in errorLogged

  test "pgxtool generateWorkerSource scaffolding verification":
    let (srcCode, testSql) = generateWorkerSource("telemetry")
    check "proc telemetry_worker*() {.pgxWorker.}" in srcCode
    check "workerInit(\"postgres\")" in srcCode
    check "runWorkerLoop(intervalMs = 5000):" in srcCode
    check "workerActivity(\"Processing worker cycle\"):" in srcCode
    check "workerTransaction:" in srcCode
    check "let cfg = bgWorker(\"telemetry\"):" in srcCode
    check "registerDynamicWorker(cfg)" in srcCode
    check "trackWorkerStarted(\"telemetry\", pid)" in srcCode
    check "proc stop_telemetry_worker*(): bool" in srcCode
    check "proc telemetry_worker_status*(): string" in srcCode
    check "SELECT start_telemetry_worker() > 0 AS worker_started;" in testSql
    check "SELECT telemetry_worker_status();" in testSql
    check "SELECT stop_telemetry_worker();" in testSql

  test "Worker introspection & graceful shutdown verification":
    # Default without entry should be empty string
    check getWorkerName() == ""
    check getWorkerType() == ""

    # Simulated worker entry
    var mockWorker: BackgroundWorker
    for i, ch in "archiver_daemon":
      mockWorker.bgw_name[i] = ch
    for i, ch in "Archiver":
      mockWorker.bgw_type[i] = ch

    MyBgworkerEntry = addr mockWorker
    check getWorkerName() == "archiver_daemon"
    check getWorkerType() == "Archiver"
    MyBgworkerEntry = nil
