#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${GLAUCOPLASTIC_PROJECT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
CLIENT_DIR="${GLAUCOPLASTIC_CLIENT_DIR:-$PWD}"
CLIENT_BIN_DIR="${GLAUCOPLASTIC_CLIENT_BIN_DIR:-dist/$(basename -- "$CLIENT_DIR")}"

MODEL_SLUG="IAAR-Shanghai_Metis-4B"
USER_MODEL="${GLAUCOPLASTIC_METIS_MODEL_ROOT:-$HOME/.local/share/glaucoplastic/models/metis}/$MODEL_SLUG"
PROJECT_MODEL="$PROJECT/models/metis/$MODEL_SLUG"

model_complete() {
  local root="$1"

  [[ -s "$root/config.json" ]] &&
  [[ -s "$root/modeling_metis.py" ]] &&
  [[ -s "$root/tokenizer.json" ]] &&
  [[ -s "$root/model.safetensors.index.json" ]] &&
  [[ -s "$root/model-00001-of-00002.safetensors" ]] &&
  [[ -s "$root/model-00002-of-00002.safetensors" ]]
}

MODEL_SOURCE="$PROJECT_MODEL"

if ! model_complete "$MODEL_SOURCE"; then
  MODEL_SOURCE="$USER_MODEL"
fi

if ! model_complete "$MODEL_SOURCE"; then
  echo "ERRO: o Metis não está disponível para inclusão no build." >&2
  echo "Execute: $PROJECT/scripts/ensure-metis-model.sh" >&2
  exit 1
fi

case "$CLIENT_BIN_DIR" in
  /*) OUTPUT_DIR="$CLIENT_BIN_DIR" ;;
  *)  OUTPUT_DIR="$CLIENT_DIR/$CLIENT_BIN_DIR" ;;
esac

BUNDLED_MODEL="$OUTPUT_DIR/models/metis/$MODEL_SLUG"
TEMP_BUNDLE="$OUTPUT_DIR/models/metis/.${MODEL_SLUG}.installing"

mkdir -p "$OUTPUT_DIR/models/metis"

if model_complete "$BUNDLED_MODEL" &&
   [[ -f "$MODEL_SOURCE/.glaucoplastic-model.json" ]] &&
   [[ -f "$BUNDLED_MODEL/.glaucoplastic-model.json" ]] &&
   cmp -s \
     "$MODEL_SOURCE/.glaucoplastic-model.json" \
     "$BUNDLED_MODEL/.glaucoplastic-model.json"; then
  echo "[GlaucoPlastic] Metis já incluído no build: $BUNDLED_MODEL"
else
  echo "[GlaucoPlastic] Incluindo o Metis no resultado padrão do nimble build"
  echo "  origem:  $MODEL_SOURCE"
  echo "  destino: $BUNDLED_MODEL"

  rm -rf "$TEMP_BUNDLE"
  mkdir -p "$TEMP_BUNDLE"

  cp -aL --reflink=auto "$MODEL_SOURCE/." "$TEMP_BUNDLE/"

  if ! model_complete "$TEMP_BUNDLE"; then
    rm -rf "$TEMP_BUNDLE"
    echo "ERRO: a cópia do Metis para o build ficou incompleta." >&2
    exit 1
  fi

  rm -rf "$BUNDLED_MODEL"
  mv "$TEMP_BUNDLE" "$BUNDLED_MODEL"
fi

cat > "$OUTPUT_DIR/glaucoplastic-bundle.json" <<JSON
{
  "metisModel": "models/metis/$MODEL_SLUG",
  "modelId": "IAAR-Shanghai/Metis-4B",
  "generatedBy": "nimble build"
}
JSON

echo "[GlaucoPlastic] Build completo em $OUTPUT_DIR"
du -sh "$BUNDLED_MODEL"
