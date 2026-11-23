#!/usr/bin/env bash
set -euo pipefail

# Verify negative security guards block unsafe C FFI imports, ExecIOEffect calls,
# OS/syscall/spawn bypasses, default-deny dynamic/PostgreSQL loaders, any ELF RPATH/RUNPATH,
# and unapproved DT_NEEDED dependencies, while allowing opt-in dynamic loading via pgxext.json.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PGXTOOL_BIN="${PGXTOOL_BIN:-pgxtool}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export PGXTOOL_HOME="$TMP_HOME"
"$PGXTOOL_BIN" init >/dev/null

assert_no_binary_artifacts() {
  local case_name="$1"
  local src_dir="$TMP_HOME/$case_name/src"
  if [ -f "$src_dir/${case_name}.so" ] || [ -f "$src_dir/${case_name}" ] || [ -f "$src_dir/lib${case_name}.so" ]; then
    echo "❌ Shared library artifact was left behind after $case_name violation!"
    exit 1
  fi
}

assert_blocked_case() {
  local case_name="$1"
  local pattern="$2"
  local desc="$3"
  local extra_pattern="${4:-}"
  local skip_copy="${5:-0}"

  if [ "$skip_copy" != "1" ]; then
    cp -r "$SCRIPT_DIR/$case_name" "$TMP_HOME/$case_name"
  fi

  set +e
  local out
  out="$("$PGXTOOL_BIN" build-extension "$case_name" 2>&1)"
  local code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "❌ Expected $case_name build to fail security audit, but it exited 0!"
    echo "$out"
    exit 1
  fi
  if ! printf '%s' "$out" | grep -qE "$pattern"; then
    echo "❌ Expected output matching '$pattern' for $case_name, got:"
    echo "$out"
    exit 1
  fi
  if [ -n "$extra_pattern" ] && ! printf '%s' "$out" | grep -qE "$extra_pattern"; then
    echo "❌ Expected output matching '$extra_pattern' for $case_name, got:"
    echo "$out"
    exit 1
  fi
  assert_no_binary_artifacts "$case_name"
  echo "✅ [PASS] $desc"
}

assert_blocked_case "blocked_system_call" "SECURITY VIOLATION" \
  "Binary Symbol Auditor blocked unsafe C FFI import ('system') and removed artifacts."
assert_blocked_case "blocked_execeffect" "ExecIOEffect|SECURITY VIOLATION" \
  "Static I/O Effect Guard blocked ExecIOEffect ('execCmd')."
assert_blocked_case "blocked_syscall" "SECURITY VIOLATION" \
  "Binary Symbol Auditor v2 blocked raw 'syscall' FFI bypass and removed artifacts." "syscall"
assert_blocked_case "blocked_posix_spawn" "SECURITY VIOLATION" \
  "Binary Symbol Auditor v2 blocked 'posix_spawn' process spawning and removed artifacts." "posix_spawn"
assert_blocked_case "blocked_dlopen_default" "SECURITY VIOLATION" \
  "Binary Symbol Auditor v2 blocked dynamic loader symbols by default with pgxext.json opt-in guidance." "allowDynamicLoader.*pgxext\.json|pgxext\.json"
assert_blocked_case "blocked_pg_load_file" "SECURITY VIOLATION" \
  "Binary Symbol Auditor v2 blocked PostgreSQL load_file loader by default and removed artifacts." "load_file"

# Verify any ELF RPATH/RUNPATH (even pkglibdir) is rejected unconditionally
mkdir -p "$TMP_HOME/blocked_rpath_pkglibdir/src"
cat > "$TMP_HOME/blocked_rpath_pkglibdir/src/main.nim" <<'EOF'
{.passL: "-Wl,-rpath,/usr/lib/postgresql/18/lib".}
import pgxcrown

proc rpath_probe*(x: int32): int32 =
  return x + 1'i32
