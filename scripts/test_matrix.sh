#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PGXCROWN_IMAGE="${PGXCROWN_IMAGE:-pgxcrown}"
PGXTOOL_BIN="${PGXTOOL_BIN:-pgxtool}"
PG_LIST="14,15,16,17,18"
UNIT_ONLY=0
E2E_ONLY=0
SKIP_SMOKE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Unified multi-version test matrix runner for pgxcrown across PostgreSQL 14-18.

Options:
  --pg <versions>   Comma-separated PG versions (default: 14,15,16,17,18)
  --unit-only       Run only in-container unit tests, security blocks, and hook builds
  --e2e-only        Run only auto-discovered E2E SQL suites (no --bless)
  --skip-smoke      Skip CLI scaffolding smoke tests
  -h, --help        Show this help message

Environment overrides:
  PGXCROWN_IMAGE    Docker image repo to test against (default: pgxcrown)
  PGXTOOL_BIN       Path or command name for pgxtool binary (default: pgxtool)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pg)
      if [ "$#" -lt 2 ]; then
        echo "❌ Missing argument after --pg" >&2
        exit 1
      fi
      PG_LIST="$2"
      shift 2
      ;;
    --pg=*)
      PG_LIST="${1#--pg=}"
      shift
      ;;
    --unit-only)
      UNIT_ONLY=1
      shift
      ;;
    --e2e-only)
      E2E_ONLY=1
      shift
      ;;
    --skip-smoke)
      SKIP_SMOKE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${UNIT_ONLY}" -eq 1 ] && [ "${E2E_ONLY}" -eq 1 ]; then
  echo "❌ --unit-only and --e2e-only cannot be used together." >&2
  exit 1
fi

if [[ "${PGXTOOL_BIN}" == */* ]]; then
  PGXTOOL_BIN="$(cd "$(dirname "${PGXTOOL_BIN}")" && pwd)/$(basename "${PGXTOOL_BIN}")"
  if [ ! -x "${PGXTOOL_BIN}" ]; then
    echo "❌ PGXTOOL_BIN is not executable: ${PGXTOOL_BIN}" >&2
    exit 1
  fi
else
  if ! command -v "${PGXTOOL_BIN}" >/dev/null 2>&1; then
    echo "❌ pgxtool binary not found in PATH: ${PGXTOOL_BIN}" >&2
    exit 1
  fi
fi

IFS=',' read -r -a RAW_PG_VERSIONS <<< "${PG_LIST}"
PG_VERSIONS=()
for raw_ver in "${RAW_PG_VERSIONS[@]}"; do
  ver="${raw_ver//[[:space:]]/}"
  [ -z "${ver}" ] && continue
  if [ "${ver}" = "latest" ]; then
    ver="18"
  fi
  case "${ver}" in
    14|15|16|17|18)
      PG_VERSIONS+=("${ver}")
      ;;
    *)
      echo "❌ Unsupported PostgreSQL version in --pg: '${ver}' (expected 14,15,16,17,18)" >&2
      exit 1
      ;;
  esac
done

if [ "${#PG_VERSIONS[@]}" -eq 0 ]; then
  echo "❌ No PostgreSQL versions selected." >&2
  exit 1
fi

export PGXCROWN_IMAGE
cd "${REPO_ROOT}"

discover_e2e_suites() {
  (
    shopt -s nullglob
    local suites=()
    local d
    for d in "${REPO_ROOT}"/tests/*/; do
      if [ -d "${d}tests/sql" ]; then
        suites+=("$(basename "${d%/}")")
      fi
    done
    if [ "${#suites[@]}" -gt 0 ]; then
      printf '%s\n' "${suites[@]}" | LC_ALL=C sort
    fi
  )
}

