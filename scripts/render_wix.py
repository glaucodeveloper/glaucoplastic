#!/usr/bin/env python3
from __future__ import annotations

import glob
import json
import os
import shutil
import sys
import uuid
from collections import defaultdict
from pathlib import Path
from xml.sax.saxutils import quoteattr

if len(sys.argv) != 5:
    raise SystemExit(
        "uso: render_wix.py <project> <stage> <manifest.json> <output.wxs>"
    )

project = Path(sys.argv[1]).resolve()
stage = Path(sys.argv[2]).resolve()
manifest_path = Path(sys.argv[3]).resolve()
wxs_path = Path(sys.argv[4]).resolve()
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))


def copy_declared_assets() -> None:
    for asset in manifest.get("assets", []):
        kind = asset["kind"]
        source_text = asset["source"]
        expanded_source = Path(os.path.expandvars(source_text)).expanduser()
        source_pattern = (
            expanded_source
            if expanded_source.is_absolute()
            else project / expanded_source
        )
        destination_text = asset.get("destination", "")
        destination = stage / destination_text

        if kind == "file":
            if not source_pattern.is_file():
                raise SystemExit(f"Asset ausente: {source_pattern}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_pattern, destination)
            continue

        if kind == "glob":
            matches = [
                Path(value)
                for value in sorted(glob.glob(str(source_pattern)))
                if Path(value).is_file()
            ]
            if not matches:
                raise SystemExit(f"Glob sem arquivos: {source_pattern}")
            destination.mkdir(parents=True, exist_ok=True)
            for item in matches:
                shutil.copy2(item, destination / item.name)
            continue

        if kind == "tree":
            if not source_pattern.is_dir():
                raise SystemExit(f"Diretório de asset ausente: {source_pattern}")
            for item in sorted(source_pattern.rglob("*")):
                if not item.is_file():
                    continue
                relative = item.relative_to(source_pattern)
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
            continue

        raise SystemExit(f"Tipo de asset desconhecido: {kind}")


copy_declared_assets()

upgrade = uuid.UUID(manifest["upgrade_code"])


def sid(prefix: str, value: str) -> str:
    return f"{prefix}_{uuid.uuid5(upgrade, value).hex[:24].upper()}"


def guid(value: str) -> str:
    return str(uuid.uuid5(upgrade, value)).upper()


def normalized_parts(value: str) -> tuple[str, ...]:
    return tuple(part for part in Path(value).parts if part not in ("", "."))


def build_tree(paths: list[tuple[str, ...]]) -> dict[tuple[str, ...], set[tuple[str, ...]]]:
    tree: dict[tuple[str, ...], set[tuple[str, ...]]] = defaultdict(set)
    for parts in paths:
        parent: tuple[str, ...] = ()
        for part in parts:
            child = parent + (part,)
            tree[parent].add(child)
            parent = child
    return tree


def emit_directory_tree(
    tree: dict[tuple[str, ...], set[tuple[str, ...]]],
    id_prefix: str,
    parent: tuple[str, ...] = (),
    indent: str = "",
) -> list[str]:
    lines: list[str] = []
    for child in sorted(tree.get(parent, set())):
        path_text = "/".join(child)
        directory_id = sid(id_prefix, path_text)
        lines.append(
            f"{indent}<Directory Id={quoteattr(directory_id)} "
            f"Name={quoteattr(child[-1])}>"
        )
        lines.extend(
            emit_directory_tree(tree, id_prefix, child, indent + "  ")
        )
        lines.append(f"{indent}</Directory>")
    return lines


files = sorted(path for path in stage.rglob("*") if path.is_file())
if not files:
    raise SystemExit(f"Stage vazio: {stage}")

file_directories = sorted(
    {
        tuple(path.relative_to(stage).parent.parts)
        for path in files
        if path.relative_to(stage).parent != Path(".")
    }
)
install_tree = build_tree(file_directories)

install_directory_ids: dict[tuple[str, ...], str] = {(): "INSTALLFOLDER"}
for directory in file_directories:
    parent: tuple[str, ...] = ()
    for part in directory:
        parent = parent + (part,)
        install_directory_ids[parent] = sid("INSTALLDIR", "/".join(parent))

components_by_directory: dict[str, list[str]] = defaultdict(list)
component_refs: list[str] = []

for path in files:
    relative = path.relative_to(stage)
    relative_text = relative.as_posix()
    directory_key = tuple(relative.parent.parts) if relative.parent != Path(".") else ()
    directory_id = install_directory_ids[directory_key]
    component_id = sid("CMP", f"file:{relative_text}")
    file_id = sid("FIL", relative_text)
    component_refs.append(component_id)
    components_by_directory[directory_id].extend(
        [
            f"<Component Id={quoteattr(component_id)} Guid={quoteattr(guid('file:' + relative_text))}>",
            f"  <File Id={quoteattr(file_id)} Source={quoteattr(str(path))} KeyPath=\"yes\" />",
            "</Component>",
        ]
    )

scope = manifest.get("scope", "perUser")
per_user = scope == "perUser"
install_scope = "perUser" if per_user else "perMachine"
install_root = "LocalAppDataFolder" if per_user else "ProgramFiles64Folder"
data_root_value = manifest["application_data"].get(
    "root", "localAppData" if per_user else "commonAppData"
)
data_root = "LocalAppDataFolder" if data_root_value == "localAppData" else "CommonAppDataFolder"
registry_root = "HKCU" if per_user else "HKLM"

install_relative_path = manifest["install_directory"]["path"]
data_relative_path = manifest["application_data"]["path"]

# A raiz de instalação pode conter subpastas declaradas em `path`.
install_path_parts = normalized_parts(install_relative_path)
if not install_path_parts:
    raise SystemExit("install_directory.path vazio")

data_path_parts = normalized_parts(data_relative_path)
if not data_path_parts:
    raise SystemExit("application_data.path vazio")

# Diretórios de dados aninhados, incluindo okf/<espaco>.
data_directories = [
    normalized_parts(value)
    for value in manifest["application_data"].get("directories", [])
]
data_tree = build_tree(data_directories)
data_directory_ids: dict[tuple[str, ...], str] = {(): "APPDATAROOT"}
for directory in data_directories:
    parent: tuple[str, ...] = ()
    for part in directory:
        parent = parent + (part,)
        data_directory_ids[parent] = sid("DATADIR", "/".join(parent))


def emit_path_chain(
    parts: tuple[str, ...],
    final_id: str,
    indent: str,
    prefix: str,
    nested_content: list[str] | None = None,
) -> list[str]:
    lines: list[str] = []
    for index, part in enumerate(parts):
        is_final = index == len(parts) - 1
        directory_id = final_id if is_final else sid(prefix, "/".join(parts[: index + 1]))
        lines.append(
            f"{indent}<Directory Id={quoteattr(directory_id)} Name={quoteattr(part)}>"
        )
        indent += "  "
    if nested_content:
        lines.extend(f"{indent}{line}" for line in nested_content)
    for _ in parts:
        indent = indent[:-2]
        lines.append(f"{indent}</Directory>")
    return lines


install_subtree = emit_directory_tree(
    install_tree,
    "INSTALLDIR",
    (),
    "",
)
install_path_xml = emit_path_chain(
    install_path_parts,
    "INSTALLFOLDER",
    "        ",
    "INSTALLPATH",
    install_subtree,
)

data_subtree = emit_directory_tree(
    data_tree,
    "DATADIR",
    (),
    "",
)
data_path_xml = emit_path_chain(
    data_path_parts,
    "APPDATAROOT",
    "        ",
    "DATAPATH",
    data_subtree,
)

# Um componente por diretório de dados garante que diretórios vazios existam.
data_component_blocks: list[str] = []
for directory in sorted(data_directory_ids):
    if not directory:
        continue
    path_text = "/".join(directory)
    directory_id = data_directory_ids[directory]
    component_id = sid("CMP", f"data-dir:{path_text}")
    component_refs.append(component_id)
    registry_key = (
        "Software\\"
        + manifest["manufacturer"]
        + "\\"
        + manifest["product_name"]
        + "\\DataDirectories"
    )
    data_component_blocks.extend(
        [
            f"<DirectoryRef Id={quoteattr(directory_id)}>",
            f"  <Component Id={quoteattr(component_id)} Guid={quoteattr(guid('data-dir:' + path_text))}>",
            "    <CreateFolder />",
            f"    <RegistryValue Root={quoteattr(registry_root)} Key={quoteattr(registry_key)} "
            f"Name={quoteattr(path_text)} Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />",
            "  </Component>",
            "</DirectoryRef>",
        ]
    )

# Atalhos opcionais.
shortcut_blocks: list[str] = []
executable = manifest["executable"]
shortcuts = manifest.get("shortcuts", {})
software_key = (
    "Software\\"
    + manifest["manufacturer"]
    + "\\"
    + manifest["product_name"]
)

if shortcuts.get("start_menu", False):
    component_id = sid("CMP", "shortcut:start-menu")
    component_refs.append(component_id)
    shortcut_blocks.extend(
        [
            '<DirectoryRef Id="ApplicationProgramsFolder">',
            f"  <Component Id={quoteattr(component_id)} Guid={quoteattr(guid('shortcut:start-menu'))}>",
            f"    <Shortcut Id=\"StartMenuShortcut\" Name={quoteattr(manifest['product_name'])} "
            f"Target={quoteattr('[INSTALLFOLDER]' + executable)} WorkingDirectory=\"INSTALLFOLDER\" />",
            '    <RemoveFolder Id="RemoveApplicationProgramsFolder" On="uninstall" />',
            f"    <RegistryValue Root={quoteattr(registry_root)} Key={quoteattr(software_key)} "
            'Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />',
            "  </Component>",
            "</DirectoryRef>",
        ]
    )

if shortcuts.get("desktop", False):
    component_id = sid("CMP", "shortcut:desktop")
    component_refs.append(component_id)
    shortcut_blocks.extend(
        [
            '<DirectoryRef Id="DesktopFolder">',
            f"  <Component Id={quoteattr(component_id)} Guid={quoteattr(guid('shortcut:desktop'))}>",
            f"    <Shortcut Id=\"DesktopShortcut\" Name={quoteattr(manifest['product_name'])} "
            f"Target={quoteattr('[INSTALLFOLDER]' + executable)} WorkingDirectory=\"INSTALLFOLDER\" />",
            f"    <RegistryValue Root={quoteattr(registry_root)} Key={quoteattr(software_key)} "
            'Name="DesktopShortcut" Type="integer" Value="1" KeyPath="yes" />',
            "  </Component>",
            "</DirectoryRef>",
        ]
    )

download_page = manifest.get("installer_download", {})
download_ui: list[str] = []
if download_page.get("enabled", False):
    page_title = quoteattr(str(download_page.get("title", "Preparar recursos locais")))
    page_description = quoteattr(str(download_page.get("description", "Baixe os recursos necessários durante a instalação.")))
    runtime_checked = "1" if download_page.get("runtime", True) else ""
    model_checked = "1" if download_page.get("model", True) else ""
    download_ui = [
        '    <Property Id="GLAUCO_DOWNLOAD_RUNTIME" Value=' + quoteattr(runtime_checked) + ' />',
        '    <Property Id="GLAUCO_DOWNLOAD_MODEL" Value=' + quoteattr(model_checked) + ' />',
        '    <Property Id="GLAUCO_DOWNLOAD_BACKEND" Value=' + quoteattr(str(download_page.get("backend", "auto"))) + ' />',
        '    <UIRef Id="WixUI_InstallDir" />',
        '    <UI>',
        '      <Dialog Id="GlaucoDownloadDlg" Width="370" Height="270" Title="[ProductName]">',
        f'        <Control Id="Title" Type="Text" X="15" Y="15" Width="340" Height="25" Transparent="yes" NoPrefix="yes" Text={page_title} />',
        f'        <Control Id="Description" Type="Text" X="20" Y="55" Width="330" Height="45" Transparent="yes" NoPrefix="yes" Text={page_description} />',
        '        <Control Id="Runtime" Type="CheckBox" X="20" Y="120" Width="320" Height="18" Property="GLAUCO_DOWNLOAD_RUNTIME" CheckBoxValue="1" Text="Preparar runtime gráfico automaticamente" />',
        '        <Control Id="Model" Type="CheckBox" X="20" Y="145" Width="320" Height="18" Property="GLAUCO_DOWNLOAD_MODEL" CheckBoxValue="1" Text="Preparar o modelo local automaticamente" />',
        '        <Control Id="Back" Type="PushButton" X="180" Y="243" Width="56" Height="17" Text="Voltar"><Publish Event="NewDialog" Value="InstallDirDlg">1</Publish></Control>',
        '        <Control Id="Next" Type="PushButton" X="240" Y="243" Width="56" Height="17" Default="yes" Text="Continuar"><Publish Event="NewDialog" Value="VerifyReadyDlg">1</Publish></Control>',
        '        <Control Id="Cancel" Type="PushButton" X="304" Y="243" Width="56" Height="17" Cancel="yes" Text="Cancelar"><Publish Event="SpawnDialog" Value="CancelDlg">1</Publish></Control>',
        '      </Dialog>',
        '      <Publish Dialog="InstallDirDlg" Control="Next" Event="NewDialog" Value="GlaucoDownloadDlg">1</Publish>',
        '    </UI>',
    ]

lines: list[str] = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">',
    f"  <Product Id=\"*\" Name={quoteattr(manifest['product_name'])} Language=\"1046\" "
    f"Version={quoteattr(manifest['version'])} Manufacturer={quoteattr(manifest['manufacturer'])} "
    f"UpgradeCode={quoteattr(manifest['upgrade_code'])}>",
    f'    <Package InstallerVersion="500" Compressed="yes" InstallScope="{install_scope}" />',
    '    <MajorUpgrade DowngradeErrorMessage="Uma versão mais recente já está instalada." />',
    '    <MediaTemplate EmbedCab="yes" />',
    '    <Directory Id="TARGETDIR" Name="SourceDir">',
    f"      <Directory Id={quoteattr(install_root)}>",
]
lines.extend(download_ui)
lines.extend(install_path_xml)
lines.extend(
    [
        "      </Directory>",
        f"      <Directory Id={quoteattr(data_root)}>",
    ]
)
lines.extend(data_path_xml)
lines.extend(
    [
        "      </Directory>",
        '      <Directory Id="DesktopFolder" />',
        '      <Directory Id="ProgramMenuFolder">',
        f"        <Directory Id=\"ApplicationProgramsFolder\" Name={quoteattr(manifest['product_name'])} />",
        "      </Directory>",
        "    </Directory>",
    ]
)

for directory_id in sorted(components_by_directory):
    lines.append(f"    <DirectoryRef Id={quoteattr(directory_id)}>")
    for component_line in components_by_directory[directory_id]:
        lines.append("      " + component_line)
    lines.append("    </DirectoryRef>")

for block_line in data_component_blocks:
    lines.append("    " + block_line)
for block_line in shortcut_blocks:
    lines.append("    " + block_line)

lines.append('    <Feature Id="MainFeature" Title="Aplicação" Level="1">')
for component_id in component_refs:
    lines.append(f"      <ComponentRef Id={quoteattr(component_id)} />")
lines.extend(
    [
        "    </Feature>",
        "  </Product>",
        "</Wix>",
    ]
)

wxs_path.parent.mkdir(parents=True, exist_ok=True)
wxs_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"WiX gerado: {wxs_path}")
