#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


class BuildError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[GlaucoPlastic] {message}")


def fail(message: str) -> "NoReturn":
    raise BuildError(message)


def env_path(name: str) -> Path | None:
    value = os.environ.get(name, "").strip()
    if not value:
        return None
    return Path(value).expanduser().resolve()


def existing_file(candidates: Iterable[Path | None]) -> Path | None:
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate.resolve()
    return None


def existing_dir(candidates: Iterable[Path | None]) -> Path | None:
    for candidate in candidates:
        if candidate is not None and candidate.is_dir():
            return candidate.resolve()
    return None


def host_target() -> str:
    machine = platform.machine().lower()
    is_x64 = machine in {"x86_64", "amd64"}
    if not is_x64:
        fail(f"Arquitetura ainda não suportada pelo empacotador: {machine}")
    if os.name == "nt":
        return "windows-x64"
    if sys.platform.startswith("linux"):
        return "linux-x64"
    fail(f"Plataforma ainda não suportada: {sys.platform}")


def target_executable(application: str, target: str) -> str:
    return application + (".exe" if target.startswith("windows") else "")


def load_config(project: Path) -> dict:
    path = project / "glaucoplastic.build.json"
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        fail(f"Configuração inválida em {path}: {error}")
    if not isinstance(value, dict):
        fail(f"A raiz de {path} precisa ser um objeto JSON.")
    return value


def config_path(project: Path, config: dict, dotted: str) -> Path | None:
    current = config
    for part in dotted.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    if not isinstance(current, str) or not current.strip():
        return None
    value = Path(os.path.expandvars(current)).expanduser()
    if not value.is_absolute():
        value = project / value
    return value.resolve()


def locate_model(project: Path, config: dict, explicit: str | None) -> Path:
    explicit_path = Path(explicit).expanduser().resolve() if explicit else None
    home = Path.home()
    candidates = [
        explicit_path,
        env_path("GLAUCOPLASTIC_MODEL_PATH"),
        config_path(project, config, "model.source"),
        home / "models" / "gemma-4-E4B-it-Q4_K_M.gguf",
        home / "models" / "Qwen3-4B" / "Qwen3-4B-Q4_K_M.gguf",
        project / "models" / "gemma-4-E4B-it-Q4_K_M.gguf",
        project / "models" / "Qwen3-4B-Q4_K_M.gguf",
    ]
    found = existing_file(candidates)
    if found is None:
        rendered = "\n- ".join(str(item) for item in candidates if item)
        fail(
            "Modelo GGUF não encontrado. Defina GLAUCOPLASTIC_MODEL_PATH "
            "ou model.source em glaucoplastic.build.json.\n- " + rendered
        )
    return found


def locate_llama_binary(
    project: Path,
    config: dict,
    target: str,
    explicit: str | None,
) -> Path:
    explicit_path = Path(explicit).expanduser().resolve() if explicit else None
    executable = "llama-server.exe" if target.startswith("windows") else "llama-server"
    platform_dir = "windows-x64" if target.startswith("windows") else "linux-x64"
    home = Path.home()
    candidates = [
        explicit_path,
        env_path("GLAUCOPLASTIC_LLAMA_BIN"),
        config_path(project, config, f"llama.{target}.executable"),
        project / "runtime" / "llama" / platform_dir / "bin" / executable,
        project / "runtime" / "llama" / platform_dir / executable,
        home / ".local" / "llama.cpp" / executable,
        home / ".local" / "src" / "llama.cpp" / "build-cuda" / "bin" / executable,
        home / ".local" / "src" / "llama.cpp" / "build" / "bin" / executable,
    ]
    found = existing_file(candidates)
    if found is None:
        rendered = "\n- ".join(str(item) for item in candidates if item)
        fail(
            f"{executable} não encontrado para {target}. Defina "
            "GLAUCOPLASTIC_LLAMA_BIN ou llama.<target>.executable.\n- " + rendered
        )
    return found


