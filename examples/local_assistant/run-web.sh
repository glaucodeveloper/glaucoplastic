#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PORT="${1:-${GLAUCOPLASTIC_WEB_PORT:-8765}}"
HOST="${2:-${GLAUCOPLASTIC_WEB_HOST:-0.0.0.0}}"

export LOCALAPPDATA="$ROOT/.localappdata"
export GLAUCOPLASTIC_WEB_SERVER=1
export GLAUCOPLASTIC_WEB_HOST="$HOST"
export GLAUCOPLASTIC_WEB_PORT="$PORT"
export NIMBLE_DIR="$ROOT/.nimble"
mkdir -p "$NIMBLE_DIR"
for name in packages_official.json packages_temp.json official-nim-releases.json; do
  if [[ ! -e "$NIMBLE_DIR/$name" && -e "$HOME/.nimble/$name" ]]; then
    cp "$HOME/.nimble/$name" "$NIMBLE_DIR/$name"
  fi
done
export GLAUCOPLASTIC_VOICE_RECOGNITION="system-microphone"
export GLAUCOPLASTIC_VOICE_INPUT_DEVICE="${GLAUCOPLASTIC_VOICE_INPUT_DEVICE:-glauco_phone_mic}"
export GLAUCOPLASTIC_WHISPER_BINARY="${GLAUCOPLASTIC_WHISPER_BINARY:-$ROOT/.runtime/whisper.cpp/build/bin/whisper-cli}"
export GLAUCOPLASTIC_WHISPER_MODEL="${GLAUCOPLASTIC_WHISPER_MODEL:-$ROOT/.runtime/whisper.cpp/models/ggml-base.bin}"
export GLAUCOPLASTIC_FFMPEG_BINARY="${GLAUCOPLASTIC_FFMPEG_BINARY:-ffmpeg}"

systemctl --user start audio-speaker.service 2>/dev/null || true

for _ in $(seq 1 30); do
  if ! command -v pactl >/dev/null 2>&1 || \
      pactl list sources short 2>/dev/null | grep -q "$GLAUCOPLASTIC_VOICE_INPUT_DEVICE"; then
    break
  fi
  sleep 0.2
done

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf 'Local Assistant WebUI\n'
printf '  local: http://127.0.0.1:%s\n' "$PORT"
[[ -n "$LAN_IP" ]] && printf '  rede:  http://%s:%s\n' "$LAN_IP" "$PORT"
printf '  mic:   %s\n\n' "$GLAUCOPLASTIC_VOICE_INPUT_DEVICE"

exec nim c -r -d:glaucoplasticHeadless --path:../../src ./assistant_consumer.nim
