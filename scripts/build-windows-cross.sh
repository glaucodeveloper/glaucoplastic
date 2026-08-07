#!/usr/bin/env bash
set -Eeuo pipefail

# GlaucoPlastic - cross build Windows x64 a partir de Linux.
#
# Produz:
#   dist/windows-x64/
#     assistant_consumer.exe
#     models/metis/IAAR-Shanghai_Metis-4B/
#     runtime/metis/python/
#     tools/glaucoplastic_rpa.py (se existir)
#
# O build host é Linux. Nenhum binário Windows é executado durante o build.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${GLAUCOPLASTIC_WINDOWS_DIST:-$ROOT/dist/windows-x64}"
BUILD="${GLAUCOPLASTIC_WINDOWS_BUILD:-$ROOT/.build/windows-x64}"
WHEELHOUSE="$BUILD/wheelhouse"
DOWNLOADS="$BUILD/downloads"
NIMCACHE="$BUILD/nimcache"

APP_SOURCE="${GLAUCOPLASTIC_WINDOWS_APP_SOURCE:-$ROOT/examples/local_assistant/assistant_consumer.nim}"
APP_NAME="${GLAUCOPLASTIC_APPLICATION:-$(basename "$APP_SOURCE" .nim)}"
GENERATED_SOURCE="$BUILD/${APP_NAME}_windows.nim"
EXE="$DIST/${APP_NAME}.exe"

PYTHON_VERSION="3.10.11"
PYTHON_SERIES="3.10"
PYTHON_TAG="310"
PYROOT="$DIST/runtime/metis/python"
SITE="$PYROOT/Lib/site-packages"
PYTHON_ZIP="$DOWNLOADS/python-${PYTHON_VERSION}-embed-amd64.zip"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-embed-amd64.zip"

MODEL_SLUG="IAAR-Shanghai_Metis-4B"
MODEL_SOURCE="${GLAUCOPLASTIC_METIS_MODEL_SOURCE:-$ROOT/models/metis/$MODEL_SLUG}"
MODEL_DEST="$DIST/models/metis/$MODEL_SLUG"

CC="${GLAUCOPLASTIC_WINDOWS_CC:-x86_64-w64-mingw32-gcc}"
OBJDUMP="${GLAUCOPLASTIC_WINDOWS_OBJDUMP:-x86_64-w64-mingw32-objdump}"

log() {
  printf '[windows-build] %s\n' "$*"
}

die() {
  printf '[windows-build:error] %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $1"
}

need python3
need curl
need unzip
need nim
need "$CC"
need file

mkdir -p \
  "$DIST" \
  "$BUILD" \
  "$WHEELHOUSE" \
  "$DOWNLOADS" \
  "$NIMCACHE" \
  "$DIST/models/metis" \
  "$PYROOT" \
  "$SITE"

# Migra o wheelhouse criado manualmente dentro do dist para a área de build.
# Wheels são cache de compilação e não devem duplicar vários GiB no pacote final.
if [[ -d "$DIST/wheelhouse" ]]; then
  log "migrando wheelhouse antigo para $WHEELHOUSE"
  cp -an "$DIST/wheelhouse/." "$WHEELHOUSE/" || true
  rm -rf "$DIST/wheelhouse"
fi

# ---------------------------------------------------------------------------
# Metis checkpoint
# ---------------------------------------------------------------------------

if [[ -L "$MODEL_SOURCE" ]]; then
  RESOLVED_MODEL_SOURCE="$(readlink -f "$MODEL_SOURCE" || true)"
else
  RESOLVED_MODEL_SOURCE="$MODEL_SOURCE"
fi

[[ -n "${RESOLVED_MODEL_SOURCE:-}" ]] || die "symlink do modelo está quebrado: $MODEL_SOURCE"
[[ -f "$RESOLVED_MODEL_SOURCE/config.json" ]] ||
  die "config.json do Metis não encontrado em: $RESOLVED_MODEL_SOURCE"
[[ -f "$RESOLVED_MODEL_SOURCE/model.safetensors.index.json" ]] ||
  die "índice safetensors do Metis não encontrado em: $RESOLVED_MODEL_SOURCE"

if [[ -f "$MODEL_DEST/config.json" &&
      -f "$MODEL_DEST/model.safetensors.index.json" ]]; then
  log "Metis já materializado no dist: $MODEL_DEST"
else
  log "materializando Metis no dist (symlinks serão resolvidos)"
  rm -rf "$MODEL_DEST"
  cp -aL "$MODEL_SOURCE" "$MODEL_DEST"
