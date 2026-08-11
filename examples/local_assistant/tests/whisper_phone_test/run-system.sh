#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

exec nimble run -- \
  --mode=system \
  --duration="${1:-6}" \
  --device="${GLAUCOPLASTIC_VOICE_INPUT_DEVICE:-glauco_phone_mic}"
