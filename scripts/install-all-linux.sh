#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_core_packages() {
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm curl python tar unzip git cmake base-devel

    if pacman -Si webkit2gtk-4.1 >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm webkit2gtk-4.1
    elif pacman -Si webkit2gtk >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm webkit2gtk
    else
      echo "AVISO: WebKitGTK não foi localizado; o backend foreign nativo ficará indisponível." >&2
    fi

  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y curl python3 tar unzip git cmake build-essential libwebkit2gtk-4.1-dev

  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl python3 tar unzip git cmake gcc-c++ webkit2gtk4.1-devel

  else
    echo "Gerenciador de pacotes não reconhecido. Instale curl, Python, Git, C/C++ e WebKitGTK." >&2
  fi
}

install_core_packages
bash "$ROOT/scripts/install-nim-linux.sh"
bash "$ROOT/scripts/install-llama-runtime-linux.sh"
bash "$ROOT/scripts/configure-qwen3-model.sh"

echo "==> Registrando pacote em modo develop"
cd "$ROOT"
nimble develop -y

echo "Bootstrap Linux concluído."
