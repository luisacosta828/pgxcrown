import pgxcrown
import std/strutils

type
  ex05_iban* {.pgxType: string.} = distinct string

proc isValidIbanMod97(iban: string): bool {.noSideEffect.} =
  if iban.len < 15 or iban.len > 34:
    return false
  if iban[0] notin {'A'..'Z'} or iban[1] notin {'A'..'Z'}:
    return false
  if iban[2] notin {'0'..'9'} or iban[3] notin {'0'..'9'}:
    return false
  for i in 4 ..< iban.len:
    if iban[i] notin {'A'..'Z', '0'..'9'}:
      return false

  let rearranged = iban[4 .. ^1] & iban[0 .. 3]
  var rem = 0
  for ch in rearranged:
    if ch in {'0'..'9'}:
      rem = (rem * 10 + (ord(ch) - ord('0'))) mod 97
    else:
      let val = ord(ch) - ord('A') + 10
      rem = (rem * 100 + val) mod 97
  rem == 1

proc parse_ex05_iban*(s: cstring): ex05_iban {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().replace(" ", "").toUpperAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "ex05_iban cannot be empty")
  if not isValidIbanMod97(cleaned):
    raise newException(ValueError, "invalid ex05_iban format or mod-97 checksum")
  ex05_iban(cleaned)

proc format_ex05_iban*(val: ex05_iban): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc ex05_iban_country*(val: ex05_iban): string {.immutable, parallelSafe.} =
  string(val)[0 .. 1]

proc ex05_iban_masked*(val: ex05_iban): string {.immutable, parallelSafe.} =
  let s = string(val)
  s[0 .. 3] & "****" & s[^4 .. ^1]

proc ex05_iban_lt*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) < string(b)

proc ex05_iban_le*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) <= string(b)

proc ex05_iban_eq*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) == string(b)

proc ex05_iban_ne*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) != string(b)

proc ex05_iban_ge*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) >= string(b)

proc ex05_iban_gt*(a, b: ex05_iban): bool {.immutable, parallelSafe.} =
  string(a) > string(b)

proc ex05_iban_cmp*(a, b: ex05_iban): int32 {.immutable, parallelSafe.} =
  int32(cmp(string(a), string(b)))

pgxSql("ex05_iban_btree_and_ledger", """
CREATE OPERATOR < (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_lt,
  COMMUTATOR = >,
  NEGATOR = >=,
  RESTRICT = scalarltsel,
  JOIN = scalarltjoinsel
);

CREATE OPERATOR <= (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_le,
  COMMUTATOR = >=,
  NEGATOR = >,
  RESTRICT = scalarlesel,
  JOIN = scalarlejoinsel
);

CREATE OPERATOR = (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_eq,
  COMMUTATOR = =,
  NEGATOR = <>,
  RESTRICT = eqsel,
  JOIN = eqjoinsel,
  HASHES,
  MERGES
);

CREATE OPERATOR <> (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_ne,
  COMMUTATOR = <>,
  NEGATOR = =,
  RESTRICT = neqsel,
  JOIN = neqjoinsel
);

CREATE OPERATOR >= (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_ge,
  COMMUTATOR = <=,
  NEGATOR = <,
  RESTRICT = scalargesel,
  JOIN = scalargejoinsel
);

CREATE OPERATOR > (
  LEFTARG = ex05_iban,
  RIGHTARG = ex05_iban,
  FUNCTION = ex05_iban_gt,
  COMMUTATOR = <,
  NEGATOR = <=,
  RESTRICT = scalargtsel,
  JOIN = scalargtjoinsel
);

CREATE OPERATOR CLASS ex05_iban_ops
  DEFAULT FOR TYPE ex05_iban USING btree AS
    OPERATOR 1 <,
    OPERATOR 2 <=,
    OPERATOR 3 =,
    OPERATOR 4 >=,
    OPERATOR 5 >,
    FUNCTION 1 ex05_iban_cmp(ex05_iban, ex05_iban);

CREATE TABLE IF NOT EXISTS ex05_ledger (
  id int4 PRIMARY KEY,
  iban ex05_iban NOT NULL,
  holder text NOT NULL,
  balance_cents int8 NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ex05_ledger_iban
  ON ex05_ledger USING btree (iban);
""", phase = "post")
