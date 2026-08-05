#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${GLAUCOPLASTIC_RUNTIME_DIR:-$ROOT/runtime/llama/linux-x64}"
BIN_DIR="$RUNTIME_ROOT/bin"
BACKEND="${LLAMA_BACKEND:-vulkan}"
API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for command in curl python3 tar unzip sha256sum find; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $command" >&2
    exit 1
  }
done

case "$BACKEND" in
  cpu)
    REGEX='^llama-b[0-9]+-bin-ubuntu-x64\.(tar\.gz|zip)$'
    ;;
  vulkan)
    REGEX='^llama-b[0-9]+-bin-ubuntu-vulkan-x64\.(tar\.gz|zip)$'
    ;;
  rocm)
    REGEX='^llama-b[0-9]+-bin-ubuntu-rocm-[0-9.]+-x64\.(tar\.gz|zip)$'
    ;;
  *)
    echo "ERRO: LLAMA_BACKEND deve ser cpu, vulkan ou rocm" >&2
    exit 1
    ;;
esac

echo "==> Pasta dos binários: $BIN_DIR"
echo "==> Consultando a versão mais recente do llama.cpp"
curl -fsSL -H 'Accept: application/vnd.github+json' "$API" -o "$TMP/release.json"

readarray -t VALUES < <(python3 - "$TMP/release.json" "$REGEX" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1], encoding='utf-8'))
pattern = re.compile(sys.argv[2])
for asset in release.get('assets', []):
    if pattern.match(asset['name']):
        print(release['tag_name'])
        print(asset['name'])
        print(asset['browser_download_url'])
        print(asset.get('digest') or '')
        break
else:
    names = '\n'.join(a.get('name', '') for a in release.get('assets', []))
    raise SystemExit('Nenhum asset compatível encontrado. Assets disponíveis:\n' + names)
PY
)

TAG="${VALUES[0]}"
ASSET="${VALUES[1]}"
URL="${VALUES[2]}"
DIGEST="${VALUES[3]:-}"
ARCHIVE="$TMP/$ASSET"
EXTRACTED="$TMP/extracted"

echo "==> Baixando $ASSET"
curl -fL --retry 4 "$URL" -o "$ARCHIVE"

if [[ "$DIGEST" == sha256:* ]]; then
  EXPECTED="${DIGEST#sha256:}"
  ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  [[ "$ACTUAL" == "$EXPECTED" ]] || {
    echo "ERRO: SHA-256 do runtime não confere." >&2
    exit 1
  }
fi

mkdir -p "$EXTRACTED"
case "$ASSET" in
  *.tar.gz) tar -xzf "$ARCHIVE" -C "$EXTRACTED" ;;
  *.zip) unzip -q "$ARCHIVE" -d "$EXTRACTED" ;;
  *) echo "ERRO: formato de arquivo desconhecido: $ASSET" >&2; exit 1 ;;
esac

SERVER="$(find "$EXTRACTED" -type f -name 'llama-server' -print -quit)"
[[ -n "$SERVER" ]] || {
  echo "ERRO: llama-server não encontrado no arquivo baixado." >&2
  exit 1
}

SERVER_DIR="$(dirname "$SERVER")"
rm -rf "$RUNTIME_ROOT"
mkdir -p "$BIN_DIR"
cp -a "$SERVER_DIR"/. "$BIN_DIR"/
chmod +x "$BIN_DIR/llama-server"

python3 - "$RUNTIME_ROOT/VERSION.json" "$TAG" "$ASSET" "$BACKEND" "$BIN_DIR" <<'PY'
import json, sys
json.dump({
    'tag': sys.argv[2],
    'asset': sys.argv[3],
    'backend': sys.argv[4],
    'bin_directory': sys.argv[5]
}, open(sys.argv[1], 'w', encoding='utf-8'), indent=2)
PY

echo "Runtime Linux instalado em: $RUNTIME_ROOT"
echo "Binários disponíveis em: $BIN_DIR"
"$BIN_DIR/llama-server" --version || true
