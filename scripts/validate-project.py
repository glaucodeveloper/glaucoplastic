#!/usr/bin/env python3
from __future__ import annotations

import ast
import os
import py_compile
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
errors: list[str] = []

required = [
    "glaucoplastic.nimble",
    "src/glaucoplastic.nim",
    "examples/macroobras/app.nim",
    "examples/consumer/consumer.nimble",
    "scripts/install-all-linux.sh",
    "scripts/install-all-windows.ps1",
    "scripts/install-llama-runtime-linux.sh",
    "scripts/install-llama-runtime-windows.ps1",
    "scripts/download-gemma4.sh",
    "scripts/download-gemma4.ps1",
    "scripts/build-msi.sh",
    "scripts/render_wix.py",
]
for relative in required:
    if not (root / relative).is_file():
        errors.append(f"arquivo obrigatório ausente: {relative}")

monolith = (root / "src/glaucoplastic.nim").read_text(encoding="utf-8")
for marker in [
    "macro glaucoplastic*",
    "PlasticOrmRuntime",
    "PlasticStateRuntime",
    "PlasticOkfRuntime",
    "PlasticGitMemory",
    "PlasticRlmRuntime",
    "PlasticForeignBackend",
    "writeInstallerManifest*",
]:
    if marker not in monolith:
        errors.append(f"marcador ausente no monólito: {marker}")

example = (root / "examples/macroobras/app.nim").read_text(encoding="utf-8")
for marker in [
    "agents:",
    "foreign(",
    "when states.ObraSelecionada changed:",
    "okfs:",
    "installation:",
]:
    if marker not in example:
        errors.append(f"exemplo sem sintaxe esperada: {marker}")

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix.lower() in {".gguf", ".dll", ".so", ".dylib"}:
        errors.append(f"binário pesado não deve estar no ZIP: {path.relative_to(root)}")
    if path.name in {"llama-server", "llama-server.exe"}:
        errors.append(f"runtime deve ser baixado pelo instalador: {path.relative_to(root)}")

try:
    py_compile.compile(str(root / "scripts/render_wix.py"), doraise=True)
except Exception as error:
    errors.append(f"render_wix.py inválido: {error}")

if errors:
    print("VALIDAÇÃO FALHOU", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print("Validação estrutural concluída.")
print(f"Monólito: {len(monolith.splitlines())} linhas")
print(f"Arquivos: {sum(1 for path in root.rglob('*') if path.is_file())}")
