#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${GLAUCOPLASTIC_MODEL_DIR:-$HOME/models/Qwen3-4B}"
MODEL_FILE="${GLAUCOPLASTIC_MODEL_FILE:-Qwen3-4B-Q4_K_M.gguf}"
MODEL_PATH="${GLAUCOPLASTIC_MODEL_PATH:-$MODEL_DIR/$MODEL_FILE}"
HF_REPO="${HF_REPO:-Qwen/Qwen3-4B-GGUF}"
HF_FILE="${HF_FILE:-$MODEL_FILE}"

mkdir -p "$MODEL_DIR" "$ROOT/models"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "==> Modelo ausente; será baixado para: $MODEL_PATH"

  if ! command -v hf >/dev/null 2>&1; then
    echo "==> Instalando a CLI oficial do Hugging Face em ~/.local/bin"
    curl -LsSf https://hf.co/cli/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
  fi

  command -v hf >/dev/null 2>&1 || {
    echo "ERRO: CLI hf não encontrada." >&2
    exit 1
  }

  ARGS=(download "$HF_REPO" "$HF_FILE" --local-dir "$MODEL_DIR")
  if [[ -n "${HF_TOKEN:-}" ]]; then
    ARGS+=(--token "$HF_TOKEN")
  fi
  hf "${ARGS[@]}"
fi

[[ -f "$MODEL_PATH" ]] || {
  echo "ERRO: modelo não encontrado: $MODEL_PATH" >&2
  exit 1
}

MODEL_SHA256="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"

# Um link pequeno permite que exemplos e ferramentas do projeto encontrem o
# modelo sem duplicar o arquivo de 2,4 GB. O framework também consulta
# diretamente ~/models/Qwen3-4B.
PROJECT_LINK="$ROOT/models/$MODEL_FILE"
rm -f "$PROJECT_LINK"
ln -s "$MODEL_PATH" "$PROJECT_LINK"

python3 - "$ROOT/models/model.json" "$HF_REPO" "$MODEL_FILE" "$MODEL_PATH" "$MODEL_SHA256" <<'PY'
import json, sys
json.dump({
    "repo": sys.argv[2],
    "file": sys.argv[3],
    "path": sys.argv[4],
    "sha256": sys.argv[5],
    "format": "GGUF",
    "role": "Qwen3 4B Instruct"
}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY

cat > "$ROOT/models/model.env" <<ENV
GLAUCOPLASTIC_MODEL_PATH=$MODEL_PATH
GLAUCOPLASTIC_MODEL_ALIAS=qwen3-4b
ENV

echo "Modelo configurado: $MODEL_PATH"
echo "Link do projeto: $PROJECT_LINK"
echo "SHA-256: $MODEL_SHA256"
