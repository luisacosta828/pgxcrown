SHOW shared_preload_libraries;
SELECT shmem_banner() AS banner;
SELECT shmem_bump_hits(10) AS hit1;
SELECT shmem_bump_hits(5) AS hit2;
SELECT shmem_await_ticks(2, 5000) AS worker_ticked;
SELECT name, allocated_size >= size AS valid_shmem_size FROM pg_shmem_allocations WHERE name = 'pgxcrown_preload_state';
SELECT shmem_worker_ticks() >= 2 AS static_worker_running;
SELECT COUNT(*) AS zero_fake_sql_types FROM pg_type WHERE typname = 'PreloadBenchState';
