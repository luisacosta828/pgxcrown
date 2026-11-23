-- Ejemplo 05: Tipo SQL base propio ({.pgxType: string.}), operadores B-tree e indice en tabla real
\set VERBOSITY terse

-- 1. Parsing y normalizacion en {.pgxInput.} / {.pgxOutput.}
SELECT '  de89 3704 0044 0532 0130 00  '::ex05_iban AS normalized_iban,
       ex05_iban_country('es91 2100 0418 4502 0005 1332'::ex05_iban) AS country,
       ex05_iban_masked('es91 2100 0418 4502 0005 1332'::ex05_iban) AS masked;

-- 2. Validacion en parser -> SQLSTATE 22023 (invalid_parameter_value)
CREATE FUNCTION pg_temp.ex05_check_invalid_iban(raw text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM raw::ex05_iban;
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN OTHERS THEN
  RETURN 'CAUGHT:' || SQLSTATE;
END $$;

SELECT pg_temp.ex05_check_invalid_iban('   ') AS empty_rejected,
       pg_temp.ex05_check_invalid_iban('SHORT123') AS short_rejected,
       pg_temp.ex05_check_invalid_iban('DE00370400440532013000') AS bad_checksum_rejected;

-- 3. Operadores de comparacion y clase de operador B-tree por defecto
SELECT ('DE89370400440532013000'::ex05_iban = 'de89 3704 0044 0532 0130 00'::ex05_iban) AS eq_ok,
       ('DE89370400440532013000'::ex05_iban < 'ES9121000418450200051332'::ex05_iban) AS lt_ok,
       ('GB82WEST12345698765432'::ex05_iban > 'FR7630006000011234567890189'::ex05_iban) AS gt_ok;

SELECT opcname, opcdefault
FROM pg_opclass
WHERE opcname = 'ex05_iban_ops';

-- 4. Insercion y consultas WHERE / ORDER BY sobre tabla real ex05_ledger con indice B-tree
INSERT INTO ex05_ledger (id, iban, holder, balance_cents) VALUES
  (1, 'gb82 west 1234 5698 7654 32', 'London Treasury', 450000),
  (2, 'de89 3704 0044 0532 0130 00', 'Berlin Ops', 125000),
  (3, 'fr76 3000 6000 0112 3456 7890 189', 'Paris Escrow', 310000),
  (4, 'es91 2100 0418 4502 0005 1332', 'Madrid Retail', 280000);

SELECT id, iban, holder, balance_cents
FROM ex05_ledger
WHERE iban = 'es91 2100 0418 4502 0005 1332'::ex05_iban;

SELECT id, iban, ex05_iban_country(iban) AS country, holder
FROM ex05_ledger
WHERE iban >= 'ES9121000418450200051332'::ex05_iban
  AND iban <= 'FR7630006000011234567890189'::ex05_iban
ORDER BY iban ASC;

SELECT id, iban, holder
FROM ex05_ledger
ORDER BY iban DESC;

-- 5. Verificacion booleana determinista de que el optimizador usa idx_ex05_ledger_iban
CREATE FUNCTION pg_temp.ex05_uses_btree_index()
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  plan_line text;
  found_idx boolean := false;
BEGIN
  SET LOCAL enable_seqscan = off;
  FOR plan_line IN
    EXPLAIN (FORMAT TEXT)
    SELECT id FROM ex05_ledger WHERE iban = 'ES9121000418450200051332'::ex05_iban
  LOOP
    IF plan_line LIKE '%idx_ex05_ledger_iban%' THEN
      found_idx := true;
    END IF;
  END LOOP;
  RETURN found_idx;
END $$;

SELECT pg_temp.ex05_uses_btree_index() AS uses_btree_index;
