CREATE TYPE "ArchStatus" AS ENUM ('pending', 'active');

CREATE OR REPLACE FUNCTION v30_ping() returns Text as
'arch_v30_suite', 'pgx_v30_ping_d01fea_void'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_pair_sum(int4, int4) returns int4 as
'arch_v30_suite', 'pgx_v30_pair_sum_da83c2_int4_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;
