#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(awk -F'"' '/^version/ { print $2; exit }' "$ROOT/glaucoplastic.nimble")"
OUTPUT="${1:-$ROOT/release/glaucoplastic-nim-${VERSION}.zip}"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

for command in python3 zip sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $command" >&2
    exit 1
  }
done

PACKAGE_NAME="glaucoplastic-nim-${VERSION}"
PACKAGE_DIR="$TEMP/$PACKAGE_NAME"

python3 - "$ROOT" "$PACKAGE_DIR" <<'PY'
from __future__ import annotations
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2]).resolve()

ignored_directories = {
    ".git", "__pycache__", "nimcache"
}
ignored_suffixes = {
    ".gguf", ".dll", ".so", ".dylib", ".pyc"
}
ignored_names = {
    "llama-server", "llama-server.exe"
}

def ignore(directory: str, names: list[str]) -> set[str]:
    current = Path(directory)
    ignored: set[str] = set()
    for name in names:
        candidate = current / name
        relative = candidate.relative_to(source)
        if name in ignored_directories:
            ignored.add(name)
        elif name in ignored_names:
            ignored.add(name)
        elif candidate.is_file() and candidate.suffix.lower() in ignored_suffixes:
            ignored.add(name)
        elif relative.parts and relative.parts[0] in {"build", "release"} and name != ".gitkeep":
            ignored.add(name)
    return ignored

shutil.copytree(source, target, ignore=ignore)
PY

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
(
  cd "$TEMP"
  zip -qr "$OUTPUT" "$PACKAGE_NAME"
)
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

echo "ZIP: $OUTPUT"
echo "SHA: $OUTPUT.sha256"
