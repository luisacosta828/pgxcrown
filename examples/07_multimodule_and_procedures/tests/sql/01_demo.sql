\set VERBOSITY terse

-- 1. Extension metadata: pgxExtension overrides pgxext.json (trusted = t)
SELECT extname, extversion, extrelocatable
FROM pg_extension
WHERE extname = '07_multimodule_and_procedures';

SELECT version, relocatable, trusted, comment
FROM pg_available_extension_versions
WHERE name = '07_multimodule_and_procedures'
ORDER BY version;

-- 2. Chained {.pgxInit.} across billing_ops.nim -> main.nim and {.noSql.} isolation
SELECT ex07_init_status() AS chained_init_bias;

SELECT count(*) AS leaked_nosql_procs
FROM pg_proc
WHERE proname IN ('computecentsinternal', 'computeCentsInternal', 'initbillingops', 'initmainmodule');

-- 3. Pure LEAKPROOF & regular UDFs + SQL PROCEDURE inspection
SELECT proname, prokind, prosecdef, proleakproof, proconfig
FROM pg_proc
WHERE proname IN (
  'ex07_is_valid_amount',
  'ex07_post_charge',
  'ex07_reset_ledger',
  'ex07_vault_total',
  'ex07_caller_vault_total'
)
ORDER BY proname;

SELECT ex07_is_valid_amount(500) AS valid_pos,
       ex07_is_valid_amount(-10) AS valid_neg,
       ex07_calc_invoice(4, 250) AS invoice_cents;

-- 4. Invoking SQL PROCEDUREs with CALL
CALL ex07_reset_ledger();
CALL ex07_post_charge(1500);
CALL ex07_post_charge(250);
SELECT ex07_ledger_total() AS ledger_after_calls;

-- 5. SECURITY DEFINER vs SECURITY INVOKER isolation
CREATE TABLE public.ex07_billing_vault (id serial PRIMARY KEY, amount_cents bigint NOT NULL);
INSERT INTO public.ex07_billing_vault (amount_cents) VALUES (1200), (800);
REVOKE ALL ON public.ex07_billing_vault FROM PUBLIC;

CREATE ROLE ex07_auditor LOGIN NOSUPERUSER;
CREATE FUNCTION pg_temp.try_caller_vault() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v bigint;
BEGIN
  v := ex07_caller_vault_total();
  RETURN 'UNEXPECTED:' || v;
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

SET ROLE ex07_auditor;
SELECT ex07_vault_total() AS definer_vault_total;
SELECT pg_temp.try_caller_vault() AS invoker_vault_guard;
RESET ROLE;

DROP TABLE public.ex07_billing_vault;
DROP ROLE ex07_auditor;
