#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_FILE="${GLAUCOPLASTIC_UI_TRACE_FILE:-/tmp/glaucoplastic-ui-trace.log}"
CONSOLE_FILE="${GLAUCOPLASTIC_UI_CONSOLE_LOG:-/tmp/glaucoplastic-dev-console.log}"

: > "${TRACE_FILE}"
: > "${CONSOLE_FILE}"

export GLAUCOPLASTIC_UI_DEBUG=1
export GLAUCOPLASTIC_UI_TRACE_FILE="${TRACE_FILE}"

cd "${ROOT_DIR}"

echo "[watch] trace=${TRACE_FILE}"
echo "[watch] console=${CONSOLE_FILE}"

bash scripts/dev.sh "$@" 2>&1 | tee "${CONSOLE_FILE}" &
dev_pid=$!

tail -n 0 -f "${TRACE_FILE}" &
tail_pid=$!

cleanup() {
  kill "${tail_pid}" "${dev_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait "${dev_pid}"
dev_status=$?

kill "${tail_pid}" 2>/dev/null || true
wait "${tail_pid}" 2>/dev/null || true

exit "${dev_status}"