def infer_llama_root(
    project: Path,
    config: dict,
    target: str,
    binary: Path,
    explicit_root: str | None,
) -> Path:
    configured = (
        Path(explicit_root).expanduser().resolve()
        if explicit_root
        else env_path("GLAUCOPLASTIC_LLAMA_RUNTIME_ROOT")
    )
    candidates = [
        configured,
        config_path(project, config, f"llama.{target}.runtimeRoot"),
    ]
    root = existing_dir(candidates)
    if root:
        return root

    parent = binary.parent
    if parent.name.lower() == "bin":
        return parent.parent

    # Builds usuais do llama.cpp: build/bin/llama-server.
    for ancestor in [parent, *parent.parents]:
        if ancestor.name in {"build", "build-cuda", "build-vulkan"}:
            return ancestor

    return parent


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    try:
        destination.chmod(destination.stat().st_mode | stat.S_IXUSR)
    except OSError:
        pass


def copy_tree(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(
        source,
        destination,
        symlinks=False,
        copy_function=shutil.copy2,
        ignore=shutil.ignore_patterns(
            "*.o", "*.obj", "*.a", "*.lib", "*.pdb",
            "CMakeFiles", "CMakeCache.txt", "cmake_install.cmake",
            "Makefile", "*.cmake", ".git", "tests", "examples",
        ),
    )


def ensure_llama_layout(
    runtime_root: Path,
    binary: Path,
    bundle: Path,
    target: str,
) -> Path:
    platform_dir = "windows-x64" if target.startswith("windows") else "linux-x64"
    destination = bundle / "runtime" / "llama" / platform_dir
    copy_tree(runtime_root, destination)

    executable_name = "llama-server.exe" if target.startswith("windows") else "llama-server"
    expected = destination / "bin" / executable_name
    if expected.is_file():
        return expected

    relative_binary: Path | None = None
    try:
        relative_binary = binary.relative_to(runtime_root)
    except ValueError:
        pass

    if relative_binary is not None:
        copied = destination / relative_binary
        if copied.is_file():
            expected.parent.mkdir(parents=True, exist_ok=True)
            if copied.resolve() != expected.resolve():
                copy_file(copied, expected)
            return expected

    expected.parent.mkdir(parents=True, exist_ok=True)
    copy_file(binary, expected)

    # Quando o binário veio de uma pasta isolada, copie bibliotecas vizinhas.
    for pattern in ("*.dll", "*.so", "*.so.*", "*.dylib"):
        for library in binary.parent.glob(pattern):
            if library.is_file():
                copy_file(library, expected.parent / library.name)

    return expected


def project_asset_entries(project: Path, config: dict) -> list[tuple[Path, Path]]:
    defaults = [
        ("tools", "tools"),
        ("okf", "okf"),
        ("assets", "assets"),
        (".runtime/whisper.cpp", "runtime/whisper.cpp"),
    ]
    configured = config.get("assets", [])
    entries: list[tuple[Path, Path]] = []

    raw_entries = configured if isinstance(configured, list) else []
    for item in [*defaults, *raw_entries]:
        if isinstance(item, (list, tuple)) and len(item) == 2:
            source_text, destination_text = str(item[0]), str(item[1])
        elif isinstance(item, dict):
            source_text = str(item.get("source", ""))
            destination_text = str(item.get("destination", source_text))
        else:
            continue
        if not source_text:
            continue
        source = (project / source_text).resolve()
        destination = Path(destination_text)
        entries.append((source, destination))
    return entries


def copy_project_assets(project: Path, config: dict, bundle: Path) -> None:
    copied_destinations: set[str] = set()
    for source, relative_destination in project_asset_entries(project, config):
        key = relative_destination.as_posix()
        if key in copied_destinations or not source.exists():
            continue
        copied_destinations.add(key)
        destination = bundle / relative_destination
        if source.is_dir():
            copy_tree(source, destination)
        else:
            copy_file(source, destination)


def nim_command() -> str:
    configured = os.environ.get("NIM", "").strip()
    if configured:
        return configured
    found = shutil.which("nim")
    if not found:
        fail("Compilador Nim não encontrado no PATH.")
    return found


def compile_application(
    repo: Path,
    project: Path,
    application: str,
    target: str,
    mode: str,
    output: Path,
) -> None:
    source = project / f"{application}.nim"
    if not source.is_file():
        fail(f"Fonte da aplicação não encontrado: {source}")

    output.parent.mkdir(parents=True, exist_ok=True)
    nimcache = project / "nimcache" / mode / target
    nimcache.mkdir(parents=True, exist_ok=True)

    command = [
        nim_command(),
        "c",
        "--threads:on",
        "--mm:orc",
        f"--path:{repo / 'src'}",
        f"--nimcache:{nimcache}",
        f"--out:{output}",
    ]

    if mode == "dev":
        command += ["-d:debug"]
    else:
        command += ["-d:release", "--opt:speed"]

    host = host_target()
    if target != host:
        if target == "windows-x64":
            command += ["--os:windows", "--cpu:amd64", "-d:mingw"]
        elif target == "linux-x64":
            command += ["--os:linux", "--cpu:amd64"]
        else:
            fail(f"Target desconhecido: {target}")

    command.append(str(source))
    log("Compilando: " + " ".join(command))
    completed = subprocess.run(command, cwd=project)
    if completed.returncode != 0:
        fail(f"Compilação falhou com código {completed.returncode}.")
    if not output.is_file():
        fail(f"O compilador terminou sem produzir: {output}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def manifest_files(bundle: Path) -> list[dict]:
    entries: list[dict] = []
    for path in sorted(item for item in bundle.rglob("*") if item.is_file()):
        relative = path.relative_to(bundle).as_posix()
        entries.append({
            "path": relative,
            "size": path.stat().st_size,
            "sha256": sha256(path),
        })
    return entries


def write_manifest(
    bundle: Path,
    application: str,
    target: str,
    model: Path,
    llama_binary: Path,
) -> Path:
    manifest = {
        "schema": "glaucoplastic.bundle.v1",
        "application": application,
        "target": target,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "model": {
            "sourceName": model.name,
            "bundlePath": f"models/{model.name}",
            "size": model.stat().st_size,
            "sha256": sha256(bundle / "models" / model.name),
        },
        "llama": {
            "bundlePath": llama_binary.relative_to(bundle).as_posix(),
            "sha256": sha256(llama_binary),
        },
        "files": manifest_files(bundle),
    }
    path = bundle / "manifest.json"
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def archive_bundle(bundle: Path, target: str) -> Path:
    if target.startswith("windows"):
        archive = bundle.parent / f"{bundle.name}.zip"
        if archive.exists():
            archive.unlink()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as handle:
            for path in sorted(item for item in bundle.rglob("*") if item.is_file()):
                handle.write(path, Path(bundle.name) / path.relative_to(bundle))
        return archive

    archive = bundle.parent / f"{bundle.name}.tar.gz"
    if archive.exists():
        archive.unlink()
    with tarfile.open(archive, "w:gz") as handle:
        handle.add(bundle, arcname=bundle.name)
    return archive


def verify_bundle(bundle: Path) -> None:
    manifest_path = bundle / "manifest.json"
    if not manifest_path.is_file():
        fail(f"Manifesto inexistente: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    failures: list[str] = []
    for entry in manifest.get("files", []):
        relative = entry.get("path", "")
        if relative == "manifest.json":
            continue
        path = bundle / relative
        if not path.is_file():
            failures.append(f"ausente: {relative}")
            continue
        if path.stat().st_size != entry.get("size"):
            failures.append(f"tamanho divergente: {relative}")
            continue
        if sha256(path) != entry.get("sha256"):
            failures.append(f"hash divergente: {relative}")
    if failures:
        fail("Bundle inválido:\n- " + "\n- ".join(failures))
    log(f"Bundle verificado: {bundle}")


def command_dev(args: argparse.Namespace, repo: Path, project: Path, config: dict) -> None:
    application = args.application or str(config.get("application", "assistant_consumer"))
    target = host_target()
    output = project / "bin" / target_executable(application, target)
    compile_application(repo, project, application, target, "dev", output)
    log(f"Build de desenvolvimento concluído: {output}")
    log("Modelo e llama-server não foram copiados.")


def command_build(
    args: argparse.Namespace,
    repo: Path,
    project: Path,
    config: dict,
    compile_first: bool,
) -> None:
    application = args.application or str(config.get("application", "assistant_consumer"))
    target = host_target() if args.target == "auto" else args.target
    output_root = (
        Path(args.output).expanduser().resolve()
        if args.output
        else project / str(config.get("output", "dist"))
    )
    bundle_name = f"{application}-{target}"
    bundle = output_root / bundle_name
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True, exist_ok=True)

    executable = bundle / target_executable(application, target)
    if compile_first:
        compile_application(repo, project, application, target, "release", executable)
    else:
        existing = project / "bin" / target_executable(application, target)
        if not existing.is_file():
            fail(f"Binário para empacotar não encontrado: {existing}")
        copy_file(existing, executable)

    model = locate_model(project, config, args.model)
    model_destination = bundle / "models" / model.name
    copy_file(model, model_destination)
    log(f"Modelo incluído: {model_destination}")

    llama_source = locate_llama_binary(
        project,
        config,
        target,
        args.llama_bin,
    )
    llama_root = infer_llama_root(
        project,
        config,
        target,
        llama_source,
        args.llama_runtime,
    )
    bundled_llama = ensure_llama_layout(
        llama_root,
        llama_source,
        bundle,
        target,
    )
    log(f"Runtime llama.cpp incluído: {bundled_llama}")

    copy_project_assets(project, config, bundle)
    manifest = write_manifest(
        bundle,
        application,
        target,
        model,
        bundled_llama,
    )
    log(f"Manifesto gerado: {manifest}")
    verify_bundle(bundle)

    no_archive = args.no_archive or os.environ.get(
        "GLAUCOPLASTIC_BUILD_NO_ARCHIVE", ""
    ).lower() in {"1", "true", "yes", "on"}
    if not no_archive:
        archive = archive_bundle(bundle, target)
        log(f"Arquivo de distribuição: {archive}")

    log(f"Distribuição completa: {bundle}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="glaucoplastic-build",
        description=(
            "Compilação de desenvolvimento e distribuição autocontida "
            "de aplicações GlaucoPlastic."
        ),
    )
    parser.add_argument(
        "command",
        choices=["dev", "build", "package", "verify"],
    )
    parser.add_argument("--project", default=os.getcwd())
    parser.add_argument("--application")
    parser.add_argument(
        "--target",
        choices=["auto", "linux-x64", "windows-x64"],
        default="auto",
    )
    parser.add_argument("--output")
    parser.add_argument("--model")
    parser.add_argument("--llama-bin")
    parser.add_argument("--llama-runtime")
    parser.add_argument("--no-archive", action="store_true")
    parser.add_argument("--bundle")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project = Path(args.project).expanduser().resolve()
    if not project.is_dir():
        fail(f"Projeto inexistente: {project}")

    repo = Path(__file__).resolve().parents[1]
    core = repo / "src" / "glaucoplastic.nim"
    if not core.is_file():
        fail(f"O empacotador não está dentro de um checkout GlaucoPlastic: {repo}")

    config = load_config(project)

    if args.command == "dev":
        command_dev(args, repo, project, config)
    elif args.command == "build":
        command_build(args, repo, project, config, compile_first=True)
    elif args.command == "package":
        command_build(args, repo, project, config, compile_first=False)
    elif args.command == "verify":
        bundle = (
            Path(args.bundle).expanduser().resolve()
            if args.bundle
            else project / str(config.get("output", "dist")) /
                f"{args.application or config.get('application', 'assistant_consumer')}-"
                f"{host_target() if args.target == 'auto' else args.target}"
        )
        verify_bundle(bundle)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as error:
        print(f"[GlaucoPlastic] ERRO: {error}", file=sys.stderr)
        raise SystemExit(1)
