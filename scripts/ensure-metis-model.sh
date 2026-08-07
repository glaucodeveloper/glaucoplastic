#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_ID="${GLAUCOPLASTIC_METIS_MODEL:-IAAR-Shanghai/Metis-4B}"
MODEL_SLUG="${MODEL_ID//\//_}"
TARGET="${GLAUCOPLASTIC_METIS_DOWNLOAD_DIR:-$HOME/.local/share/glaucoplastic/models/metis/$MODEL_SLUG}"

log() {
  printf '[GlaucoPlastic:Metis] %s\n' "$*" >&2
}

model_ready() {
  local root="$1"

  [[ -d "$root" ]] || return 1
  [[ -s "$root/config.json" ]] || return 1

  local index="$root/model.safetensors.index.json"

  if [[ -s "$index" ]]; then
    python3 - "$root" "$index" <<'PY'
import json
import os
import sys

root = os.path.realpath(sys.argv[1])
index_path = sys.argv[2]

try:
    with open(index_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(1)

weight_map = payload.get("weight_map") or {}
shards = sorted(set(weight_map.values()))

if not shards:
    raise SystemExit(1)

for shard in shards:
    path = os.path.join(root, shard)
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise SystemExit(1)

raise SystemExit(0)
PY
    return $?
  fi

  [[ -s "$root/model.safetensors" ]]
}

candidate_paths() {
  local explicit="${GLAUCOPLASTIC_METIS_MODEL_PATH:-}"

  [[ -z "$explicit" ]] || printf '%s\n' "$explicit"

  printf '%s\n' \
    "$TARGET" \
    "$HOME/dev/glaucoplastic/models/Metis-4B" \
    "$HOME/models/glaucoplastic-local/Metis-4B"

  local hf_repo="$HOME/.cache/huggingface/hub/models--IAAR-Shanghai--Metis-4B"

  if [[ -s "$hf_repo/refs/main" ]]; then
    local revision
    revision="$(tr -d '\r\n' < "$hf_repo/refs/main")"
    [[ -z "$revision" ]] || printf '%s\n' "$hf_repo/snapshots/$revision"
  fi

  if [[ -d "$hf_repo/snapshots" ]]; then
    find "$hf_repo/snapshots" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -print 2>/dev/null || true
  fi
}

resolve_existing() {
  local candidate=""

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue

    if model_ready "$candidate"; then
      (
        cd "$candidate"
        pwd -P
      )
      return 0
    fi
  done < <(candidate_paths)

  return 1
}

download_model() {
  case "${GLAUCOPLASTIC_METIS_AUTO_DOWNLOAD:-1}" in
    0|false|FALSE|no|NO|off|OFF)
      log "download automático desabilitado"
      return 1
      ;;
  esac

  local python="${GLAUCOPLASTIC_METIS_PYTHON:-}"

  if [[ -z "$python" && -x "$HOME/.venvs/metis-gemma/bin/python" ]]; then
    python="$HOME/.venvs/metis-gemma/bin/python"
  fi

  if [[ -z "$python" ]]; then
    python="$(command -v python3 || command -v python || true)"
  fi

  [[ -n "$python" ]] || {
    log "Python não encontrado"
    return 1
  }

  if ! "$python" -c 'import huggingface_hub' >/dev/null 2>&1; then
    case "${GLAUCOPLASTIC_METIS_AUTO_INSTALL:-1}" in
      0|false|FALSE|no|NO|off|OFF)
        log "huggingface_hub ausente e auto-install desabilitado"
        return 1
        ;;
    esac

    log "Instalando huggingface-hub"
    "$python" -m pip install --upgrade huggingface-hub
  fi

  mkdir -p "$TARGET"

  log "Baixando $MODEL_ID"
  log "Destino: $TARGET"

  "$python" - "$MODEL_ID" "$TARGET" <<'PY'
import os
import sys
from huggingface_hub import snapshot_download

repo_id = sys.argv[1]
local_dir = sys.argv[2]

token = (
    os.environ.get("HF_TOKEN")
    or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    or None
)

cache_dir = os.environ.get("HUGGINGFACE_HUB_CACHE")

if not cache_dir:
    cache_dir = os.path.join(
        os.path.expanduser("~"),
        ".cache",
        "huggingface",
        "hub"
    )

snapshot_download(
    repo_id=repo_id,
    repo_type="model",
    local_dir=local_dir,
    cache_dir=cache_dir,
    local_files_only=False,
    token=token,
    max_workers=int(
        os.environ.get(
            "GLAUCOPLASTIC_METIS_DOWNLOAD_WORKERS",
            "4"
        )
    )
)
PY

  model_ready "$TARGET" || {
    log "checkpoint incompleto após download: $TARGET"
    return 1
  }

  (
    cd "$TARGET"
    pwd -P
  )
}

main() {
  local resolved=""

  if resolved="$(resolve_existing)"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  download_model
}

main "$@"
