#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${GLAUCOPLASTIC_PROJECT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

MODEL_ID="IAAR-Shanghai/Metis-4B"
MODEL_SLUG="IAAR-Shanghai_Metis-4B"
HF_REPO_DIR="$HOME/.cache/huggingface/hub/models--IAAR-Shanghai--Metis-4B"
USER_MODEL_ROOT="${GLAUCOPLASTIC_METIS_MODEL_ROOT:-$HOME/.local/share/glaucoplastic/models/metis}"
USER_MODEL="$USER_MODEL_ROOT/$MODEL_SLUG"
PROJECT_MODEL="$PROJECT/models/metis/$MODEL_SLUG"
STAMP="$(date +%Y%m%d-%H%M%S)"

fail() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

model_complete() {
  local root="$1"

  [[ -s "$root/config.json" ]] &&
  [[ -s "$root/configuration_metis.py" ]] &&
  [[ -s "$root/modeling_metis.py" ]] &&
  [[ -s "$root/tokenizer.json" ]] &&
  [[ -s "$root/model.safetensors.index.json" ]] &&
  [[ -s "$root/model-00001-of-00002.safetensors" ]] &&
  [[ -s "$root/model-00002-of-00002.safetensors" ]]
}

find_hf_snapshot() {
  local revision=""
  local candidate=""

  if [[ -s "$HF_REPO_DIR/refs/main" ]]; then
    revision="$(tr -d '\r\n' < "$HF_REPO_DIR/refs/main")"
    candidate="$HF_REPO_DIR/snapshots/$revision"

    if model_complete "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ -d "$HF_REPO_DIR/snapshots" ]]; then
    while IFS= read -r candidate; do
      if model_complete "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(
      find "$HF_REPO_DIR/snapshots" \
        -mindepth 1 -maxdepth 1 -type d \
        -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      cut -d' ' -f2-
    )
  fi

  return 1
}

register_project_model() {
  mkdir -p "$(dirname -- "$PROJECT_MODEL")"

  if [[ -e "$PROJECT_MODEL" || -L "$PROJECT_MODEL" ]]; then
    rm -rf "$PROJECT_MODEL"
  fi

  ln -s "$USER_MODEL" "$PROJECT_MODEL"
}

mkdir -p "$USER_MODEL_ROOT"

if model_complete "$USER_MODEL"; then
  register_project_model
  echo "[GlaucoPlastic] Metis disponível em $USER_MODEL"
  exit 0
fi

TEMP_MODEL="$USER_MODEL.installing-$STAMP"
rm -rf "$TEMP_MODEL"
mkdir -p "$TEMP_MODEL"

if SNAPSHOT="$(find_hf_snapshot)"; then
  echo "[GlaucoPlastic] Materializando o Metis do cache Hugging Face"
  echo "  origem:  $SNAPSHOT"
  echo "  destino: $USER_MODEL"

  cp -aL --reflink=auto "$SNAPSHOT/." "$TEMP_MODEL/"
else
  echo "[GlaucoPlastic] Cache completo ausente; baixando $MODEL_ID"

  PYTHON="${GLAUCOPLASTIC_BUILD_PYTHON:-python3}"

  "$PYTHON" - "$MODEL_ID" "$TEMP_MODEL" <<'PY'
from pathlib import Path
import subprocess
import sys

repo_id = sys.argv[1]
destination = Path(sys.argv[2]).resolve()

try:
    from huggingface_hub import snapshot_download
except ImportError:
    subprocess.check_call([
        sys.executable,
        "-m",
        "pip",
        "install",
        "--user",
        "--upgrade",
        "huggingface_hub",
    ])
    from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=repo_id,
    local_dir=str(destination),
    max_workers=4,
)
PY
fi

if ! model_complete "$TEMP_MODEL"; then
  rm -rf "$TEMP_MODEL"
  fail "o download/materialização terminou com o modelo incompleto"
fi

if find "$TEMP_MODEL" -type l -print -quit | grep -q .; then
  rm -rf "$TEMP_MODEL"
  fail "a pasta materializada ainda contém links simbólicos"
fi

cat > "$TEMP_MODEL/.glaucoplastic-model.json" <<JSON
{
  "modelId": "$MODEL_ID",
  "directoryName": "$MODEL_SLUG",
  "source": "user-model-store"
}
JSON

rm -rf "$USER_MODEL"
mv "$TEMP_MODEL" "$USER_MODEL"
register_project_model

echo "[GlaucoPlastic] Metis preparado em $USER_MODEL"
