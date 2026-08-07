#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${GLAUCOPLASTIC_PROJECT:-$PWD}"
APP_NAME="${GLAUCOPLASTIC_APPLICATION:-app}"
APP_SOURCE="${GLAUCOPLASTIC_APP_SOURCE:-$PROJECT/$APP_NAME.nim}"
DIST="${GLAUCOPLASTIC_LINUX_DIST:-$PROJECT/dist/linux-x64}"
BUILD="${GLAUCOPLASTIC_LINUX_BUILD:-$PROJECT/.build/linux-x64}"

MODEL_SLUG="IAAR-Shanghai_Metis-4B"
MODEL_SOURCE="${GLAUCOPLASTIC_METIS_MODEL_SOURCE:-$ROOT/models/metis/$MODEL_SLUG}"
MODEL_DEST="$DIST/models/metis/$MODEL_SLUG"

PYTHON_SOURCE="${GLAUCOPLASTIC_METIS_PYTHON:-$HOME/.venvs/metis-gemma/bin/python}"
PYDEST="$DIST/runtime/metis/python"

EXE="$DIST/$APP_NAME"
NIMCACHE="$BUILD/nimcache"

log() {
  printf '[linux-build] %s\n' "$*"
}

die() {
  printf '[linux-build:error] %s\n' "$*" >&2
  exit 1
}

[[ -f "$APP_SOURCE" ]] || die "fonte não encontrada: $APP_SOURCE"
[[ -f "$ROOT/src/glaucoplastic.nim" ]] ||
  die "framework não encontrado: $ROOT/src/glaucoplastic.nim"

[[ -s "$MODEL_SOURCE/config.json" ]] ||
  die "Metis não encontrado: $MODEL_SOURCE"

[[ -x "$PYTHON_SOURCE" ]] ||
  die "Python Metis não encontrado: $PYTHON_SOURCE"

mkdir -p "$DIST" "$BUILD" "$NIMCACHE"

log "compilando $APP_NAME para Linux x64"
nim c \
  --threads:on \
  --mm:orc \
  -d:release \
  --opt:speed \
  --path:"$ROOT/src" \
  --nimcache:"$NIMCACHE" \
  --out:"$EXE" \
  "$APP_SOURCE"

log "materializando Metis"
mkdir -p "$DIST/models/metis"
if [[ -s "$MODEL_DEST/config.json" &&
      -s "$MODEL_DEST/model.safetensors.index.json" ]]; then
  log "Metis já presente no bundle"
else
  rm -rf "$MODEL_DEST"
  if command -v rsync >/dev/null 2>&1; then
    mkdir -p "$MODEL_DEST"
    rsync -aL "$MODEL_SOURCE/" "$MODEL_DEST/"
  else
    cp -aL --reflink=auto "$MODEL_SOURCE" "$MODEL_DEST"
  fi
fi

readarray -t PYINFO < <(
  "$PYTHON_SOURCE" - <<'PY'
import os
import site
import sys

print(os.path.realpath(sys.base_prefix))
paths = site.getsitepackages()
print(os.path.realpath(paths[0] if paths else ""))
print(f"{sys.version_info.major}.{sys.version_info.minor}")
print(os.path.realpath(sys.executable))
PY
)

BASE_PREFIX="${PYINFO[0]:-}"
SITE_SOURCE="${PYINFO[1]:-}"
PY_SERIES="${PYINFO[2]:-3.10}"

[[ -d "$BASE_PREFIX" ]] || die "base_prefix Python inválido: $BASE_PREFIX"
[[ -d "$SITE_SOURCE" ]] || die "site-packages inválido: $SITE_SOURCE"

if [[ -x "$PYDEST/bin/python" &&
      -d "$PYDEST/lib/python$PY_SERIES/site-packages/torch" &&
      -d "$PYDEST/lib/python$PY_SERIES/site-packages/transformers" ]]; then
  log "runtime Python já presente no bundle"
else
  log "materializando CPython Linux"
  rm -rf "$PYDEST"
  mkdir -p "$PYDEST"

  if command -v rsync >/dev/null 2>&1; then
    rsync -aL \
      --exclude='__pycache__/' \
      --exclude='*.pyc' \
      "$BASE_PREFIX/" "$PYDEST/"
  else
    cp -aL --reflink=auto "$BASE_PREFIX/." "$PYDEST/"
    find "$PYDEST" -type d -name '__pycache__' -prune -exec rm -rf {} + || true
    find "$PYDEST" -type f -name '*.pyc' -delete || true
  fi

  SITE_DEST="$PYDEST/lib/python$PY_SERIES/site-packages"
  mkdir -p "$SITE_DEST"

  log "incluindo dependências Python do Metis"
  if command -v rsync >/dev/null 2>&1; then
    rsync -aL \
      --exclude='__pycache__/' \
      --exclude='*.pyc' \
      "$SITE_SOURCE/" "$SITE_DEST/"
  else
    cp -aL --reflink=auto "$SITE_SOURCE/." "$SITE_DEST/"
    find "$SITE_DEST" -type d -name '__pycache__' -prune -exec rm -rf {} + || true
    find "$SITE_DEST" -type f -name '*.pyc' -delete || true
  fi

  if [[ ! -e "$PYDEST/bin/python" ]]; then
    if [[ -x "$PYDEST/bin/python$PY_SERIES" ]]; then
      ln -s "python$PY_SERIES" "$PYDEST/bin/python"
    elif [[ -x "$PYDEST/bin/python3" ]]; then
      ln -s python3 "$PYDEST/bin/python"
    else
      die "Python materializado sem bin/python"
    fi
  fi
fi

for package in torch transformers accelerate bitsandbytes safetensors tokenizers fla; do
  [[ -e "$PYDEST/lib/python$PY_SERIES/site-packages/$package" ]] ||
    die "dependência Python ausente no bundle: $package"
done

mkdir -p "$DIST/tools"

for tool in \
  glaucoplastic_rpa.py \
  glaucoplastic_office.py
do
  if [[ -f "$ROOT/tools/$tool" ]]; then
    cp -a "$ROOT/tools/$tool" "$DIST/tools/$tool"
  fi
done

cat > "$DIST/glaucoplastic-bundle.json" <<JSON
{
  "schema": "glaucoplastic.bundle.v2",
  "application": "$APP_NAME",
  "target": "linux-x64",
  "metisModel": "models/metis/$MODEL_SLUG",
  "pythonRuntime": "runtime/metis/python",
  "foreignDesktop": "webkitgtk",
  "networkWebForeign": "unsupported"
}
JSON

log "bundle Linux concluído"
du -sh "$DIST" "$PYDEST" "$MODEL_DEST" || true
printf '\n[linux-build] artefatos principais:\n'
printf '  %s\n' "$EXE"
printf '  %s\n' "$PYDEST/bin/python"
printf '  %s\n' "$MODEL_DEST"