run_container_unit_phase() {
  local ver="$1"
  local image_tag="${PGXCROWN_IMAGE}:${ver}"
  echo ""
  echo "======================================================================"
  echo "==> [PG ${ver}] Container Unit Tests, Security Blocks, Hooks & LSP Check (${image_tag})"
  echo "======================================================================"

  docker run --rm -v "${REPO_ROOT}:/repo:ro" "${image_tag}" bash -lc '
    set -euo pipefail
    EXPECTED_VER="$(sed -n -E "s/^version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" /repo/pgxcrown.nimble | head -n1)"
    [ "$(pgxtool --version)" = "pgxtool v${EXPECTED_VER}" ]

    mkdir -p /tmp/repo_check
    cp /repo/pgxcrown.nimble /tmp/repo_check/pgxcrown.nimble
    cp -r /repo/src /tmp/repo_check/src
    cp -r /repo/tests /tmp/repo_check/tests
    cd /tmp/repo_check

    shopt -s nullglob
    mapfile -t unit_tests < <(printf "%s\n" tests/test_*.nim | LC_ALL=C sort)
    if [ "${#unit_tests[@]}" -eq 0 ]; then
      echo "❌ No unit test files found matching tests/test_*.nim"
      exit 1
    fi

    for t in "${unit_tests[@]}"; do
      echo "==> Running unit suite (debug): $t"
      nim c -r --hints:off --path:src "$t"
      echo "==> Running unit suite (release+ARC): $t"
      nim c -r -d:release --mm:arc --hints:off --path:src "$t"
    done

    chmod +x tests/negative/verify_security_blocks.sh
    ./tests/negative/verify_security_blocks.sh

    TMP_HOOK_HOME="$(mktemp -d)"
    export PGXTOOL_HOME="$TMP_HOOK_HOME"
    pgxtool init >/dev/null
    pgxtool create-hook emit_log
    pgxtool build-extension emit_log
    pgxtool create-hook post_parse_analyze
    pgxtool build-extension post_parse_analyze
    rm -rf "$TMP_HOOK_HOME"

    TMP_LSP_HOME="$(mktemp -d)"
    export PGXTOOL_HOME="$TMP_LSP_HOME"
    pgxtool init >/dev/null
    pgxtool create-project lsp_smoke
    (cd "$TMP_LSP_HOME/lsp_smoke" && nim check src/main.nim)
    rm -rf "$TMP_LSP_HOME"
  '
}

run_e2e_phase() {
  local ver="$1"
  local suites=()
  mapfile -t suites < <(discover_e2e_suites)
  if [ "${#suites[@]}" -eq 0 ]; then
    echo "❌ No E2E test suites found under tests/*/tests/sql" >&2
    exit 1
  fi

  echo ""
  echo "======================================================================"
  echo "==> [PG ${ver}] Running ${#suites[@]} Auto-Discovered E2E Suites (${PGXCROWN_IMAGE}:${ver})"
  echo "======================================================================"

  for suite in "${suites[@]}"; do
    echo "==> Running E2E suite: tests/${suite} (PG ${ver})"
    "${PGXTOOL_BIN}" test "tests/${suite}" --pg "${ver}"
  done
}

run_smoke_phase() {
  local ver="$1"
  echo ""
  echo "======================================================================"
  echo "==> [PG ${ver}] Running CLI Scaffolding & LSP Smoke Tests"
  echo "======================================================================"

  (
    TMP_HOME="$(mktemp -d)"
    trap 'rm -rf "$TMP_HOME"' EXIT
    export PGXTOOL_HOME="$TMP_HOME"
    cd "$TMP_HOME"

    "${PGXTOOL_BIN}" init
    "${PGXTOOL_BIN}" available-hooks
    "${PGXTOOL_BIN}" create-project sample_ext
    "${PGXTOOL_BIN}" create-type factorial --base-type int
    "${PGXTOOL_BIN}" create-type geo_coord --base-type float64
    "${PGXTOOL_BIN}" create-type nickname --base-type string
    "${PGXTOOL_BIN}" create-type is_active --base-type bool
    "${PGXTOOL_BIN}" create-type grade_code --base-type char
    "${PGXTOOL_BIN}" create-type big_counter --base-type uint64
    "${PGXTOOL_BIN}" create-worker order_archiver
    "${PGXTOOL_BIN}" create-hook emit_log
    "${PGXTOOL_BIN}" create-hook post_parse_analyze

    [ -f "$TMP_HOME/sample_ext/nim.cfg" ]
    "${PGXTOOL_BIN}" sync-lsp sample_ext --pg "${ver}"

    for prj in sample_ext factorial geo_coord nickname is_active grade_code big_counter order_archiver emit_log post_parse_analyze; do
      "${PGXTOOL_BIN}" test "$prj" --pg "${ver}" --bless
    done
  )
}

for ver in "${PG_VERSIONS[@]}"; do
  if [ "${E2E_ONLY}" -eq 0 ]; then
    run_container_unit_phase "${ver}"
  fi
  if [ "${UNIT_ONLY}" -eq 0 ]; then
    run_e2e_phase "${ver}"
    if [ "${SKIP_SMOKE}" -eq 0 ]; then
      run_smoke_phase "${ver}"
    fi
  fi
done

echo ""
echo "======================================================================"
echo "✅ ALL MATRIX CHECKS PASSED (PG versions: ${PG_VERSIONS[*]}, image: ${PGXCROWN_IMAGE})"
echo "======================================================================"
