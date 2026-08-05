#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="${APP_SOURCE:-$ROOT/examples/macroobras/app.nim}"
BUILD="${BUILD:-$ROOT/build/windows-msi}"
STAGE="$BUILD/stage"
RELEASE="${RELEASE:-$ROOT/release}"
MANIFEST="$BUILD/installer.json"
WXS="$BUILD/GlaucoPlasticApp.wxs"

for command in nim python3 wixl x86_64-w64-mingw32-gcc sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $command" >&2
    exit 1
  }
done

rm -rf "$BUILD"
mkdir -p "$STAGE" "$RELEASE"

# O executável nativo que emite o manifesto é compilado primeiro. A configuração
# do nome, versão, fabricante, diretórios e assets continua em src/app.nim.
nim c \
  -d:release \
  --path:"$ROOT/src" \
  --out:"$BUILD/manifest-emitter" \
  "$APP_SOURCE"

(
  cd "$ROOT"
  "$BUILD/manifest-emitter" --manifest
)

[[ -f "$MANIFEST" ]] || {
  echo "ERRO: manifesto não foi criado: $MANIFEST" >&2
  exit 1
}

readarray -t META < <(python3 - "$MANIFEST" <<'PY'
import json, re, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
product = manifest["product_name"]
version = manifest["version"]
executable = manifest["executable"]
safe = re.sub(r"[^A-Za-z0-9._-]+", "-", product).strip("-") or "GlaucoPlasticApp"
print(product)
print(version)
print(executable)
print(safe)
PY
)

PRODUCT_NAME="${META[0]}"
PRODUCT_VERSION="${META[1]}"
TARGET_EXE="${META[2]}"
SAFE_NAME="${META[3]}"
MSI="$RELEASE/${SAFE_NAME}-${PRODUCT_VERSION}-Windows-x64.msi"

nim c \
  -d:release \
  --os:windows \
  --cpu:amd64 \
  --cc:gcc \
  --gcc.exe:x86_64-w64-mingw32-gcc \
  --gcc.linkerexe:x86_64-w64-mingw32-gcc \
  --path:"$ROOT/src" \
  --out:"$STAGE/$TARGET_EXE" \
  "$APP_SOURCE"

python3 "$ROOT/scripts/render_wix.py" \
  "$ROOT" \
  "$STAGE" \
  "$MANIFEST" \
  "$WXS"

wixl -o "$MSI" "$WXS"
sha256sum "$MSI" > "$MSI.sha256"

printf 'Produto: %s\n' "$PRODUCT_NAME"
printf 'MSI: %s\n' "$MSI"
printf 'SHA: %s\n' "$MSI.sha256"
