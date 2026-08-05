#!/usr/bin/env bash
set -Eeuo pipefail

if command -v nim >/dev/null 2>&1 && command -v nimble >/dev/null 2>&1; then
  nim --version | head -n 1
  exit 0
fi

if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm nim gcc git
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y nim gcc git
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y nim gcc git
else
  command -v curl >/dev/null 2>&1 || {
    echo "ERRO: curl é necessário para instalar Nim via choosenim." >&2
    exit 1
  }
  curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
  export PATH="$HOME/.nimble/bin:$PATH"
fi

command -v nim >/dev/null 2>&1 || {
  echo "ERRO: Nim não foi encontrado após a instalação." >&2
  exit 1
}
command -v nimble >/dev/null 2>&1 || {
  echo "ERRO: Nimble não foi encontrado após a instalação." >&2
  exit 1
}

nim --version | head -n 1