fi

# ---------------------------------------------------------------------------
# CPython embeddable Windows
# ---------------------------------------------------------------------------

if [[ ! -f "$PYROOT/python.exe" || ! -f "$PYROOT/python${PYTHON_TAG}.dll" ]]; then
  if [[ ! -f "$PYTHON_ZIP" ]]; then
    log "baixando CPython ${PYTHON_VERSION} embeddable para Windows"
    curl -fL "$PYTHON_URL" -o "$PYTHON_ZIP"
  else
    log "reutilizando CPython em cache: $PYTHON_ZIP"
  fi

  log "extraindo CPython Windows"
  unzip -q -o "$PYTHON_ZIP" -d "$PYROOT"
fi

# O probe atual do GlaucoPlastic exige encodings.__file__ como arquivo físico.
# O Python embeddable mantém a stdlib em python310.zip por padrão, então
# materializamos a stdlib em Lib/ e colocamos Lib antes do ZIP no _pth.
if [[ ! -f "$PYROOT/Lib/encodings/__init__.py" ]]; then
  log "materializando stdlib Python em Lib/ para o probe do Metis"
  mkdir -p "$PYROOT/Lib"
  unzip -q -o "$PYROOT/python${PYTHON_TAG}.zip" -d "$PYROOT/Lib"
fi

mkdir -p "$SITE"

cat > "$PYROOT/python${PYTHON_TAG}._pth" <<EOF
Lib
Lib\\site-packages
python${PYTHON_TAG}.zip
.
import site
EOF

# ---------------------------------------------------------------------------
# Wheels Windows
# ---------------------------------------------------------------------------

PIP_TARGET_ARGS=(
  --platform win_amd64
  --python-version "$PYTHON_SERIES"
  --implementation cp
  --abi "cp${PYTHON_TAG}"
  --only-binary=:all:
)

TORCH_REQ='torch==2.5.1+cu118'

# Pacotes que declaram torch/triton como dependência são tratados como
# artefatos fechados. Em cross-build, o pip avalia environment markers usando
# o host Linux em alguns caminhos de resolução; isso faz o metadata do torch
# Windows tentar resolver nvidia-nccl-cu12 para Linux.
NO_DEPS_REQS=(
  'accelerate==1.14.0'
  'bitsandbytes==0.50.0'
  'triton-windows==3.1.0.post17'
  'flash-linear-attention==0.2.2'
)

# Dependências que podem ser resolvidas normalmente para win_amd64 sem
# reintroduzir torch no grafo.
RESOLVED_REQS=(
  'transformers==5.4.0'
  'safetensors==0.8.0'
  'huggingface-hub==1.19.0'
  'tokenizers==0.22.2'
  'numpy==2.2.6'
  'einops==0.8.2'
  'find-libpython==0.5.1'
  'ninja'
  'datasets>=3.3.0'
  'psutil'
  'packaging'
  'pyyaml'
)

log "baixando Torch Windows CUDA 11.8 sem resolver dependências"
python3 -m pip download \
  --dest "$WHEELHOUSE" \
  "${PIP_TARGET_ARGS[@]}" \
  --no-deps \
  --index-url https://download.pytorch.org/whl/cu118 \
  "$TORCH_REQ"

log "baixando pacotes que dependem de torch/triton sem resolver o grafo"
python3 -m pip download \
  --dest "$WHEELHOUSE" \
  "${PIP_TARGET_ARGS[@]}" \
  --no-deps \
  "${NO_DEPS_REQS[@]}"

log "resolvendo dependências Python independentes de torch para Windows"
python3 -m pip download \
  --dest "$WHEELHOUSE" \
  "${PIP_TARGET_ARGS[@]}" \
  "${RESOLVED_REQS[@]}"

# Não execute `pip install --target` durante cross-build: embora o target
# seja win_amd64, o pip host pode comparar o conjunto com pacotes instalados
# no Linux. Baixamos os wheels com pip e fazemos a instalação estrutural aqui.
log "extraindo wheels Windows no Python embutido"

export WHEELHOUSE SITE PYROOT

python3 - <<'PY'
from pathlib import Path
import os
import shutil
import zipfile

wheelhouse = Path(os.environ["WHEELHOUSE"])
site = Path(os.environ["SITE"])
pyroot = Path(os.environ["PYROOT"])

site.mkdir(parents=True, exist_ok=True)
(pyroot / "Scripts").mkdir(parents=True, exist_ok=True)

wheels = sorted(wheelhouse.glob("*.whl"))
if not wheels:
    raise SystemExit("wheelhouse vazio")


