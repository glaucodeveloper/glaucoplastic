#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_SLUG="IAAR-Shanghai_Metis-4B"
export GLAUCOPLASTIC_METIS_MODEL_PATH="${GLAUCOPLASTIC_METIS_MODEL_PATH:-$HOME/.local/share/glaucoplastic/models/metis/$MODEL_SLUG}"
export GLAUCOPLASTIC_METIS_VENV="${GLAUCOPLASTIC_METIS_VENV:-$HOME/.venvs/metis-gemma}"
export GLAUCOPLASTIC_METIS_PYTHON="${GLAUCOPLASTIC_METIS_PYTHON:-$GLAUCOPLASTIC_METIS_VENV/bin/python}"

[[ -x "$GLAUCOPLASTIC_METIS_PYTHON" ]] || {
  echo "ERRO: Python Metis ausente: $GLAUCOPLASTIC_METIS_PYTHON" >&2
  return 1 2>/dev/null || exit 1
}

mapfile -t METIS_PYTHON_INFO < <(
  env -u PYTHONHOME -u PYTHONPATH -u PYTHONSTARTUP \
    "$GLAUCOPLASTIC_METIS_PYTHON" - <<'PY'
import os
import site
import sys
import sysconfig

base_prefix = os.path.realpath(sys.base_prefix)
stdlib = os.path.realpath(sysconfig.get_path("stdlib") or "")
platstdlib = os.path.realpath(sysconfig.get_path("platstdlib") or "")
dynload = os.path.join(platstdlib or stdlib, "lib-dynload")

site_paths = []
for value in site.getsitepackages():
    value = os.path.realpath(value)
    if value and value not in site_paths:
        site_paths.append(value)

library = ""
libdir = sysconfig.get_config_var("LIBDIR") or ""
for name in (
    sysconfig.get_config_var("INSTSONAME"),
    sysconfig.get_config_var("LDLIBRARY"),
):
    if name:
        candidate = os.path.realpath(os.path.join(libdir, name))
        if os.path.isfile(candidate):
            library = candidate
            break

if not library:
    try:
        import find_libpython
        candidate = find_libpython.find_libpython()
        if candidate and os.path.isfile(candidate):
            library = os.path.realpath(candidate)
    except Exception:
        pass

print(base_prefix)
print(stdlib)
print(platstdlib)
print(dynload)
print(os.pathsep.join(site_paths))
print(library)
PY
)

[[ "${#METIS_PYTHON_INFO[@]}" -ge 6 ]] || {
  echo "ERRO: probe incompleto do Python Metis." >&2
  return 1 2>/dev/null || exit 1
}

METIS_BASE_PREFIX="${METIS_PYTHON_INFO[0]}"
METIS_STDLIB="${METIS_PYTHON_INFO[1]}"
METIS_PLATSTDLIB="${METIS_PYTHON_INFO[2]}"
METIS_DYNLOAD="${METIS_PYTHON_INFO[3]}"
METIS_SITE_PATHS="${METIS_PYTHON_INFO[4]}"
METIS_LIBPYTHON="${METIS_PYTHON_INFO[5]}"

[[ -f "$METIS_STDLIB/encodings/__init__.py" ]] || {
  echo "ERRO: encodings não encontrado em $METIS_STDLIB" >&2
  return 1 2>/dev/null || exit 1
}

[[ -f "$METIS_LIBPYTHON" ]] || {
  echo "ERRO: libpython não encontrada: $METIS_LIBPYTHON" >&2
  return 1 2>/dev/null || exit 1
}

python_path_parts=()
for value in "$METIS_STDLIB" "$METIS_PLATSTDLIB" "$METIS_DYNLOAD"; do
  [[ -n "$value" && -d "$value" ]] && python_path_parts+=("$value")
done
[[ -n "$METIS_SITE_PATHS" ]] && python_path_parts+=("$METIS_SITE_PATHS")

METIS_PYTHONPATH="$(IFS=:; printf '%s' "${python_path_parts[*]}")"

export PYTHONHOME="$METIS_BASE_PREFIX"
export PYTHONPATH="$METIS_PYTHONPATH"
export PYTHONNOUSERSITE=1
unset PYTHONSTARTUP

export GLAUCOPLASTIC_METIS_PYTHONHOME="$METIS_BASE_PREFIX"
export GLAUCOPLASTIC_METIS_PYTHONPATH="$METIS_PYTHONPATH"
export GLAUCOPLASTIC_METIS_LIBPYTHON="$METIS_LIBPYTHON"
export GLAUCOPLASTIC_METIS_AUTO_DOWNLOAD=0
export GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL=0

METIS_LIBDIR="$(dirname -- "$METIS_LIBPYTHON")"
export LD_LIBRARY_PATH="$METIS_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
