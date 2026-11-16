#!/usr/bin/env bash
set -euo pipefail

# Verify negative security guards block unsafe C FFI imports and ExecIOEffect calls.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export PGXTOOL_HOME="$TMP_HOME"
pgxtool init >/dev/null
cp -r "$SCRIPT_DIR/blocked_system_call" "$TMP_HOME/blocked_system_call"
cp -r "$SCRIPT_DIR/blocked_execeffect" "$TMP_HOME/blocked_execeffect"

set +e
OUT_FFI="$(pgxtool build-extension blocked_system_call 2>&1)"
CODE_FFI=$?
set -e

if [ "$CODE_FFI" -eq 0 ]; then
  echo "❌ Expected blocked_system_call build to fail security audit, but it exited 0!"
  exit 1
fi
if ! printf '%s' "$OUT_FFI" | grep -q "SECURITY VIOLATION"; then
  echo "❌ Expected SECURITY VIOLATION output for blocked_system_call, got:"
  echo "$OUT_FFI"
  exit 1
fi
if [ -f "$TMP_HOME/blocked_system_call/src/blocked_system_call.so" ] || [ -f "$TMP_HOME/blocked_system_call/src/blocked_system_call" ]; then
  echo "❌ Shared library artifact was left behind after blocked_system_call violation!"
  exit 1
fi
echo "✅ [PASS] Binary Symbol Auditor blocked unsafe C FFI import ('system') and removed artifacts."

set +e
OUT_EXEC="$(pgxtool build-extension blocked_execeffect 2>&1)"
CODE_EXEC=$?
set -e

if [ "$CODE_EXEC" -eq 0 ]; then
  echo "❌ Expected blocked_execeffect build to fail ExecIOEffect check, but it exited 0!"
  exit 1
fi
if ! printf '%s' "$OUT_EXEC" | grep -qE "ExecIOEffect|SECURITY VIOLATION"; then
  echo "❌ Expected ExecIOEffect/SECURITY VIOLATION error for blocked_execeffect, got:"
  echo "$OUT_EXEC"
  exit 1
fi
if [ -f "$TMP_HOME/blocked_execeffect/src/blocked_execeffect.so" ] || [ -f "$TMP_HOME/blocked_execeffect/src/blocked_execeffect" ]; then
  echo "❌ Shared library artifact was left behind after blocked_execeffect violation!"
  exit 1
fi
echo "✅ [PASS] Static I/O Effect Guard blocked ExecIOEffect ('execCmd')."
