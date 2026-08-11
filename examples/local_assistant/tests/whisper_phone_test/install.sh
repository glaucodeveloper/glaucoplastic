#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$HOME/dev/glaucoplastic}"
TARGET="$ROOT/examples/local_assistant/tests/whisper_phone_test"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$(dirname -- "$TARGET")"
rm -rf "$TARGET"
cp -a "$HERE" "$TARGET"

chmod +x \
  "$TARGET/run-system.sh" \
  "$TARGET/run-phone-api.sh"

cd "$TARGET"
nimble build

echo
echo "Instalado em:"
echo "  $TARGET"
echo
echo "Teste pela fonte do sistema:"
echo "  $TARGET/run-system.sh 6"
echo
echo "Teste direto pela API do celular:"
echo "  $TARGET/run-phone-api.sh 6"
