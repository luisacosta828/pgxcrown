SELECT ipc_rpc_roundtrip('hello_ipc') AS rpc_one;
SELECT ipc_rpc_roundtrip('pgxcrown_dsm_mq') AS rpc_two;
SELECT ipc_typed_channel_roundtrip(6, 7, 'typed_mq') AS typed_rpc;
SELECT ipc_sugar_call(8, 9, 'hi') AS sugar_rpc;
SELECT COUNT(*) AS zero_fake_sql_types FROM pg_type WHERE typname IN ('IpcSharedState', 'IpcTypedReq', 'IpcTypedResp');
