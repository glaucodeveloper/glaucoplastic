#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

exec nimble run -- \
  --mode=phone-api \
  --duration="${1:-6}" \
  --phone-api="${PHONE_MIC_CONTROL_URL:-http://127.0.0.1:5003}"
