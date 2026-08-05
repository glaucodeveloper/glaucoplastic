#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${ROOT_DIR}/.devdata}"

mkdir -p "${XDG_DATA_HOME}"

cd "${ROOT_DIR}"

nim c --nimcache:"${ROOT_DIR}/.nimcache" --path:"${REPO_DIR}/src" src/consumer.nim

exec "${ROOT_DIR}/src/consumer" "$@"
