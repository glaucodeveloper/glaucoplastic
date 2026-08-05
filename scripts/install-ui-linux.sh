#!/usr/bin/env bash
set -Eeuo pipefail

if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed gtk3 webkit2gtk-4.1
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y libgtk-3-0 libwebkit2gtk-4.1-0
  exit 0
fi

if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y gtk3 webkit2gtk4.1
  exit 0
fi

echo "Instale GTK 3 e WebKitGTK 4.1 pelo gerenciador da sua distribuição." >&2
exit 1