def copy_member(zf, info, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zf.open(info) as src, dest.open("wb") as out:
        shutil.copyfileobj(src, out)


for wheel in wheels:
    name = wheel.name.lower()
    if "manylinux" in name or "linux_" in name or "macosx_" in name:
        raise SystemExit(
            "wheel incompatível com target Windows no wheelhouse: " + wheel.name
        )

    print("[windows-build] extract:", wheel.name)

    with zipfile.ZipFile(wheel) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue

            rel = Path(info.filename)
            parts = rel.parts
            data_index = next(
                (i for i, p in enumerate(parts) if p.endswith(".data")),
                None,
            )

            if data_index is None:
                dest = site / rel
            else:
                tail = parts[data_index + 1 :]
                if len(tail) < 2:
                    continue
                scheme = tail[0]
                sub = Path(*tail[1:])

                if scheme in ("purelib", "platlib"):
                    dest = site / sub
                elif scheme == "scripts":
                    dest = pyroot / "Scripts" / sub
                elif scheme == "data":
                    dest = pyroot / sub
                elif scheme == "headers":
                    dest = pyroot / "Include" / sub
                else:
                    continue

            copy_member(zf, info, dest)

print(f"[windows-build] wheels instalados estruturalmente: {len(wheels)}")
PY

# Não permita contaminação acidental com extensões ELF do venv Linux.
SO_COUNT="$(find "$SITE" -type f -name '*.so' | wc -l)"
if [[ "$SO_COUNT" != "0" ]]; then
  find "$SITE" -type f -name '*.so' >&2
  die "foram encontrados $SO_COUNT arquivos .so Linux no runtime Windows"
fi

for required in \
  "$SITE/torch" \
  "$SITE/transformers" \
  "$SITE/accelerate" \
  "$SITE/bitsandbytes" \
  "$SITE/triton" \
  "$SITE/fla" \
  "$SITE/safetensors" \
  "$SITE/tokenizers" \
  "$SITE/numpy"
do
  [[ -e "$required" ]] || die "runtime Python incompleto; ausente: $required"
done

if [[ ! -e "$SITE/find_libpython.py" && ! -e "$SITE/find_libpython" ]]; then
  die "runtime Python incompleto; módulo find_libpython ausente"
fi

[[ -f "$SITE/torch/lib/torch_cuda.dll" ]] ||
  die "Torch Windows sem torch_cuda.dll"
[[ -f "$SITE/torch/lib/cudart64_110.dll" ]] ||
  die "Torch cu118 sem cudart64_110.dll"
[[ -f "$SITE/torch/lib/cublas64_11.dll" ]] ||
  die "Torch cu118 sem cublas64_11.dll"

if find "$SITE" -maxdepth 1 -type d -iname 'nvidia_nccl*' | grep -q .; then
  die "nvidia-nccl foi incluído indevidamente no target Windows"
fi

# ---------------------------------------------------------------------------
# Assets usados pelo assistant_consumer
# ---------------------------------------------------------------------------

mkdir -p "$DIST/tools"

if [[ -f "$ROOT/tools/glaucoplastic_rpa.py" ]]; then
  cp -a "$ROOT/tools/glaucoplastic_rpa.py" "$DIST/tools/"
fi

# Se houver assets nativos Windows já preparados no repositório, copie-os.
if [[ -d "$ROOT/native/windows-x64" ]]; then
  mkdir -p "$DIST/native/windows-x64"
  cp -a "$ROOT/native/windows-x64/." "$DIST/native/windows-x64/"
fi

# ---------------------------------------------------------------------------
# Fonte Windows gerada
# ---------------------------------------------------------------------------

[[ -f "$APP_SOURCE" ]] || die "fonte do aplicativo não encontrada: $APP_SOURCE"

export APP_SOURCE GENERATED_SOURCE MODEL_SLUG
python3 - <<'PY'
import os
from pathlib import Path

source_path = Path(os.environ["APP_SOURCE"])
target_path = Path(os.environ["GENERATED_SOURCE"])
model_slug = os.environ["MODEL_SLUG"]

text = source_path.read_text()

old_root = "let LocalRpaRoot = currentSourcePath().parentDir"
new_root = """let LocalRpaRoot =
  when defined(windows):
    getAppDir()
  else:
    currentSourcePath().parentDir"""

if old_root in text:
    text = text.replace(old_root, new_root, 1)
elif "let LocalRpaRoot =" not in text:
    raise SystemExit(
        "não foi possível localizar LocalRpaRoot em " + str(source_path)
    )

marker = new_root if new_root in text else "let LocalRpaRoot = getAppDir()"

bundle = f"""

when defined(windows):
  let BundledMetisPythonRoot =
    LocalRpaRoot / "runtime" / "metis" / "python"

  putEnv(
    "GLAUCOPLASTIC_METIS_PYTHON",
    BundledMetisPythonRoot / "python.exe"
  )
  putEnv(
    "GLAUCOPLASTIC_METIS_LIBPYTHON",
    BundledMetisPythonRoot / "python310.dll"
  )
  putEnv(
    "GLAUCOPLASTIC_METIS_MODEL_PATH",
    LocalRpaRoot / "models" / "metis" / "{model_slug}"
  )
  putEnv(
    "GLAUCOPLASTIC_RPA_PYTHON",
    BundledMetisPythonRoot / "python.exe"
  )
  putEnv("GLAUCOPLASTIC_METIS_MODE", "embedded")
  putEnv("GLAUCOPLASTIC_METIS_PYTHON_VERSION", "3.10")
  putEnv("GLAUCOPLASTIC_METIS_PREPARE_RUNTIME", "0")
  putEnv("GLAUCOPLASTIC_METIS_AUTO_INSTALL", "0")
  putEnv("GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL", "0")
"""

if "BundledMetisPythonRoot" not in text:
    idx = text.index(marker) + len(marker)
    text = text[:idx] + bundle + text[idx:]

target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_text(text)
print("[windows-build] fonte gerada:", target_path)
PY

# ---------------------------------------------------------------------------
# Cross-compilação Nim -> PE x86-64
# ---------------------------------------------------------------------------

log "cross-compilando assistant_consumer.exe"

NIM_ARGS=(
  c
  --os:windows
  --cpu:amd64
  --cc:gcc
  "--gcc.exe:$CC"
  "--gcc.linkerexe:$CC"
  "--path:$ROOT/src"
  "--nimcache:$NIMCACHE"
  -d:release
  --opt:speed
  --passL:-static-libgcc
  "-o:$EXE"
)

if [[ "${GLAUCOPLASTIC_WINDOWS_GUI_SUBSYSTEM:-0}" == "1" ]]; then
  NIM_ARGS+=(--app:gui)
fi

nim "${NIM_ARGS[@]}" "$GENERATED_SOURCE"

[[ -f "$EXE" ]] || die "o compilador não produziu: $EXE"

FILE_DESC="$(file "$EXE")"
log "$FILE_DESC"
grep -qE 'PE32\+.*x86-64|PE32\+.*Windows' <<<"$FILE_DESC" ||
  die "o artefato não parece ser um executável Windows x64"

# Copia runtimes MinGW somente se o executável efetivamente os importar.
if command -v "$OBJDUMP" >/dev/null 2>&1; then
  IMPORTS="$("$OBJDUMP" -p "$EXE" 2>/dev/null |
    awk '/DLL Name:/ {print $3}' | tr '[:upper:]' '[:lower:]')"

  for dll in libwinpthread-1.dll libgcc_s_seh-1.dll libstdc++-6.dll; do
    if grep -qx "${dll,,}" <<<"$IMPORTS"; then
      candidate="$("$CC" -print-file-name="$dll")"
      if [[ -f "$candidate" ]]; then
        cp -a "$candidate" "$DIST/$dll"
        log "runtime MinGW incluído: $dll"
      else
        die "o executável importa $dll, mas o cross-compiler não o localizou"
      fi
    fi
  done

  log "DLLs importadas pelo executável:"
  "$OBJDUMP" -p "$EXE" 2>/dev/null |
    awk '/DLL Name:/ {print "  " $3}' | sort -u
fi

# ---------------------------------------------------------------------------
# Relatório
# ---------------------------------------------------------------------------

log "build concluído"
printf '\n'
du -sh "$DIST" || true
du -sh "$PYROOT" || true
du -sh "$MODEL_DEST" || true

printf '\n[windows-build] artefatos principais:\n'
printf '  %s\n' "$EXE"
printf '  %s\n' "$PYROOT/python.exe"
printf '  %s\n' "$PYROOT/python${PYTHON_TAG}.dll"
printf '  %s\n' "$MODEL_DEST"

printf '\n[windows-build] observação:\n'
printf '%s\n' \
  '  Este script monta e cross-compila o bundle. O glaucoplastic.nim atual' \
  '  ainda precisa de um backend desktop Windows/WebView2 real no run();' \
  '  sem ele, o target Windows entra no backend foreign mock.'
