#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export GLAUCOPLASTIC_VOICE_RECOGNITION="system-microphone"
export GLAUCOPLASTIC_VOICE_INPUT_DEVICE="${GLAUCOPLASTIC_VOICE_INPUT_DEVICE:-glauco_phone_mic}"
export GLAUCOPLASTIC_WHISPER_BINARY="${GLAUCOPLASTIC_WHISPER_BINARY:-$ROOT/.runtime/whisper.cpp/build/bin/whisper-cli}"
export GLAUCOPLASTIC_WHISPER_MODEL="${GLAUCOPLASTIC_WHISPER_MODEL:-$ROOT/.runtime/whisper.cpp/models/ggml-base.bin}"
export GLAUCOPLASTIC_FFMPEG_BINARY="${GLAUCOPLASTIC_FFMPEG_BINARY:-ffmpeg}"
unset GLAUCOPLASTIC_WEB_SERVER GLAUCOPLASTIC_WEB_HOST GLAUCOPLASTIC_WEB_PORT

systemctl --user start audio-speaker.service 2>/dev/null || true

for _ in $(seq 1 30); do
  if ! command -v pactl >/dev/null 2>&1 || \
      pactl list sources short 2>/dev/null | grep -q "$GLAUCOPLASTIC_VOICE_INPUT_DEVICE"; then
    break
  fi
  sleep 0.2
done

exec nimble run
