#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${GLAUCOPLASTIC_WINDOWS_RUNTIME_DIR:-$ROOT/runtime/llama/windows-x64}"
BIN_DIR="$RUNTIME_ROOT/bin"
BACKEND="${LLAMA_WINDOWS_BACKEND:-cpu}"
API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for command in curl python3 unzip sha256sum find; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $command" >&2
    exit 1
  }
done

case "$BACKEND" in
  cpu) REGEX='^llama-b[0-9]+-bin-win-cpu-x64\.zip$' ;;
  vulkan) REGEX='^llama-b[0-9]+-bin-win-vulkan-x64\.zip$' ;;
  cuda12) REGEX='^llama-b[0-9]+-bin-win-cuda-12\.[0-9]+-x64\.zip$' ;;
  cuda13) REGEX='^llama-b[0-9]+-bin-win-cuda-13\.[0-9]+-x64\.zip$' ;;
  *)
    echo "ERRO: LLAMA_WINDOWS_BACKEND deve ser cpu, vulkan, cuda12 ou cuda13" >&2
    exit 1
    ;;
esac

echo "==> Pasta dos binários Windows: $BIN_DIR"
echo "==> Consultando a release mais recente do llama.cpp"
curl -fsSL -H 'Accept: application/vnd.github+json' "$API" -o "$TMP/release.json"

readarray -t VALUES < <(python3 - "$TMP/release.json" "$REGEX" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
pattern = re.compile(sys.argv[2])
for asset in release.get("assets", []):
    if pattern.match(asset["name"]):
        print(release["tag_name"])
        print(asset["name"])
        print(asset["browser_download_url"])
        print(asset.get("digest") or "")
        break
else:
    raise SystemExit("Nenhum asset Windows compatível encontrado")
PY
)

TAG="${VALUES[0]}"
ASSET="${VALUES[1]}"
URL="${VALUES[2]}"
DIGEST="${VALUES[3]:-}"
ARCHIVE="$TMP/runtime.zip"
EXTRACTED="$TMP/extracted"

echo "==> Baixando $ASSET"
curl -fL --retry 4 "$URL" -o "$ARCHIVE"

if [[ "$DIGEST" == sha256:* ]]; then
  EXPECTED="${DIGEST#sha256:}"
  ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  [[ "$ACTUAL" == "$EXPECTED" ]] || {
    echo "ERRO: SHA-256 do runtime Windows não confere." >&2
    exit 1
  }
fi

mkdir -p "$EXTRACTED"
unzip -q "$ARCHIVE" -d "$EXTRACTED"
SERVER="$(find "$EXTRACTED" -type f -iname 'llama-server.exe' -print -quit)"
[[ -n "$SERVER" ]] || {
  echo "ERRO: llama-server.exe não encontrado." >&2
  exit 1
}
SERVER_DIR="$(dirname "$SERVER")"

rm -rf "$RUNTIME_ROOT"
mkdir -p "$BIN_DIR"
cp -a "$SERVER_DIR"/. "$BIN_DIR"/

if [[ "$BACKEND" == cuda12 || "$BACKEND" == cuda13 ]]; then
  CUDA_MAJOR="${BACKEND#cuda}"
  readarray -t CUDA_VALUES < <(python3 - "$TMP/release.json" "$CUDA_MAJOR" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
major = re.escape(sys.argv[2])
pattern = re.compile(rf"^cudart-llama-bin-win-cuda-{major}\.[0-9]+-x64\.zip$")
for asset in release.get("assets", []):
    if pattern.match(asset["name"]):
        print(asset["name"])
        print(asset["browser_download_url"])
        print(asset.get("digest") or "")
        break
else:
    raise SystemExit("Runtime CUDA correspondente não encontrado")
PY
  )
  CUDA_ARCHIVE="$TMP/cudart.zip"
  curl -fL --retry 4 "${CUDA_VALUES[1]}" -o "$CUDA_ARCHIVE"
  if [[ "${CUDA_VALUES[2]:-}" == sha256:* ]]; then
    EXPECTED="${CUDA_VALUES[2]#sha256:}"
    ACTUAL="$(sha256sum "$CUDA_ARCHIVE" | awk '{print $1}')"
    [[ "$ACTUAL" == "$EXPECTED" ]] || {
      echo "ERRO: SHA-256 do runtime CUDA não confere." >&2
      exit 1
    }
  fi
  unzip -q -o "$CUDA_ARCHIVE" -d "$BIN_DIR"
fi

python3 - "$RUNTIME_ROOT/VERSION.json" "$TAG" "$ASSET" "$BACKEND" "$BIN_DIR" <<'PY'
import json, sys
json.dump({
    "tag": sys.argv[2],
    "asset": sys.argv[3],
    "backend": sys.argv[4],
    "bin_directory": sys.argv[5]
}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY

echo "Runtime Windows preparado em: $RUNTIME_ROOT"
echo "Binários disponíveis em: $BIN_DIR"
