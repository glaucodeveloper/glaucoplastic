#!/usr/bin/env bash
set -Eeuo pipefail

# GLAUCOPLASTIC_DEV_UI_LOGS_V1

PROJECT="${1:?project root ausente}"
TARGET="${2:?executável ausente}"
shift 2

export GLAUCOPLASTIC_UI_DEBUG="${GLAUCOPLASTIC_UI_DEBUG:-1}"

TRACE_FILE="${GLAUCOPLASTIC_UI_TRACE_FILE:-$PROJECT/.glaucoplastic/dev/ui-trace.log}"
export GLAUCOPLASTIC_UI_TRACE_FILE="$TRACE_FILE"

mkdir -p "$(dirname "$TRACE_FILE")"
touch "$TRACE_FILE"

export GLAUCOPLASTIC_UI_MUTATION_DEBUG="${GLAUCOPLASTIC_UI_MUTATION_DEBUG:-0}"

TAIL_PID=""
APP_PID=""

cleanup() {
  local status=$?

  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  if [[ -n "$TAIL_PID" ]]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi

  exit "$status"
}

trap cleanup EXIT INT TERM HUP

printf '\n[glaucoplastic:dev] UI debug: enabled\n'
printf '[glaucoplastic:dev] UI trace: %s\n' "$TRACE_FILE"
printf '[glaucoplastic:dev] executable: %s\n\n' "$TARGET"

tail -n 0 -F "$TRACE_FILE" 2>/dev/null |
  sed -u 's/^/[ui] /' &
TAIL_PID=$!

"$TARGET" "$@" &
APP_PID=$!

set +e
wait "$APP_PID"
STATUS=$?
set -e

APP_PID=""

if [[ -n "$TAIL_PID" ]]; then
  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""
fi

trap - EXIT INT TERM HUP
exit "$STATUS"
