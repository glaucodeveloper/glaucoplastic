#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ROOT" && pwd)"

INDEX="$ROOT/website/index.html"
TARGET="$ROOT/website/assets/css/viewport-flow-patch.css"
SOURCE="$PATCH_DIR/website/assets/css/viewport-flow-patch.css"
STAMP="$(date +%Y%m%d-%H%M%S)"

[[ -f "$INDEX" ]] || {
  echo "Erro: não encontrei $INDEX"
  exit 1
}

[[ -f "$SOURCE" ]] || {
  echo "Erro: não encontrei $SOURCE"
  exit 1
}

mkdir -p "$(dirname "$TARGET")"

cp "$INDEX" "$INDEX.bak.$STAMP"

if [[ -f "$TARGET" ]]; then
  cp "$TARGET" "$TARGET.bak.$STAMP"
fi

cp "$SOURCE" "$TARGET"

python3 - "$INDEX" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

tag = '<link href="./assets/css/viewport-flow-patch.css" rel="stylesheet">'

# Remove duplicatas anteriores antes de reinserir a tag no final dos estilos.
source = re.sub(
    r'\s*<link\s+href=["\']\./assets/css/viewport-flow-patch\.css["\']\s+rel=["\']stylesheet["\']\s*/?>',
    '',
    source,
    flags=re.I,
)

if "</head>" not in source:
    raise SystemExit("Erro: não encontrei </head> em website/index.html.")

source = source.replace(
    "</head>",
    f"  {tag}\n</head>",
    1,
)

path.write_text(source, encoding="utf-8")
PY

python3 - "$TARGET" "$INDEX" <<'PY'
from pathlib import Path
import sys

css = Path(sys.argv[1]).read_text(encoding="utf-8")
html = Path(sys.argv[2]).read_text(encoding="utf-8")

if css.count("{") != css.count("}"):
    raise SystemExit("Erro: quantidade incompatível de chaves no CSS.")

if html.count("viewport-flow-patch.css") != 1:
    raise SystemExit("Erro: a folha de estilo não foi vinculada exatamente uma vez.")

print("Validação concluída.")
PY

echo
echo "Fluxo vertical responsivo aplicado."
echo
echo "Arquivo criado:"
echo "  website/assets/css/viewport-flow-patch.css"
echo
echo "A página agora:"
echo "  - ocupa a altura disponível quando o conteúdo é curto"
echo "  - cresce naturalmente quando o conteúdo é longo"
echo "  - mantém scroll-y como fallback"
echo "  - rola o conteúdo central do admin sem perder sidebar/topbar"
echo "  - limita sidebar, menu móvel e chat à altura da janela"
echo
echo "Publique:"
echo "  git add website/index.html website/assets/css/viewport-flow-patch.css"
echo '  git commit -m "fix: ajusta fluxo vertical e fallback de rolagem"'
echo "  git pull --rebase origin main"
echo "  git push origin main"