EOF
assert_blocked_case "blocked_rpath_pkglibdir" "SECURITY VIOLATION" \
  "ELF RPATH/RUNPATH Auditor rejected pkglibdir RPATH ('/usr/lib/postgresql/18/lib') and removed artifacts." \
  "/usr/lib/postgresql/18/lib" "1"

# Verify unapproved DT_NEEDED shared library dependency is rejected
if [ "$(uname -s)" = "Linux" ] && command -v gcc >/dev/null 2>&1; then
  mkdir -p "$TMP_HOME/unapproved_lib" "$TMP_HOME/blocked_dt_needed/src"
  cat > "$TMP_HOME/unapproved_lib/dep.c" <<'EOF'
int unapproved_dep_fn(int x) { return x + 42; }
EOF
  gcc -shared -fPIC -Wl,-soname,libunapproved_dep.so -o "$TMP_HOME/unapproved_lib/libunapproved_dep.so" "$TMP_HOME/unapproved_lib/dep.c"
  cat > "$TMP_HOME/blocked_dt_needed/src/main.nim" <<EOF
{.passL: "-Wl,--no-as-needed $TMP_HOME/unapproved_lib/libunapproved_dep.so".}
import pgxcrown

proc c_unapproved_dep(x: cint): cint {.importc: "unapproved_dep_fn".}

proc dt_needed_probe*(x: int32): int32 =
  return c_unapproved_dep(x.cint).int32
EOF
  assert_blocked_case "blocked_dt_needed" "SECURITY VIOLATION" \
    "ELF DT_NEEDED Auditor rejected unapproved shared library ('libunapproved_dep.so') and removed artifacts." \
    "libunapproved_dep\.so" "1"
fi

cp -r "$SCRIPT_DIR/allowed_dlopen_optin" "$TMP_HOME/allowed_dlopen_optin"
set +e
OUT_OPTIN="$("$PGXTOOL_BIN" build-extension allowed_dlopen_optin 2>&1)"
CODE_OPTIN=$?
set -e

if [ "$CODE_OPTIN" -ne 0 ]; then
  echo "❌ Expected allowed_dlopen_optin build to succeed with allowDynamicLoader=true, exited $CODE_OPTIN:"
  echo "$OUT_OPTIN"
  exit 1
fi
if ! printf '%s' "$OUT_OPTIN" | grep -q "SECURITY AUDIT PASSED"; then
  echo "❌ Expected SECURITY AUDIT PASSED in allowed_dlopen_optin output, got:"
  echo "$OUT_OPTIN"
  exit 1
fi
if [ ! -f "$TMP_HOME/allowed_dlopen_optin/src/allowed_dlopen_optin.so" ] && [ ! -f "$TMP_HOME/allowed_dlopen_optin/src/allowed_dlopen_optin" ]; then
  echo "❌ Expected compiled shared library artifact for allowed_dlopen_optin!"
  exit 1
fi
echo "✅ [PASS] Dynamic loader opt-in ('allowDynamicLoader': true in pgxext.json) succeeded cleanly."

# Verify malformed non-boolean allowDynamicLoader in pgxext.json is rejected strictly
cp -r "$SCRIPT_DIR/allowed_dlopen_optin" "$TMP_HOME/invalid_adl_type"
cat > "$TMP_HOME/invalid_adl_type/pgxext.json" <<'EOF'
{
  "version": "0.1.0",
  "allowDynamicLoader": "true"
}
EOF
set +e
OUT_BAD_CFG="$("$PGXTOOL_BIN" build-extension invalid_adl_type 2>&1)"
CODE_BAD_CFG=$?
set -e
if [ "$CODE_BAD_CFG" -eq 0 ]; then
  echo "❌ Expected invalid non-bool allowDynamicLoader to fail, but build exited 0!"
  exit 1
fi
assert_no_binary_artifacts "invalid_adl_type"
echo "✅ [PASS] Non-boolean 'allowDynamicLoader' in pgxext.json rejected cleanly."
