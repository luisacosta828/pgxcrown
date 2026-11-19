SELECT ipc_rpc_roundtrip('hello_ipc') AS rpc_one;
SELECT ipc_rpc_roundtrip('pgxcrown_dsm_mq') AS rpc_two;
SELECT COUNT(*) AS zero_fake_sql_types FROM pg_type WHERE typname = 'IpcSharedState';
