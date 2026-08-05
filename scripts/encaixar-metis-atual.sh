#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${GLAUCOPLASTIC_PROJECT:-${1:-$HOME/dev/glaucoplastic}}"
CLIENT_DIR="${GLAUCOPLASTIC_CLIENT_DIR:-${2:-$PROJECT/examples/consumer}}"
FRAMEWORK="$PROJECT/src/glaucoplastic.nim"
CLIENT_NIMBLE="${GLAUCOPLASTIC_CLIENT_NIMBLE:-}"

MODEL_ID="IAAR-Shanghai/Metis-4B"
MODEL_SLUG="IAAR-Shanghai_Metis-4B"
USER_MODEL_ROOT="${GLAUCOPLASTIC_METIS_MODEL_ROOT:-$HOME/.local/share/glaucoplastic/models/metis}"
USER_MODEL="$USER_MODEL_ROOT/$MODEL_SLUG"
PROJECT_MODEL="$PROJECT/models/metis/$MODEL_SLUG"

ENSURE_SCRIPT="$PROJECT/scripts/ensure-metis-model.sh"
PACKAGE_SCRIPT="$PROJECT/scripts/package-client-with-metis.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"

fail() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

[[ -f "$FRAMEWORK" ]] ||
  fail "GlaucoPlastic não encontrado em $FRAMEWORK"

if [[ -z "$CLIENT_NIMBLE" ]]; then
  mapfile -t NIMBLE_FILES < <(
    find "$CLIENT_DIR" -maxdepth 1 -type f -name '*.nimble' -print | sort
  )

  [[ "${#NIMBLE_FILES[@]}" -eq 1 ]] ||
    fail "era esperado exatamente um arquivo .nimble em $CLIENT_DIR"

  CLIENT_NIMBLE="${NIMBLE_FILES[0]}"
fi

[[ -f "$CLIENT_NIMBLE" ]] ||
  fail "arquivo Nimble não encontrado: $CLIENT_NIMBLE"

mkdir -p \
  "$PROJECT/scripts" \
  "$PROJECT/models/metis" \
  "$USER_MODEL_ROOT"

cat > "$ENSURE_SCRIPT" <<'BASH'
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
BASH

cat > "$PACKAGE_SCRIPT" <<'BASH'
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
BASH

chmod +x "$ENSURE_SCRIPT" "$PACKAGE_SCRIPT"

"$ENSURE_SCRIPT"

PACKAGE_NAME="$(basename -- "$CLIENT_NIMBLE" .nimble)"
cp -a "$CLIENT_NIMBLE" "$CLIENT_NIMBLE.bak.$STAMP"

python3 - "$CLIENT_NIMBLE" "$PACKAGE_NAME" <<'PY'
from pathlib import Path
import re
import sys

nimble_path = Path(sys.argv[1])
package_name = sys.argv[2]
text = nimble_path.read_text(encoding="utf-8")

begin = "# BEGIN GLAUCOPLASTIC METIS STANDARD BUILD"
end = "# END GLAUCOPLASTIC METIS STANDARD BUILD"

text = re.sub(
    rf"\n?{re.escape(begin)}.*?{re.escape(end)}\n?",
    "\n",
    text,
    flags=re.S,
)

text = re.sub(
    r"\n?task\s+bundleMetis\s*,[^\n]*:\s*\n"
    r"(?:[ \t]+[^\n]*(?:\n|$))+",
    "\n",
    text,
)

if not re.search(r"(?m)^[ \t]*binDir[ \t]*=", text):
    text = text.rstrip() + f'\n\nbinDir = "dist/{package_name}"\n'

block = f'''
{begin}
import std/os

let glaucoplasticProjectRoot =
  getEnv(
    "GLAUCOPLASTIC_PROJECT",
    absolutePath(thisDir() / ".." / "..")
  )

before build:
  putEnv("GLAUCOPLASTIC_PROJECT", glaucoplasticProjectRoot)
  putEnv("GLAUCOPLASTIC_CLIENT_DIR", thisDir())
  exec quoteShell(
    glaucoplasticProjectRoot /
      "scripts" /
      "ensure-metis-model.sh"
  )

after build:
  putEnv("GLAUCOPLASTIC_PROJECT", glaucoplasticProjectRoot)
  putEnv("GLAUCOPLASTIC_CLIENT_DIR", thisDir())
  putEnv("GLAUCOPLASTIC_CLIENT_BIN_DIR", binDir)
  exec quoteShell(
    glaucoplasticProjectRoot /
      "scripts" /
      "package-client-with-metis.sh"
  )
{end}
'''

nimble_path.write_text(
    text.rstrip() + "\n\n" + block.lstrip(),
    encoding="utf-8",
)
PY

SELF_TARGET="$PROJECT/scripts/encaixar-metis-atual.sh"
if [[ "$(readlink -f "$0")" != "$(readlink -f "$SELF_TARGET" 2>/dev/null || true)" ]]; then
  cp -a "$0" "$SELF_TARGET"
  chmod +x "$SELF_TARGET"
fi

echo
echo "Integração concluída."
echo
echo "O comando padrão agora é:"
echo "  cd \"$CLIENT_DIR\""
echo "  nimble build"
echo
echo "O nimble build:"
echo "  1. garante o Metis na pasta do usuário;"
echo "  2. compila os binários declarados no .nimble;"
echo "  3. inclui o modelo em binDir/models/metis/$MODEL_SLUG."
echo
echo "Arquivo alterado:"
echo "  $CLIENT_NIMBLE"
echo
echo "Backup:"
echo "  $CLIENT_NIMBLE.bak.$STAMP"
