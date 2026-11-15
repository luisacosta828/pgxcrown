#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUPPORTED_VERSIONS=(14 15 16 17)
PGXCROWN_SOURCE="${PGXCROWN_SOURCE:-local}"
NIM_VERSION="${NIM_VERSION:-2.4.0}"
IMAGE_NAME="${IMAGE_NAME:-pgxcrown}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [14|15|16|17|all]

Environment variables:
  IMAGE_NAME       Docker image repository name (default: pgxcrown)
  PGXCROWN_SOURCE  'local' to install from repo source, 'nimble' for remote Nimble (default: local)
  NIM_VERSION      Nim toolchain image tag from nimlang/nim (default: 2.4.0)
EOF
}

build_version() {
  local pg_ver="$1"
  echo "==> Building ${IMAGE_NAME}:${pg_ver} (PostgreSQL ${pg_ver}, Nim ${NIM_VERSION}, source=${PGXCROWN_SOURCE})"
  docker build \
    --file "${SCRIPT_DIR}/Dockerfile" \
    --build-arg "PG_TAG=${pg_ver}" \
    --build-arg "NIM_VERSION=${NIM_VERSION}" \
    --build-arg "PGXCROWN_SOURCE=${PGXCROWN_SOURCE}" \
    --tag "${IMAGE_NAME}:${pg_ver}" \
    "${REPO_ROOT}"

  if [ "${pg_ver}" = "17" ]; then
    docker tag "${IMAGE_NAME}:17" "${IMAGE_NAME}:latest"
  fi
}

if [ "$#" -eq 0 ] || [ "$1" = "all" ]; then
  for ver in "${SUPPORTED_VERSIONS[@]}"; do
    build_version "${ver}"
  done
elif [[ " ${SUPPORTED_VERSIONS[*]} " == *" $1 "* ]]; then
  build_version "$1"
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
else
  echo "Unsupported PostgreSQL version: $1" >&2
  usage
  exit 1
fi
