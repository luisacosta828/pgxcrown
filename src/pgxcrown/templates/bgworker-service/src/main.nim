import pgxcrown
import std/options

proc {{project_snake}}_worker*() {.pgxWorker.} =
  workerInit("postgres")
  runWorkerLoop(intervalMs = {{interval_ms}}):
    workerActivity("{{project_name}} background cycle"):
      workerTransaction:
        discard

proc start_{{project_snake}}_worker*(): int32 {.volatile.} =
  let cfg = bgWorker("{{project_name}}"):
    library "{{project_name}}"
    entrypoint "{{project_snake}}_worker"
    database "postgres"
    restart 30
  let handle = registerDynamicWorker(cfg)
  if handle.isSome:
    let (status, pid) = handle.get.waitForStartup()
    if status == bgwStarted:
      trackWorkerStarted("{{project_name}}", pid)
      return pid.int32
  return -1'i32

proc stop_{{project_snake}}_worker*(): bool {.volatile.} =
  stopWorkerByName("{{project_name}}")

proc {{project_snake}}_worker_status*(): string {.volatile.} =
  getWorkerStatusByName("{{project_name}}")
