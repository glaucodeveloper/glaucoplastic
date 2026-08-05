# GlaucoPlastic

## Especificação consolidada para implementação — revisão 2

**Data:** 31 de julho de 2026  
**Arquivo principal do framework:** `glaucoplastic.nim`  
**Arquivo da aplicação:** `src/app.nim`

---

## 1. Definição

GlaucoPlastic é um framework monolítico em Nim para declarar uma aplicação completa dentro de uma única macro. A declaração reúne produto, instalação, ORM, componentes, estados reativos, renderização WebView, elementos nativos `foreign`, agentes RLM, memória Git e espaços OKF.

A aplicação descreve o produto. O arquivo `glaucoplastic.nim` contém o parser, os planos intermediários, a validação, a geração de código e os runtimes necessários.

```nim
import glaucoplastic

let macroObras* = glaucoplastic MacroObras:
  # declaração integral da aplicação

proc runMacroObras*() =
  macroObras.run()

when isMainModule:
  runMacroObras()
```

A única macro pública do framework é:

```nim
macro glaucoplastic*(
  applicationName: untyped,
  body: untyped
): untyped
```

O corpo é `untyped` para que nomes de entidades, estados, componentes, agentes, eventos, tags HTML e propriedades visuais sejam interpretados pela DSL antes da resolução semântica comum do Nim.

---

## 2. Decisões fundamentais

1. O framework reside em um único arquivo `glaucoplastic.nim`.
2. A macro interpreta toda a aplicação.
3. O macro executa no compile time e gera o runtime.
4. ORM, frontend, estados, agentes, RLM, memória Git, OKF, servidor interno e elementos `foreign` pertencem ao mesmo framework monolítico.
5. Toda declaração dentro de `agents:` constrói um agente RLM local.
6. Todo agente possui memória Git e capacidades OKF.
7. O `llama-server`, suas bibliotecas e o modelo GGUF são distribuídos junto da aplicação.
8. O namespace persistente é `orm.<Entidade>.<operação>`.
9. O namespace reativo é `states.<Estado>`.
10. Componentes formam namespaces visuais navegáveis.
11. `render:` pode aparecer em qualquer corpo de efeito.
12. Não existe seção `selectors:`.
13. `selector()` e `selectors()` são consultas DOM temporárias.
14. `foreign(...)` é um elemento visual nativo da DSL, implementado como `WebContentsView`, configurado por URL e integrado à árvore de renderização.
15. O MSI é configurado na declaração da aplicação.
16. O MSI cria os diretórios de dados, incluindo a pasta OKF.
17. O framework em runtime apenas valida e utiliza os diretórios instalados; ele não cria a pasta OKF.
18. O código-fonte da aplicação expõe uma `proc` própria para execução.

---

## 3. Unidade monolítica do framework

O arquivo único pode ser organizado internamente por seções:

```text
glaucoplastic.nim
├── imports
├── cabeçalho tecnológico
├── caminhos e constantes
├── tipos fundamentais de runtime
├── runtime de instalação
├── runtime do ORM
├── runtime de estados
├── runtime de renderização
├── runtime WebView
├── runtime do elemento nativo foreign
├── servidor interno do frontend
├── processo llama-server
├── cliente OpenAI-compatible local
├── runtime RLM
├── memória Git
├── runtime OKF
├── planos intermediários de compile time
├── normalização da AST
├── parser da DSL
├── validação semântica
├── geração de código
├── emissão do manifesto de instalação
└── macro glaucoplastic
```

Essa divisão é somente organizacional. Não são módulos separados.

---

## 4. Estrutura do projeto da aplicação

```text
macroobras/
├── src/
│   └── app.nim
├── glaucoplastic.nim
├── runtime/
│   └── llama/
│       └── windows-x64/
│           ├── llama-server.exe
│           └── *.dll
├── models/
│   └── glauco-agent.gguf
├── scripts/
│   └── build_windows_msi.sh
├── assets/
│   └── MacroObras.ico
├── build/
├── release/
└── macroobras.nimble
```

Estrutura instalada no Windows:

```text
%LOCALAPPDATA%\Programs\MacroObras\
├── MacroObras.exe
├── runtime\
│   └── llama\
│       ├── llama-server.exe
│       └── *.dll
├── models\
│   └── glauco-agent.gguf
└── assets\
```

Estrutura de dados criada pelo MSI:

```text
%LOCALAPPDATA%\MacroObras\
├── data\
│   └── application.sqlite
├── okf\
│   ├── index.json
│   └── espaços declarados
└── .glauco\
    ├── memory\
    └── sessions\
```

Para uma instalação por máquina, o mesmo plano pode usar:

```text
%ProgramData%\MacroObras\
```

Nesse modo, o MSI precisa aplicar permissões de escrita aos usuários autorizados. A instalação por usuário é o padrão recomendado porque os agentes, a memória Git, o banco e os OKFs precisam de diretórios graváveis.

---

## 5. Fases de funcionamento

### 5.1 Compile time

A macro:

1. recebe o corpo da aplicação;
2. normaliza chamadas, comandos, atribuições e blocos;
3. constrói um `PlasticApplicationPlan`;
4. valida nomes e referências;
5. deriva tabelas ORM;
6. deriva caminhos de componentes;
7. deriva dependências reativas;
8. deriva capacidades dos agentes;
9. gera código Nim;
10. opcionalmente emite o manifesto do instalador;
11. retorna uma expressão que constrói `PlasticApplication`.

### 5.2 Runtime

A aplicação gerada:

1. localiza a instalação;
2. carrega os caminhos definidos pelo plano de instalação;
3. valida os diretórios criados pelo MSI;
4. abre o SQLite;
5. registra o ORM;
6. constrói os estados;
7. registra eventos e condições reativas;
8. inicia o servidor interno;
9. cria a janela principal;
10. registra componentes e partes visuais;
11. cria os elementos nativos `foreign` encontrados nas árvores de renderização;
12. abre a memória Git;
13. abre os espaços OKF;
14. inicia o `llama-server` quando houver agentes;
15. registra os agentes RLM;
16. executa a renderização inicial;
17. entra no ciclo visual.

---

# Parte I — Exemplo integral da aplicação

## 6. `src/app.nim`

```nim
import glaucoplastic

let macroObras* = glaucoplastic MacroObras:
  product:
    title "MacroObras"
    description "Administração integrada de obras"
    version "1.0.0"

  installation:
    windowsMsi:
      productName "MacroObras"
      manufacturer "Glauco Developer"
      version "1.0.0"

      upgradeCode "D5752383-57A9-577E-B90D-F9D865A14A53"

      scope perUser
      executable "MacroObras.exe"
      icon "assets/MacroObras.ico"

      installDirectory:
        root localAppDataPrograms
        path "MacroObras"

      applicationData:
        root localAppData
        path "MacroObras"

        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"

      package:
        include "runtime/llama/windows-x64/llama-server.exe",
                as = "runtime/llama/llama-server.exe"

        includeGlob "runtime/llama/windows-x64/*.dll",
                    into = "runtime/llama"

        include "models/glauco-agent.gguf",
                as = "models/glauco-agent.gguf"

      shortcut:
        desktop true
        startMenu true

  orm:
    Obra:
      id integer primary
      nome string
      endereco string
      orcamento money
      inicio date
      terminoPrevisto date

    Medicao:
      id integer primary
      obraId integer
      data date
      valor money
      observacao text

      belongsTo Obra, by = obraId

  okfs:
    Obras:
      purpose """
        Conhecimento estrutural, físico, financeiro e operacional
        das obras administradas pela aplicação.
      """

    Compras:
      purpose """
        Conhecimento sobre solicitações, autorizações, pedidos,
        entregas, recibos e inventário.
      """

  components:
    Painel(titulo, estado):
      visual = {
        titulo: titulo + " — MacroObras",
        estado: estado,
        contador: 1
      }

      render:
        section(part = Root, class = "container"):
          h1(part = Titulo) visual.titulo
          span(part = Estado) visual.estado
          divi(part = Resultado)

          foreign(
            part = Documentacao,
            url = "https://example.com/documentacao",
            class = "documentacao-webcontents"
          ):
            statusCss:
              idle """
                :host {
                  opacity: 1;
                }
              """

              loading """
                :host {
                  opacity: 0.60;
                  pointer-events: none;
                }
              """

              ready """
                :host {
                  opacity: 1;
                  pointer-events: auto;
                }
              """

              failed """
                :host {
                  outline: 1px solid #b42318;
                }
              """

            documentStart:
              evalJs """
                window.__GLAUCOPLASTIC_FOREIGN__ = true;
              """

            when loaded:
              let tituloExterno =
                await Painel.Documentacao.evalJs(
                  "document.title"
                )

              states.TituloExterno =
                tituloExterno

            when navigationChanged:
              states.UrlExterna =
                Painel.Documentacao.currentUrl

            when message:
              states.ResultadoAnalise =
                Painel.Documentacao.lastMessage

    CartaoObra(obra):
      render:
        article(part = Root, class = "obra-card"):
          h2(part = Nome) obra.nome
          span(part = Orcamento) obra.orcamento

  states:
    Obras seq[Obra]:
      value orm.Obra.all()

    ObraSelecionada Obra:
      id 0
      nome ""
      endereco ""
      orcamento 0.0

    EstadoAnalise string = "ocioso"
    ResultadoAnalise json
    TituloExterno string = ""
    UrlExterna string = ""

    when states.ObraSelecionada changed:
      render:
        CartaoObra(states.ObraSelecionada)

    when states.ObraSelecionada.nome changed:
      Painel.Titulo.textContent =
        states.ObraSelecionada.nome

    when states.ObraSelecionada.id != 0 and
         states.EstadoAnalise == "ocioso":

      states.EstadoAnalise = "executando"

    when states.EstadoAnalise == "executando":
      Painel.Resultado.innerHTML =
        "Analisando..."

    when states.EstadoAnalise == "concluido":
      Painel.Resultado.innerHTML =
        states.ResultadoAnalise.summary

  agents:
    Analista(
      "analista-administrativo",
      especialidade = "obras",
      okfPrincipal = Obras,
      podeNavegar = true
    ):
      purpose """
        Analise a obra selecionada.

        Consulte o ORM, a memória Git e os espaços OKF.
        Produza conhecimento estruturado quando o pedido exigir.
        Atualize estados, componentes e elementos foreign.
      """

      render:
        section(class = "agent-status"):
          span "Analista administrativo disponível"

      when states.ObraSelecionada changed:
        let obra =
          orm.Obra.find(
            states.ObraSelecionada.id
          )

        let relacionados =
          okf.Obras.search(obra.nome)

        let tituloPagina =
          await Painel.Documentacao.evalJs(
            "document.title"
          )

        render:
          section(class = "agent-progress"):
            h2 "Analisando"
            span obra.nome
            small tituloPagina

      when states.EstadoAnalise == "executando":
        let resultado =
          rlm.analyze(
            state = states.ObraSelecionada,
            memory = gitMemory.current(),
            knowledge = okf.Obras.search(
              states.ObraSelecionada.nome
            )
          )

        states.ResultadoAnalise =
          resultado

  render:
    Painel(
      "Balanço das obras",
      states.EstadoAnalise
    )

proc runMacroObras*() =
  macroObras.validateInstallation()
  macroObras.run()

proc emitMacroObrasInstallerManifest*(
  outputPath: string
) =
  macroObras.installation.writeManifest(
    outputPath
  )

when isMainModule:
  when defined(
    glaucoplasticEmitInstallerManifest
  ):
    const manifestPath =
      staticEnv(
        "GLAUCOPLASTIC_INSTALLER_MANIFEST",
        "build/windows-msi/installer.json"
      )

    emitMacroObrasInstallerManifest(
      manifestPath
    )
  else:
    runMacroObras()
```

A `proc runMacroObras` é o ponto oficial de execução. Ela pode ser chamada por testes, pelo executável principal ou por outro bootstrap.

A seção `agents:` contém construtores de agentes. Em:

```nim
Analista(
  "analista-administrativo",
  especialidade = "obras",
  okfPrincipal = Obras
):
```

`Analista` é o nome do construtor, `"analista-administrativo"` é o nome da instância e os argumentos seguintes são propriedades personalizadas entregues ao construtor. O corpo declara o `purpose`, a renderização do agente e seus listeners reativos.

---

# Parte II — Cabeçalho tecnológico

## 7. Constantes locais

```nim
const
  PlasticLlamaExecutable =
    when defined(windows):
      "runtime/llama/llama-server.exe"
    else:
      "runtime/llama/llama-server"

  PlasticLlamaModel =
    "models/glauco-agent.gguf"

  PlasticLlamaHost = "127.0.0.1"
  PlasticLlamaPort = 1223
  PlasticLlamaAlias = "glauco-local"
  PlasticLlamaContextSize = 8192
  PlasticLlamaGpuLayers = -1

  PlasticFrontendHost = "127.0.0.1"
  PlasticFrontendPort = 7654
```

Os diretórios de dados não são constantes universais. Eles são derivados do `PlasticInstallationPlan` da aplicação.

---

## 8. Aplicação de runtime

```nim
type
  PlasticApplication* = ref object
    name*: string
    product*: PlasticProductRuntime
    installation*: PlasticInstallationRuntime

    orm*: PlasticOrmRuntime
    states*: PlasticStateRuntime
    frontend*: PlasticFrontendRuntime
    frontendServer*: PlasticFrontendServerRuntime
    webContents*: Table[string, PlasticForeignElementRuntime]

    llama*: PlasticLlamaRuntime
    rlm*: PlasticRlmRuntime
    gitMemory*: PlasticGitMemory
    okf*: PlasticOkfRuntime
    agents*: Table[string, PlasticAgent]
```

API pública:

```nim
proc validateInstallation*(
  application: PlasticApplication
)

proc run*(
  application: PlasticApplication
)

proc open*(
  application: PlasticApplication
)

proc close*(
  application: PlasticApplication
)

proc stopAgents*(
  application: PlasticApplication
)
```

---

# Parte III — Instalação e MSI

## 9. Plano de instalação

```nim
type
  PlasticInstallScope = enum
    pisPerUser
    pisPerMachine

  PlasticInstallRoot = enum
    pirLocalAppDataPrograms
    pirProgramFiles64
    pirLocalAppData
    pirCommonAppData

  PlasticInstallDirectoryPlan = object
    root: PlasticInstallRoot
    relativePath: string

  PlasticInstallAssetKind = enum
    piakFile
    piakGlob

  PlasticInstallAssetPlan = object
    kind: PlasticInstallAssetKind
    sourcePath: string
    destinationPath: string
    source: NimNode

  PlasticWindowsMsiPlan = object
    productName: string
    manufacturer: string
    version: string
    upgradeCode: string
    scope: PlasticInstallScope
    executableName: string
    iconPath: string

    installDirectory: PlasticInstallDirectoryPlan
    applicationData: PlasticInstallDirectoryPlan

    dataDirectories: seq[string]
    assets: seq[PlasticInstallAssetPlan]

    desktopShortcut: bool
    startMenuShortcut: bool

  PlasticInstallationPlan = object
    windowsMsi: PlasticWindowsMsiPlan
```

---

## 10. Responsabilidade pela pasta OKF

A pasta OKF é declarada no plano da aplicação:

```nim
applicationData:
  root localAppData
  path "MacroObras"

  createDirectory "okf"
```

O MSI cria fisicamente a pasta.

O framework em runtime não deve executar:

```nim
createDir(okfPath)
```

O runtime executa somente:

```nim
proc validateOkfInstallation(
  application: PlasticApplication
) =
  let path =
    application.installation.okfPath

  if not dirExists(path):
    raise newException(
      IOError,
      "Diretório OKF ausente. Repare ou reinstale a aplicação: " &
      path
    )
```

O mesmo princípio vale para:

```text
data
.glauco/memory
.glauco/sessions
```

Durante desenvolvimento, um script separado pode preparar o layout. Essa preparação não pertence ao início normal do framework.

---

## 11. Emissão do manifesto

O macro gera um objeto de instalação e expõe:

```nim
proc writeManifest*(
  installation: PlasticInstallationRuntime,
  outputPath: string
)
```

Formato sugerido:

```json
{
  "product_name": "MacroObras",
  "manufacturer": "Glauco Developer",
  "version": "1.0.0",
  "upgrade_code": "D5752383-57A9-577E-B90D-F9D865A14A53",
  "scope": "perUser",
  "executable": "MacroObras.exe",
  "icon": "assets/MacroObras.ico",
  "install_directory": {
    "root": "localAppDataPrograms",
    "path": "MacroObras"
  },
  "application_data": {
    "root": "localAppData",
    "path": "MacroObras",
    "directories": [
      "data",
      "okf",
      ".glauco/memory",
      ".glauco/sessions"
    ]
  },
  "assets": [
    {
      "kind": "file",
      "source": "runtime/llama/windows-x64/llama-server.exe",
      "destination": "runtime/llama/llama-server.exe"
    },
    {
      "kind": "glob",
      "source": "runtime/llama/windows-x64/*.dll",
      "destination": "runtime/llama"
    },
    {
      "kind": "file",
      "source": "models/glauco-agent.gguf",
      "destination": "models/glauco-agent.gguf"
    }
  ],
  "shortcuts": {
    "desktop": true,
    "start_menu": true
  }
}
```

O script de MSI lê esse manifesto. Assim, a configuração permanece em `src/app.nim`.

---

## 12. Script `scripts/build_windows_msi.sh`

O exemplo abaixo foi desenhado para Linux com cross-compilação MinGW e `wixl`.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

APP_SOURCE="${APP_SOURCE:-$PROJECT_ROOT/src/app.nim}"
APP_NAME="${APP_NAME:-MacroObras}"
TARGET_EXE="${TARGET_EXE:-MacroObras.exe}"

BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/windows-msi}"
STAGE_DIR="$BUILD_ROOT/stage"
MANIFEST="$BUILD_ROOT/installer.json"
WXS_FILE="$BUILD_ROOT/${APP_NAME}.wxs"

RELEASE_DIR="${RELEASE_DIR:-$PROJECT_ROOT/release}"
MSI_FILE="$RELEASE_DIR/${APP_NAME}-Windows-x64.msi"

NIM_CACHE="$BUILD_ROOT/nimcache"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERRO: comando ausente: %s\n' "$command_name" >&2
    exit 1
  fi
}

require_command nim
require_command python3
require_command wixl
require_command sha256sum

rm -rf "$BUILD_ROOT"
mkdir -p \
  "$BUILD_ROOT" \
  "$STAGE_DIR" \
  "$RELEASE_DIR" \
  "$NIM_CACHE"

export GLAUCOPLASTIC_INSTALLER_MANIFEST="$MANIFEST"

printf '==> Compilando aplicação Windows e emitindo manifesto\n'

nim c \
  -d:release \
  -d:glaucoplasticEmitInstallerManifest \
  --os:windows \
  --cpu:amd64 \
  --cc:gcc \
  --gcc.exe:x86_64-w64-mingw32-gcc \
  --gcc.linkerexe:x86_64-w64-mingw32-gcc \
  --nimcache:"$NIM_CACHE" \
  --out:"$STAGE_DIR/$TARGET_EXE" \
  "$APP_SOURCE"

if [[ ! -f "$MANIFEST" ]]; then
  printf 'ERRO: manifesto não foi emitido: %s\n' "$MANIFEST" >&2
  exit 1
fi

if [[ ! -f "$STAGE_DIR/$TARGET_EXE" ]]; then
  printf 'ERRO: executável não foi criado\n' >&2
  exit 1
fi

printf '==> Copiando recursos declarados pela aplicação\n'

python3 - "$PROJECT_ROOT" "$STAGE_DIR" "$MANIFEST" <<'PY'
from __future__ import annotations

import glob
import json
import shutil
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
stage = Path(sys.argv[2]).resolve()
manifest_path = Path(sys.argv[3]).resolve()

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

for asset in manifest.get("assets", []):
    kind = asset["kind"]
    source_pattern = str(project / asset["source"])
    destination = Path(asset["destination"])

    if kind == "file":
        source = Path(source_pattern)

        if not source.is_file():
            raise SystemExit(f"Recurso ausente: {source}")

        target = stage / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    elif kind == "glob":
        matches = [
            Path(path)
            for path in sorted(glob.glob(source_pattern))
            if Path(path).is_file()
        ]

        if not matches:
            raise SystemExit(
                f"Nenhum recurso corresponde a: {source_pattern}"
            )

        target_directory = stage / destination
        target_directory.mkdir(parents=True, exist_ok=True)

        for source in matches:
            shutil.copy2(
                source,
                target_directory / source.name
            )

    else:
        raise SystemExit(
            f"Tipo de recurso desconhecido: {kind}"
        )
PY

printf '==> Gerando WiX XML\n'

python3 - \
  "$STAGE_DIR" \
  "$MANIFEST" \
  "$WXS_FILE" <<'PY'
from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

stage = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
wxs_path = Path(sys.argv[3]).resolve()

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

product_name = manifest["product_name"]
manufacturer = manifest["manufacturer"]
version = manifest["version"]
upgrade_code = manifest["upgrade_code"]
executable = manifest["executable"]
scope = manifest.get("scope", "perUser")

namespace = uuid.UUID(upgrade_code)

def stable_id(prefix: str, value: str) -> str:
    digest = uuid.uuid5(namespace, value).hex.upper()
    return f"{prefix}_{digest[:24]}"

def stable_guid(value: str) -> str:
    return str(uuid.uuid5(namespace, value)).upper()

install_root_name = (
    "LocalAppDataFolder"
    if manifest["install_directory"]["root"]
       == "localAppDataPrograms"
    else "ProgramFiles64Folder"
)

data_root_name = (
    "LocalAppDataFolder"
    if manifest["application_data"]["root"]
       == "localAppData"
    else "CommonAppDataFolder"
)

install_path = manifest["install_directory"]["path"]
data_path = manifest["application_data"]["path"]

files = sorted(
    path for path in stage.rglob("*")
    if path.is_file()
)

directory_ids = {
    Path("."): "INSTALLFOLDER"
}

for file_path in files:
    relative_parent = file_path.relative_to(stage).parent

    current = Path(".")
    for part in relative_parent.parts:
        current = current / part

        if current not in directory_ids:
            directory_ids[current] = stable_id(
                "DIR",
                current.as_posix()
            )

children = {}

for relative_path, directory_id in directory_ids.items():
    if relative_path == Path("."):
        continue

    parent = relative_path.parent
    children.setdefault(parent, []).append(relative_path)

def emit_directory_tree(parent: Path, indent: str) -> list[str]:
    lines = []

    for child in sorted(
        children.get(parent, []),
        key=lambda value: value.as_posix()
    ):
        directory_id = directory_ids[child]
        name = child.name

        lines.append(
            f'{indent}<Directory Id={quoteattr(directory_id)} '
            f'Name={quoteattr(name)}>'
        )
        lines.extend(
            emit_directory_tree(child, indent + "  ")
        )
        lines.append(f"{indent}</Directory>")

    return lines

component_refs = []
components_by_directory = {}

for file_path in files:
    relative = file_path.relative_to(stage)
    directory = relative.parent
    directory_id = directory_ids[directory]

    component_id = stable_id(
        "CMP",
        relative.as_posix()
    )
    file_id = stable_id(
        "FIL",
        relative.as_posix()
    )

    component_refs.append(component_id)

    source = str(file_path).replace("\\", "/")

    component_lines = [
        f'<Component Id={quoteattr(component_id)} '
        f'Guid={quoteattr(stable_guid(relative.as_posix()))}>',
        f'  <File Id={quoteattr(file_id)} '
        f'Source={quoteattr(source)} '
        f'KeyPath="yes" />',
        '</Component>'
    ]

    components_by_directory.setdefault(
        directory_id,
        []
    ).extend(component_lines)

data_component_id = stable_id(
    "CMP",
    "application-data-directories"
)
component_refs.append(data_component_id)

data_directories = manifest["application_data"].get(
    "directories",
    []
)

def emit_data_directories(
    paths: list[str],
    indent: str
) -> tuple[list[str], dict[str, str]]:
    ids = {}
    tree = {}

    for path_text in paths:
        path = Path(path_text)
        current = Path(".")

        for part in path.parts:
            parent = current
            current = current / part
            tree.setdefault(parent, set()).add(current)

    def walk(parent: Path, current_indent: str) -> list[str]:
        lines = []

        for child in sorted(
            tree.get(parent, set()),
            key=lambda value: value.as_posix()
        ):
            directory_id = stable_id(
                "DATADIR",
                child.as_posix()
            )
            ids[child.as_posix()] = directory_id

            lines.append(
                f'{current_indent}<Directory '
                f'Id={quoteattr(directory_id)} '
                f'Name={quoteattr(child.name)}>'
            )
            lines.extend(
                walk(child, current_indent + "  ")
            )
            lines.append(
                f"{current_indent}</Directory>"
            )

        return lines

    return walk(Path("."), indent), ids

data_tree_lines, data_directory_ids = (
    emit_data_directories(
        data_directories,
        "          "
    )
)

data_create_lines = []

for path_text in data_directories:
    directory_id = data_directory_ids[path_text]
    data_create_lines.append(
        f'      <CreateFolder '
        f'Directory={quoteattr(directory_id)} />'
    )

registry_root = "HKCU" if scope == "perUser" else "HKLM"

wxs = []
wxs.append('<?xml version="1.0" encoding="UTF-8"?>')
wxs.append(
    '<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">'
)
wxs.append(
    f'  <Product Id="*" '
    f'Name={quoteattr(product_name)} '
    f'Language="1046" '
    f'Version={quoteattr(version)} '
    f'Manufacturer={quoteattr(manufacturer)} '
    f'UpgradeCode={quoteattr(upgrade_code)}>'
)
wxs.append(
    '    <Package InstallerVersion="500" '
    'Compressed="yes" InstallScope="' +
    ("perUser" if scope == "perUser" else "perMachine") +
    '" />'
)
wxs.append(
    '    <MajorUpgrade '
    'DowngradeErrorMessage="Uma versão mais recente já está instalada." />'
)
wxs.append(
    '    <MediaTemplate EmbedCab="yes" />'
)

wxs.append(
    f'    <Directory Id="TARGETDIR" Name="SourceDir">'
)
wxs.append(
    f'      <Directory Id={quoteattr(install_root_name)}>'
)

if install_root_name == "LocalAppDataFolder":
    wxs.append(
        '        <Directory Id="PROGRAMSROOT" '
        'Name="Programs">'
    )
    wxs.append(
        f'          <Directory Id="INSTALLFOLDER" '
        f'Name={quoteattr(install_path)}>'
    )
    base_indent = "            "
else:
    wxs.append(
        f'        <Directory Id="INSTALLFOLDER" '
        f'Name={quoteattr(install_path)}>'
    )
    base_indent = "          "

wxs.extend(
    emit_directory_tree(Path("."), base_indent)
)

if install_root_name == "LocalAppDataFolder":
    wxs.append('          </Directory>')
    wxs.append('        </Directory>')
else:
    wxs.append('        </Directory>')

wxs.append('      </Directory>')

wxs.append(
    f'      <Directory Id={quoteattr(data_root_name)}>'
)
wxs.append(
    f'        <Directory Id="APPDATAROOT" '
    f'Name={quoteattr(data_path)}>'
)
wxs.extend(data_tree_lines)
wxs.append('        </Directory>')
wxs.append('      </Directory>')

wxs.append('      <Directory Id="DesktopFolder" />')
wxs.append(
    '      <Directory Id="ProgramMenuFolder">'
)
wxs.append(
    f'        <Directory Id="ApplicationProgramsFolder" '
    f'Name={quoteattr(product_name)} />'
)
wxs.append('      </Directory>')
wxs.append('    </Directory>')

for directory_id, lines in components_by_directory.items():
    wxs.append(
        f'    <DirectoryRef Id={quoteattr(directory_id)}>'
    )

    for line in lines:
        wxs.append("      " + line)

    wxs.append('    </DirectoryRef>')

wxs.append('    <DirectoryRef Id="APPDATAROOT">')
wxs.append(
    f'      <Component Id={quoteattr(data_component_id)} '
    f'Guid={quoteattr(stable_guid("application-data-directories"))}>'
)
wxs.extend(data_create_lines)
wxs.append(
    f'        <RegistryValue Root={quoteattr(registry_root)} '
    f'Key={quoteattr("Software\\" + manufacturer + "\\" + product_name)} '
    'Name="DataDirectories" Type="integer" '
    'Value="1" KeyPath="yes" />'
)
wxs.append('      </Component>')
wxs.append('    </DirectoryRef>')

main_exe_relative = Path(executable)
main_exe_id = stable_id(
    "FIL",
    main_exe_relative.as_posix()
)

shortcut_component = stable_id(
    "CMP",
    "shortcuts"
)
component_refs.append(shortcut_component)

wxs.append('    <DirectoryRef Id="ApplicationProgramsFolder">')
wxs.append(
    f'      <Component Id={quoteattr(shortcut_component)} '
    f'Guid={quoteattr(stable_guid("shortcuts"))}>'
)

if manifest.get("shortcuts", {}).get("start_menu", False):
    wxs.append(
        f'        <Shortcut Id="StartMenuShortcut" '
        f'Name={quoteattr(product_name)} '
        'Target="[INSTALLFOLDER]' +
        escape(executable) +
        '" WorkingDirectory="INSTALLFOLDER" />'
    )

wxs.append(
    '        <RemoveFolder Id="RemoveApplicationProgramsFolder" '
    'On="uninstall" />'
)
wxs.append(
    f'        <RegistryValue Root={quoteattr(registry_root)} '
    f'Key={quoteattr("Software\\" + manufacturer + "\\" + product_name)} '
    'Name="Shortcuts" Type="integer" '
    'Value="1" KeyPath="yes" />'
)
wxs.append('      </Component>')
wxs.append('    </DirectoryRef>')

if manifest.get("shortcuts", {}).get("desktop", False):
    desktop_component = stable_id(
        "CMP",
        "desktop-shortcut"
    )
    component_refs.append(desktop_component)

    wxs.append('    <DirectoryRef Id="DesktopFolder">')
    wxs.append(
        f'      <Component Id={quoteattr(desktop_component)} '
        f'Guid={quoteattr(stable_guid("desktop-shortcut"))}>'
    )
    wxs.append(
        f'        <Shortcut Id="DesktopShortcut" '
        f'Name={quoteattr(product_name)} '
        'Target="[INSTALLFOLDER]' +
        escape(executable) +
        '" WorkingDirectory="INSTALLFOLDER" />'
    )
    wxs.append(
        f'        <RegistryValue Root={quoteattr(registry_root)} '
        f'Key={quoteattr("Software\\" + manufacturer + "\\" + product_name)} '
        'Name="DesktopShortcut" Type="integer" '
        'Value="1" KeyPath="yes" />'
    )
    wxs.append('      </Component>')
    wxs.append('    </DirectoryRef>')

wxs.append('    <Feature Id="MainFeature" Title="Aplicação" Level="1">')

for component_id in component_refs:
    wxs.append(
        f'      <ComponentRef Id={quoteattr(component_id)} />'
    )

wxs.append('    </Feature>')
wxs.append('  </Product>')
wxs.append('</Wix>')

wxs_path.write_text(
    "\n".join(wxs) + "\n",
    encoding="utf-8"
)
PY

printf '==> Construindo MSI\n'

wixl \
  -o "$MSI_FILE" \
  "$WXS_FILE"

printf '==> Gerando SHA-256\n'

sha256sum "$MSI_FILE" \
  > "$MSI_FILE.sha256"

printf '\nMSI: %s\n' "$MSI_FILE"
printf 'SHA: %s\n' "$MSI_FILE.sha256"
```

### 12.1 Execução

```bash
chmod +x scripts/build_windows_msi.sh

./scripts/build_windows_msi.sh
```

### 12.2 Dependências em Manjaro

Os nomes dos pacotes podem variar, mas o ambiente precisa fornecer:

```text
nim
mingw-w64-gcc
wixl
python
coreutils
```

### 12.3 Observação sobre diretórios vazios

O WXS usa componentes de instalação para criar os diretórios de dados. A pasta `okf` é criada pelo MSI antes da primeira execução.

O script deve ser testado com a versão instalada de `wixl`, especialmente para:

```text
CreateFolder
RegistryValue
atalhos
InstallScope
```

Se o projeto usar instalação por máquina, acrescente permissões graváveis ao diretório em `%ProgramData%`.

---

# Parte IV — ORM

## 13. Namespace global

```nim
orm.Obra.find(10)
orm.Obra.all()
orm.Obra.insert(dados)
orm.Obra.update(10, dados)
orm.Obra.delete(10)
orm.Obra.where(status = "ativa")
```

Não existe `this.orm`.

---

## 14. Plano ORM

```nim
type
  PlasticOrmFieldPlan = object
    name: string
    fieldType: string
    modifiers: seq[string]
    source: NimNode

  PlasticOrmRelationKind = enum
    porkBelongsTo
    porkHasOne
    porkHasMany

  PlasticOrmRelationPlan = object
    kind: PlasticOrmRelationKind
    targetEntity: string
    foreignKey: string
    source: NimNode

  PlasticOrmEntityPlan = object
    name: string
    fields: seq[PlasticOrmFieldPlan]
    relations: seq[PlasticOrmRelationPlan]
    source: NimNode

  PlasticOrmPlan = object
    entities: seq[PlasticOrmEntityPlan]
```

Operações mínimas:

```text
all
count
find
findOrDefault
first
firstOrDefault
where
insert
insertMany
update
delete
deleteWhere
exists
sum
min
max
transaction
```

---

# Parte V — Componentes e renderização

## 15. Componentes

```nim
components:
  Painel(titulo, estado):
    outroEstado = {
      titulo: titulo + " Título qualquer",
      contador: 1
    }

    render:
      section(part = Root, class = "container"):
        h1(part = Titulo) outroEstado.titulo
        span(part = Contador) outroEstado.contador
```

### 15.1 Locais

```nim
tituloCompleto = titulo + " — MacroObras"

visual = {
  titulo: tituloCompleto,
  contador: 1
}
```

### 15.2 Plano

```nim
type
  PlasticComponentParameterPlan = object
    name: string
    source: NimNode

  PlasticMapEntryPlan = object
    name: string
    value: NimNode

  PlasticComponentLocalKind = enum
    pclkExpression
    pclkMap

  PlasticComponentLocalPlan = object
    name: string
    source: NimNode

    case kind: PlasticComponentLocalKind
    of pclkExpression:
      expression: NimNode
    of pclkMap:
      entries: seq[PlasticMapEntryPlan]

  PlasticRenderAttributePlan = object
    name: string
    value: NimNode

  PlasticRenderNodePlan = ref object
    nodeType: string
    partName: string
    attributes: seq[PlasticRenderAttributePlan]
    arguments: seq[NimNode]
    children: seq[PlasticRenderNodePlan]
    source: NimNode

  PlasticComponentPlan = object
    name: string
    parameters: seq[PlasticComponentParameterPlan]
    locals: seq[PlasticComponentLocalPlan]
    renderStack: seq[PlasticRenderNodePlan]
    source: NimNode
```

---

## 16. Partes visuais e interface jsDOM-like

```nim
Painel.Titulo.innerHTML = "Novo título"
Painel.Titulo.textContent = "Obras"
Painel.Resultado.className = "resultado concluido"
Painel.Resultado.style.display = "block"
Painel.Resultado.setAttribute("data-status", "ok")
```

Atributo `part`:

```nim
h1(part = Titulo) titulo
```

O gerador cria um registro de caminho:

```text
Painel.Titulo
```

Seleção temporária:

```nim
selector("#resultado").innerHTML = "Concluído"

selectors(".obra-card").forEach:
  classList.add "carregada"
```

Não existe declaração `selectors:`.

---

## 17. `render` em qualquer efeito

```nim
render:
  CartaoObra(obra)
```

Pode aparecer:

```text
nível global
componentes
listeners de estado
agentes
ações
callbacks
eventos do elemento `foreign`
corpos de agentes
```

O retorno pode representar uma instância:

```nim
let card = render CartaoObra(obra)
card.Nome.textContent = obra.nome
```

---

# Parte VI — Estados

## 18. Declaração

Forma curta:

```nim
states:
  EstadoAnalise string = "ocioso"
```

Expressão inicial:

```nim
states:
  Obras seq[Obra]:
    value orm.Obra.all()
```

Construtor:

```nim
states:
  ObraSelecionada Obra:
    id 0
    nome ""
    endereco ""
    orcamento 0.0
```

O bloco após a declaração é o construtor inicial.

---

## 19. Acesso

```nim
states.ObraSelecionada
states.EstadoAnalise = "executando"
states.ObraSelecionada.nome = "Nova obra"
```

---

## 20. Evento postfix

Sintaxe pretendida:

```nim
when states.ObraSelecionada changed:
  render:
    CartaoObra(states.ObraSelecionada)
```

Propriedade:

```nim
when states.ObraSelecionada.nome changed:
  Painel.Titulo.textContent =
    states.ObraSelecionada.nome
```

Semântica:

```text
valor anterior diferente do valor atual
→ executar listener
```

### 20.1 AST esperada

A implementação precisa verificar se a versão alvo do Nim entrega:

```text
nnkCommand
├── nnkDotExpr
│   ├── states
│   └── ObraSelecionada
└── changed
```

Teste inicial:

```nim
import std/macros

macro inspect(body: untyped): untyped =
  echo body.treeRepr
  result = newStmtList()

inspect:
  when states.ObraSelecionada changed:
    discard
```

Um `template` não modifica a gramática. Caso a forma seja rejeitada antes da macro, será necessário um pré-processador textual para conservar exatamente essa escrita. O parser monolítico deve tentar primeiro a interpretação por `nnkCommand`.

---

## 21. Condições reativas

```nim
when states.EstadoAnalise == "executando":
  Painel.Resultado.innerHTML = "Analisando..."
```

Executa na transição:

```text
false → true
```

Condição composta:

```nim
when states.ObraSelecionada.id != 0 and
     states.EstadoAnalise == "ocioso":

  states.EstadoAnalise = "executando"
```

Dependências:

```text
ObraSelecionada
EstadoAnalise
```

---

## 22. Plano reativo

```nim
type
  PlasticStateEventKind = enum
    psekChanged

  PlasticStateEventPlan = object
    stateName: string
    propertyPath: seq[string]
    eventKind: PlasticStateEventKind
    source: NimNode

  PlasticStateListenerKind = enum
    pslEvent
    pslCondition

  PlasticStateListenerPlan = object
    kind: PlasticStateListenerKind
    events: seq[PlasticStateEventPlan]
    condition: NimNode
    dependencies: seq[string]
    effects: seq[PlasticEffectPlan]
    source: NimNode
```

Runtime:

```nim
type
  PlasticRuntimeListenerKind = enum
    prlkChanged
    prlkConditionEntered

  PlasticRuntimeListener = ref object
    kind: PlasticRuntimeListenerKind
    dependencies: seq[string]
    previousCondition: bool
    evaluate: proc(): bool
    execute: proc()
```

---

# Parte VII — Elemento nativo `foreign`

## 23. Definição

`foreign` não é uma seção superior da aplicação e não cria uma janela separada. Ele é um tipo nativo de nó visual aceito dentro de qualquer bloco `render:`.

```nim
render:
  foreign(
    part = Documentacao,
    url = "https://example.com/documentacao",
    class = "documentacao-webcontents"
  ):
    statusCss:
      loading """
        :host {
          opacity: 0.60;
          pointer-events: none;
        }
      """

      ready """
        :host {
          opacity: 1;
          pointer-events: auto;
        }
      """

      failed """
        :host {
          outline: 1px solid #b42318;
        }
      """
```

O elemento representa uma `WebContentsView` nativa integrada como filho da
árvore visual do host. A geometria deixa de depender de polling contínuo e
passa a ser publicada pelo DOM para o runtime quando o layout muda.

Backends:

```text
Windows → WebView2/CoreWebView2 associado a uma WebContentsView
Linux   → WebKitGTK associado a um widget nativo
macOS   → WKWebView associado a uma view nativa
```

A renderização principal cria um elemento host. O runtime recebe snapshots de
layout do DOM e atualiza a view nativa apenas quando a geometria muda.

No WebKitGTK, o bridge usa `WebKitUserContentManager` e mensagens de script.
No WebView2, o mesmo contrato deve ser atendido por `chrome.webview.postMessage`
e pelo evento de mensagem do host.

---

## 24. Configuração

Atributos essenciais:

```text
part
url
class
id
visible
allowNavigation
allowMessages
```

Exemplo:

```nim
foreign(
  part = Fornecedor,
  url = states.UrlFornecedor,
  class = "fornecedor-webcontents",
  allowNavigation = true,
  allowMessages = true
)
```

`url` pode ser uma string literal, um estado, uma propriedade ORM ou qualquer expressão aceita pelo gerador.

## 24.1. Perfil WebView

O perfil do WebView usa por padrão a pasta de execução atual:

```text
./webview/Default
```

As aplicações podem sobrescrever esse diretório com `configureUserFolder()` ou
`configureClientFolder()` antes da inicialização.

---

## 25. Status e CSS

O runtime mantém um estado interno para cada elemento:

```text
idle
loading
ready
navigating
failed
closed
```

O bloco `statusCss:` associa CSS ao host visual:

```nim
statusCss:
  idle """
    :host {
      visibility: hidden;
    }
  """

  loading """
    :host {
      visibility: visible;
      opacity: 0.55;
    }
  """

  ready """
    :host {
      visibility: visible;
      opacity: 1;
    }
  """

  failed """
    :host {
      visibility: visible;
      outline: 2px solid #b42318;
    }
  """
```

`:host` identifica o wrapper visual criado pelo GlaucoPlastic. O runtime também aplica classes automáticas:

```text
glauco-foreign
glauco-foreign--idle
glauco-foreign--loading
glauco-foreign--ready
glauco-foreign--navigating
glauco-foreign--failed
glauco-foreign--closed
```

Isso permite usar CSS normal do componente:

```css
.documentacao-webcontents.glauco-foreign--loading {
  filter: grayscale(0.4);
}
```

O CSS configura a representação e o status do host. O conteúdo remoto mantém seu próprio documento e seus próprios estilos.

---

## 26. Scripts e eventos

```nim
foreign(
  part = Documentacao,
  url = "https://example.com"
):
  documentStart:
    evalJs """
      window.__GLAUCOPLASTIC_FOREIGN__ = true;
    """

  when loaded:
    let titulo =
      await Painel.Documentacao.evalJs(
        "document.title"
      )

    states.TituloExterno = titulo

  when navigationChanged:
    states.UrlExterna =
      Painel.Documentacao.currentUrl

  when message:
    states.ResultadoAnalise =
      Painel.Documentacao.lastMessage

  when failed:
    Painel.Resultado.textContent =
      Painel.Documentacao.lastError.message
```

Eventos suportados:

```text
created
loading
loaded
navigationStarted
navigationChanged
message
failed
closed
```

Esses `when` pertencem ao corpo do nó `foreign`. Eles são eventos do elemento e não listeners do namespace `states`.

---

## 27. Operações por caminho visual

O elemento recebe o nome indicado em `part` e passa a integrar o namespace do componente:

```nim
Painel.Documentacao.navigate(
  "https://example.com/nova-pagina"
)

Painel.Documentacao.reload()
Painel.Documentacao.goBack()
Painel.Documentacao.goForward()
Painel.Documentacao.stop()

let titulo =
  await Painel.Documentacao.evalJs(
    "document.title"
  )

Painel.Documentacao.injectDocumentStart("""
  window.glaucoInjected = true;
""")

Painel.Documentacao.postMessage(
  %*{"type": "refresh"}
)

Painel.Documentacao.visible = false
```

Getters:

```nim
Painel.Documentacao.currentUrl
Painel.Documentacao.status
Painel.Documentacao.lastMessage
Painel.Documentacao.lastError
Painel.Documentacao.canGoBack
Painel.Documentacao.canGoForward
```

`evalJs`:

1. agenda a execução na thread visual;
2. espera a inicialização do WebContents;
3. executa no documento remoto;
4. serializa o resultado para JSON;
5. propaga erro JavaScript estruturado;
6. aplica timeout;
7. funciona em URLs externas;
8. pode ser chamado pela aplicação e por agentes autorizados.

---

## 28. Plano do elemento `foreign`

```nim
type
  PlasticForeignStatusCssPlan = object
    statusName: string
    cssExpression: NimNode
    source: NimNode

  PlasticForeignEventPlan = object
    eventName: string
    effects: seq[PlasticEffectPlan]
    source: NimNode

  PlasticForeignElementPlan = object
    partName: string
    urlExpression: NimNode
    attributes: seq[PlasticRenderAttributePlan]
    statusCss: seq[PlasticForeignStatusCssPlan]
    documentStartScripts: seq[NimNode]
    events: seq[PlasticForeignEventPlan]
    source: NimNode
```

`PlasticForeignElementPlan` é derivado de um `PlasticRenderNodePlan` cujo `nodeType` é `"foreign"`. Ele não aparece como seção superior de `PlasticApplicationPlan`.

---

## 29. Parser dentro de `render`

```nim
proc parseRenderNode(
  node: NimNode
): PlasticRenderNodePlan {.compileTime.} =
  result =
    parseGenericRenderNodeHeader(node)

  if result.nodeType == "foreign":
    result.foreignElement =
      parseForeignElement(node)

    return

  if node.hasBody:
    for child in node.bodyOf:
      result.children.add(
        parseRenderNode(child)
      )
```

O corpo de `foreign` aceita somente:

```text
statusCss
documentStart
when <evento>
```

Tags HTML ou componentes não são filhos do documento remoto.

---

## 30. Segurança

A página externa recebe uma ponte reduzida:

```js
window.glaucoForeign = {
  postMessage(payload) {
    // encaminhado ao runtime Nim
  }
};
```

Ela não recebe acesso direto ao ORM, sistema de arquivos, shell, Git, OKF ou RLM.

Agentes autorizados usam capabilities controladas:

```text
webcontents.list
webcontents.describe
webcontents.navigate
webcontents.reload
webcontents.eval_js
webcontents.inject_document_start
webcontents.post_message
webcontents.close
```

O runtime registra o caminho visual, URL, script, agente solicitante, resultado e erro para auditoria.

---

# Parte VIII — Servidor interno

## 31. Servidor do frontend

A janela principal usa:

```text
http://127.0.0.1:7654/
```

O servidor entrega o frontend gerado, os componentes, o runtime reativo e a ponte local. Não existe uma seção `public:` na DSL e o framework não gera elementos públicos por declaração.


---

# Parte IX — Agentes RLM

## 32. Seção `agents:`

Os agentes são declarados em uma seção plural:

```nim
agents:
  Analista(
    "analista-administrativo",
    especialidade = "obras",
    okfPrincipal = Obras
  ):
    purpose """
      Analise estados da aplicação e produza operações adequadas.
    """

    render:
      section(class = "agent-status"):
        span "Agente disponível"

    when states.ObraSelecionada changed:
      let obra =
        orm.Obra.find(
          states.ObraSelecionada.id
        )

      render:
        section(class = "agent-progress"):
          h2 "Analisando"
          span obra.nome

    when states.EstadoAnalise == "executando":
      states.ResultadoAnalise =
        rlm.analyze(
          state = states.ObraSelecionada
        )
```

Não existe a forma superior:

```nim
agent Analista:
```

A seção correta é:

```nim
agents:
  Analista(...):
```

---

## 33. Semântica do construtor

Formato geral:

```nim
agents:
  NomeDoConstrutor(
    nomeDaInstancia,
    propriedadesPersonalizadas
  ):
    corpoDeExecucao
```

Exemplo:

```nim
agents:
  Analista(
    "analista-financeiro",
    especialidade = "financeiro",
    okfPrincipal = Obras,
    podeNavegar = true,
    limiteDePesquisa = 12
  ):
    purpose """
      Produza análises financeiras das obras.
    """
```

Interpretação:

```text
NomeDoConstrutor
→ Analista

nome da instância
→ "analista-financeiro"

propriedades personalizadas
→ especialidade
→ okfPrincipal
→ podeNavegar
→ limiteDePesquisa
```

As propriedades são preservadas como expressões Nim no plano intermediário. O gerador as entrega ao construtor do agente.

O construtor técnico continua incorporando automaticamente:

```text
llama-server local
modelo GGUF local
RLM nativo
memória Git
OKF
ORM
estados
componentes
renderização
WebContents foreign
```

A declaração da aplicação fornece o nome e as propriedades específicas do agente.

---

## 34. Corpo de execução

O corpo de um construtor de agente aceita:

```text
purpose
declarações locais
render
when states.<caminho> changed
when <condição reativa>
ações e expressões
```

`purpose` compõe a instrução system.

Um `render:` diretamente no corpo registra a renderização inicial ou permanente do agente:

```nim
agents:
  Analista("analista"):
    render:
      section(class = "agent-presence"):
        span "Analista disponível"
```

Um `render:` dentro de `when` é adicionado quando o listener executar:

```nim
agents:
  Analista("analista"):
    when states.ObraSelecionada changed:
      render:
        section(class = "agent-result"):
          span states.ObraSelecionada.nome
```

Os listeners usam a mesma semântica dos estados da aplicação:

```nim
when states.ObraSelecionada changed:
```

Executa em qualquer alteração do estado ou da propriedade observada.

```nim
when states.EstadoAnalise == "executando":
```

Executa quando a condição transita de falsa para verdadeira.

---

## 35. Plano do construtor de agente

```nim
type
  PlasticAgentArgumentKind = enum
    paakPositional
    paakNamed

  PlasticAgentArgumentPlan = object
    kind: PlasticAgentArgumentKind
    name: string
    valueExpression: NimNode
    source: NimNode

  PlasticAgentPlan = object
    constructorName: string
    instanceNameExpression: NimNode
    constructorArguments: seq[PlasticAgentArgumentPlan]

    purpose: string
    localDeclarations: seq[NimNode]
    listeners: seq[PlasticStateListenerPlan]
    renderStack: seq[PlasticRenderNodePlan]

    usesNativeRlm: bool
    usesGitMemory: bool
    usesOkfRuntime: bool
    source: NimNode
```

O primeiro argumento é obrigatório e define o nome da instância:

```nim
Analista("analista-administrativo"):
```

Os demais argumentos podem ser posicionais ou nomeados. Recomenda-se usar argumentos nomeados para propriedades personalizadas.

---

## 36. Parser de `agents:`

```nim
proc parseAgents(
  node: NimNode
): seq[PlasticAgentPlan] {.compileTime.} =
  for declaration in node.bodyOf:
    result.add(
      parseAgentConstructor(
        declaration
      )
    )
```

```nim
proc parseAgentConstructor(
  node: NimNode
): PlasticAgentPlan {.compileTime.} =
  if node.kind notin PlasticCallKinds or
     not node.hasBody:
    error(
      "Esperava `NomeAgente(nome, propriedades):`.",
      node
    )

  result.constructorName =
    nodeName(node[0])

  let arguments =
    node.argumentsOf()

  if arguments.len == 0:
    error(
      "O construtor do agente precisa receber " &
      "o nome da instância.",
      node
    )

  result.instanceNameExpression =
    arguments[0].copyNimTree()

  for argument in arguments[1 .. ^1]:
    if argument.kind == nnkExprEqExpr:
      result.constructorArguments.add(
        PlasticAgentArgumentPlan(
          kind: paakNamed,
          name: nodeName(argument[0]),
          valueExpression:
            argument[1].copyNimTree(),
          source:
            argument.copyNimTree()
        )
      )
    else:
      result.constructorArguments.add(
        PlasticAgentArgumentPlan(
          kind: paakPositional,
          valueExpression:
            argument.copyNimTree(),
          source:
            argument.copyNimTree()
        )
      )

  result.usesNativeRlm = true
  result.usesGitMemory = true
  result.usesOkfRuntime = true

  for declaration in node.bodyOf:
    if declaration.isCall("purpose"):
      result.purpose =
        parsePurpose(declaration)

    elif declaration.isCall("render"):
      result.renderStack.add(
        parseRender(declaration)
      )

    elif declaration.kind == nnkWhenStmt:
      result.listeners.add(
        parseStateWhen(declaration)
      )

    else:
      result.localDeclarations.add(
        declaration.copyNimTree()
      )

  if result.purpose.len == 0:
    error(
      "O agente precisa declarar `purpose`.",
      node
    )
```

---

## 37. Prompt do agente

Composição:

```text
instrução-base RLM
protocolo de instruções estruturadas
skills de uso do ORM
skills de estado e renderização
skill de memória Git
skill de consulta OKF
skill de geração OKF
descrição dos espaços OKF
descrição dos elementos foreign disponíveis
nome e propriedades personalizadas do construtor
purpose do agente
snapshot do estado
evento atual
memórias relevantes
```

---

## 38. Runtime RLM

```nim
type
  PlasticRlmEvent = object
    kind: string
    payload: JsonNode
    createdAt: DateTime

  PlasticRlmSession = ref object
    id: string
    events: seq[PlasticRlmEvent]
    variables: Table[string, JsonNode]
    stateSnapshot: JsonNode

  PlasticRlmEnvironment = ref object
    application: PlasticApplication
    agent: PlasticAgent
    session: PlasticRlmSession
    iteration: int
    recursionDepth: int
    input: JsonNode

  PlasticRlmRuntime = ref object
    maxIterations: int
    maxRecursionDepth: int
    sessions: Table[string, PlasticRlmSession]
    capabilities:
      Table[string, PlasticRlmCapability]
```

O modelo devolve instruções estruturadas. O framework não executa código Nim arbitrário produzido pelo modelo.

---

## 39. Capacidades

```text
orm.list_entities
orm.describe
orm.query
orm.insert
orm.update
orm.delete

state.list
state.get
state.set
state.patch

component.list
component.describe
component.get
component.set

dom.query
dom.query_all
dom.get
dom.set
dom.call

render.push
render.replace
render.remove

webcontents.list
webcontents.describe
webcontents.navigate
webcontents.reload
webcontents.eval_js
webcontents.inject_document_start
webcontents.post_message
webcontents.close

git.status
git.diff
git.log
git.read
git.search

okf.list
okf.tree
okf.get
okf.search
okf.generate
okf.update
okf.exists

rlm.subquery
rlm.assign
rlm.get
answer
```


---

# Parte X — Modelo local

## 34. Recursos

```text
runtime/llama/llama-server.exe
runtime/llama/*.dll
models/glauco-agent.gguf
```

O MSI instala esses arquivos junto do executável.

---

## 35. Processo

```nim
proc startLocalLlama(): PlasticLlamaRuntime =
  validateLocalModelAssets()

  let process = startProcess(
    command =
      getAppDir() /
      PlasticLlamaExecutable,

    args = @[
      "--model",
      getAppDir() / PlasticLlamaModel,

      "--host",
      PlasticLlamaHost,

      "--port",
      $PlasticLlamaPort,

      "--alias",
      PlasticLlamaAlias,

      "--ctx-size",
      $PlasticLlamaContextSize,

      "--n-gpu-layers",
      $PlasticLlamaGpuLayers
    ],

    workingDir = getAppDir(),
    options = {
      poStdErrToStdOut
    }
  )

  result = PlasticLlamaRuntime(
    process: process,
    endpoint:
      "http://" &
      PlasticLlamaHost &
      ":" &
      $PlasticLlamaPort &
      "/v1",
    modelAlias:
      PlasticLlamaAlias
  )
```

O processo inicia uma única vez por aplicação.

---

# Parte XI — Memória Git

## 36. Estrutura

```nim
type
  PlasticGitSnapshot = object
    head: string
    branch: string
    status: string
    workingDiff: string
    stagedDiff: string
    changedFiles: seq[string]
    createdAt: DateTime

  PlasticGitMemory = ref object
    repositoryPath: string
    memoryPath: string
    previousSnapshot: PlasticGitSnapshot
    currentSnapshot: PlasticGitSnapshot
```

A pasta `.glauco/memory` é criada pelo MSI.

Antes da execução do agente:

```text
capturar HEAD
capturar branch
capturar status
capturar diff
buscar memórias relevantes
```

Depois:

```text
registrar resultado
registrar decisões
registrar estados alterados
registrar OKFs produzidos
capturar diff posterior
persistir memo
```

---

# Parte XII — OKF

## 37. Declaração

```nim
okfs:
  Obras:
    purpose """
      Conhecimento do domínio das obras.
    """

  Compras:
    purpose """
      Conhecimento do fluxo de compras.
    """
```

A pasta `okf` e seus diretórios iniciais são criados pelo MSI conforme o manifesto da aplicação.

O runtime abre e valida o workspace. Ele não cria o diretório raiz.

---

## 38. API

```nim
okf.list()
okf.tree()
okf.get("id")
okf.search("consulta")
okf.exists("id")

okf.Obras.list()
okf.Obras.get("id")
okf.Obras.search("consulta")

okf.Obras.generate(
  source = pedido,
  related = relacionados
)

okf.Obras.update(
  "id",
  source = novoConteudo
)
```

---

## 39. Skills incorporadas

### Consulta

```text
Consulte os OKFs existentes antes de responder sobre conhecimento
persistido do domínio.

Use okf.search para busca global.
Use okf.<espaço>.search para busca restrita.
Use okf.get para recuperar documentos completos.
Use okf.tree para conhecer a organização.
```

### Geração

```text
Quando o pedido exigir produzir ou estruturar conhecimento:

1. consulte OKFs existentes;
2. identifique relações;
3. escolha o espaço adequado;
4. produza título e resumo;
5. descreva elementos, propriedades, relações e funções;
6. registre fontes e metadados;
7. use okf.generate;
8. use okf.update quando houver continuidade;
9. devolva o identificador persistido.
```

---

## 40. Documento OKF

```nim
type
  PlasticOkfDocument = object
    id: string
    space: string
    title: string
    summary: string
    elements: JsonNode
    properties: JsonNode
    relations: JsonNode
    functions: JsonNode
    sources: JsonNode
    metadata: JsonNode
    createdAt: DateTime
    updatedAt: DateTime
```

---

# Parte XIII — Planos da aplicação

## 41. Plano principal

```nim
type
  PlasticApplicationPlan = object
    name: string
    product: PlasticProductPlan
    installation: PlasticInstallationPlan
    orm: PlasticOrmPlan
    okf: PlasticOkfPlan
    components: seq[PlasticComponentPlan]
    states: seq[PlasticStatePlan]
    stateListeners: seq[PlasticStateListenerPlan]
    agents: seq[PlasticAgentPlan]
    globalRenderStack: seq[PlasticRenderNodePlan]
```

---

## 42. Agente

O plano do agente é produzido pelas declarações contidas em `agents:`:

```nim
type
  PlasticAgentArgumentPlan = object
    name: string
    isNamed: bool
    valueExpression: NimNode
    source: NimNode

  PlasticAgentPlan = object
    constructorName: string
    instanceNameExpression: NimNode
    constructorArguments:
      seq[PlasticAgentArgumentPlan]

    purpose: string
    localDeclarations: seq[NimNode]
    listeners: seq[PlasticStateListenerPlan]
    renderStack: seq[PlasticRenderNodePlan]

    usesNativeRlm: bool
    usesGitMemory: bool
    usesOkfRuntime: bool
    source: NimNode
```

---

## 43. Efeitos

```nim
type
  PlasticEffectKind = enum
    pekExpression
    pekStateMutation
    pekDomMutation
    pekRender
    pekOrmCall
    pekOkfCall
    pekWebContentsCall

  PlasticEffectPlan = ref object
    kind: PlasticEffectKind
    expression: NimNode
    renderNodes: seq[PlasticRenderNodePlan]
    source: NimNode
```

---

# Parte XIV — Normalização da AST

## 44. Helpers fundamentais

```nim
const
  PlasticCallKinds = {
    nnkCall,
    nnkCommand
  }

proc nodeName(
  node: NimNode
): string {.compileTime.} =
  case node.kind
  of nnkIdent, nnkSym:
    node.strVal
  else:
    node.repr

proc hasBody(
  node: NimNode
): bool {.compileTime.} =
  node.kind in PlasticCallKinds and
  node.len > 0 and
  node[^1].kind == nnkStmtList

proc bodyOf(
  node: NimNode
): NimNode {.compileTime.} =
  if not node.hasBody:
    error(
      "A declaração precisa de corpo.",
      node
    )

  node[^1]

proc argumentEnd(
  node: NimNode
): int {.compileTime.} =
  if node.hasBody:
    node.len - 1
  else:
    node.len

proc argumentsOf(
  node: NimNode
): seq[NimNode] {.compileTime.} =
  if node.kind notin PlasticCallKinds:
    error(
      "Esperava uma chamada.",
      node
    )

  for index in 1 ..< node.argumentEnd:
    result.add(
      node[index].copyNimTree()
    )
```

---

## 45. Caminhos pontuados

```nim
proc flattenDotPath(
  node: NimNode
): seq[string] {.compileTime.} =
  case node.kind
  of nnkIdent, nnkSym:
    result.add node.strVal

  of nnkDotExpr:
    result.add flattenDotPath(node[0])
    result.add nodeName(node[1])

  else:
    discard
```

Exemplos:

```text
orm.Obra.find
→ ["orm", "Obra", "find"]

states.ObraSelecionada.nome
→ ["states", "ObraSelecionada", "nome"]

Painel.Documentacao.evalJs
→ ["Painel", "Documentacao", "evalJs"]

okf.Obras.search
→ ["okf", "Obras", "search"]
```

---

# Parte XV — Parser

## 46. Parser principal

```nim
proc parseApplication(
  applicationName: NimNode,
  body: NimNode
): PlasticApplicationPlan {.compileTime.} =
  result.name = nodeName(applicationName)

  for declaration in body:
    if declaration.isCall("product"):
      result.product =
        parseProduct(declaration)

    elif declaration.isCall("installation"):
      result.installation =
        parseInstallation(declaration)

    elif declaration.isCall("orm"):
      result.orm =
        parseOrm(declaration)

    elif declaration.isCall("okfs"):
      result.okf =
        parseOkfs(declaration)

    elif declaration.isCall("components"):
      result.components =
        parseComponents(declaration)

    elif declaration.isCall("states"):
      parseStates(
        declaration,
        result.states,
        result.stateListeners
      )

    elif declaration.isCall("agents"):
      result.agents =
        parseAgents(declaration)

    elif declaration.isCall("render"):
      result.globalRenderStack.add(
        parseRender(declaration)
      )

    else:
      error(
        "Elemento desconhecido: " &
        declaration.repr,
        declaration
      )
```

---

## 47. Parser de evento postfix

```nim
proc isPostfixChangedEvent(
  condition: NimNode
): bool {.compileTime.} =
  if condition.kind notin {
    nnkCommand,
    nnkCall
  }:
    return false

  if condition.len != 2:
    return false

  let eventName =
    nodeName(condition[1])

  let statePath =
    flattenDotPath(condition[0])

  result =
    eventName == "changed" and
    statePath.len >= 2 and
    statePath[0] == "states"
```

```nim
proc parsePostfixChangedEvent(
  condition: NimNode
): PlasticStateEventPlan {.compileTime.} =
  let path =
    flattenDotPath(condition[0])

  result.stateName = path[1]
  result.eventKind = psekChanged
  result.source = condition.copyNimTree()

  if path.len > 2:
    result.propertyPath =
      path[2 .. ^1]
```

---

## 48. Parser do `when`

```nim
proc parseStateWhen(
  node: NimNode
): PlasticStateListenerPlan {.compileTime.} =
  if node.kind != nnkWhenStmt:
    error(
      "Esperava listener when.",
      node
    )

  let branch = node[0]
  let condition = branch[0]
  let body = branch[1]

  result.source =
    node.copyNimTree()

  result.effects =
    parseEffects(body)

  if isPostfixChangedEvent(condition):
    result.kind = pslEvent
    result.events.add(
      parsePostfixChangedEvent(
        condition
      )
    )
    return

  result.kind = pslCondition
  result.condition =
    condition.copyNimTree()

  collectStateDependencies(
    condition,
    result.dependencies
  )
```

---

# Parte XVI — Validação

## 49. Regras mínimas

O macro deve rejeitar:

1. entidade duplicada;
2. campo duplicado;
3. relação para entidade inexistente;
4. estado duplicado;
5. referência a estado inexistente;
6. componente duplicado;
7. parte visual duplicada no mesmo componente;
8. janela foreign duplicada;
9. espaço OKF duplicado;
10. operação ORM inexistente;
11. operação OKF inexistente;
12. operação foreign inexistente;
13. `agent` sem `purpose`;
14. condição reativa sem dependência de estado;
15. `changed` fora de `states.<caminho>`;
16. caminho de asset inexistente ao emitir instalador;
17. `upgradeCode` inválido;
18. versão MSI inválida;
19. ausência do modelo ou do binário local;
20. diretórios de dados ausentes após instalação.

---

# Parte XVII — Geração

## 50. Gerador principal

```nim
proc generateApplication(
  plan: PlasticApplicationPlan
): NimNode {.compileTime.} =
  let applicationSymbol =
    genSym(
      nskLet,
      "plasticApplication"
    )

  let installationCode =
    generateInstallation(
      plan.installation,
      applicationSymbol
    )

  let ormCode =
    generateOrm(
      plan.orm,
      applicationSymbol
    )

  let okfCode =
    generateOkf(
      plan.okf,
      applicationSymbol
    )

  let componentCode =
    generateComponents(
      plan.components,
      applicationSymbol
    )

  let stateCode =
    generateStates(
      plan.states,
      plan.stateListeners,
      applicationSymbol
    )

  let foreignElementCode =
    generateForeignElementsFromRenderTrees(
      plan.components,
      plan.globalRenderStack,
      applicationSymbol
    )

  let agentCode =
    generateAgents(
      plan.agents,
      applicationSymbol
    )

  let renderCode =
    generateRenderStack(
      plan.globalRenderStack,
      applicationSymbol
    )

  result = quote do:
    block:
      let `applicationSymbol` =
        newPlasticApplication(
          `newLit(plan.name)`
        )

      `installationCode`
      `ormCode`
      `okfCode`
      `componentCode`
      `stateCode`
      `foreignElementCode`
      `agentCode`
      `renderCode`

      `applicationSymbol`.finalize()
      `applicationSymbol`
```

---

## 51. Macro final

```nim
macro glaucoplastic*(
  applicationName: untyped,
  body: untyped
): untyped =
  var plan =
    parseApplication(
      applicationName,
      body
    )

  validateApplication(plan)

  deriveOrmOperations(plan)
  deriveComponentPaths(plan)
  deriveStateDependencies(plan)
  deriveAgentCapabilities(plan)
  deriveInstallationPaths(plan)

  when defined(
    glaucoplasticEmitInstallerManifest
  ):
    emitInstallerManifestAtCompileTime(
      plan.installation
    )

  result =
    generateApplication(plan)
```

---

# Parte XVIII — Inicialização de runtime

## 52. `validateInstallation`

```nim
proc validateInstallation*(
  application: PlasticApplication
) =
  let requiredDirectories = @[
    application.installation.dataPath,
    application.installation.okfPath,
    application.installation.gitMemoryPath,
    application.installation.sessionPath
  ]

  for path in requiredDirectories:
    if not dirExists(path):
      raise newException(
        IOError,
        "Diretório de instalação ausente: " &
        path
      )

  validateLocalModelAssets(
    application
  )
```

---

## 53. `run`

```nim
proc run*(
  application: PlasticApplication
) =
  application.validateInstallation()

  application.orm.open()
  application.okf.open()
  application.gitMemory.open()

  application.states.initialize()
  application.frontendServer.start()
  application.frontend.start()

  if application.agents.len > 0:
    application.llama.start()
    application.rlm.start()
    application.agents.start()

  application.frontend.renderInitial()
  application.frontend.openMainWindow()
  application.frontend.runEventLoop()
```

---

# Parte XIX — Ordem recomendada de implementação

## 54. Etapa 1: confirmar a gramática

Criar testes `treeRepr` para:

```nim
when states.ObraSelecionada changed:
```

```nim
Painel(titulo, estado):
```

```nim
section(part = Root, class = "container"):
```

```nim
outroEstado = {
  titulo: titulo + "x",
  contador: 1
}
```

---

## 55. Etapa 2: parser sem geração

Implementar:

```text
normalização
ProductPlan
InstallationPlan
OrmPlan
OkfPlan
ComponentPlan
StatePlan
StateListenerPlan
ForeignElementPlan derivado do render
AgentPlan
ApplicationPlan
```

Adicionar `describe(plan)` para inspecionar o resultado.

---

## 56. Etapa 3: instalação

Implementar:

```text
parser de installation
emissão de installer.json
script MSI
criação das pastas pelo MSI
validateInstallation
```

Validar primeiro sem agentes.

---

## 57. Etapa 4: ORM e estados

Implementar:

```text
SQLite
entidades
operações básicas
inicialização de estados
atribuições
evento changed
condições de borda
fila de efeitos
```

---

## 58. Etapa 5: frontend

Implementar:

```text
servidor interno
janela principal
render de tags
componentes
parts
interface jsDOM-like
selector/querySelector
ponte JS
```

---

## 59. Etapa 6: elemento nativo `foreign`

Implementar primeiro no Windows:

```text
nó nativo dentro de render
host visual e sincronização de bounds
WebContentsView com WebView2
URL reativa
status CSS
navigate
documentStart
loaded
evalJs
postMessage
close
```

Depois criar os backends Linux e macOS sob a mesma interface.

---

## 60. Etapa 7: modelo e RLM

Implementar:

```text
validação de assets
processo llama-server
health check
cliente /v1
sessões
instruções estruturadas
capabilities
subquery
answer
```

---

## 61. Etapa 8: memória Git e OKF

Implementar:

```text
snapshots Git
memos
workspace OKF instalado
índices
busca
get
generate
update
skills
capabilities RLM
```

---

# Parte XX — Critérios de conclusão

A primeira versão é funcional quando:

1. `src/app.nim` compila usando uma única macro;
2. o parser reconhece todas as seções;
3. `when states.X changed:` funciona ou possui pré-processamento documentado;
4. o MSI é configurado em `src/app.nim`;
5. o script gera um MSI;
6. o MSI instala executável, llama-server, DLLs e GGUF;
7. o MSI cria `data`, `okf`, `.glauco/memory` e `.glauco/sessions`;
8. o runtime não cria a pasta OKF;
9. a aplicação valida a instalação;
10. `orm.Entidade.operação` persiste dados;
11. estados inicializam por expressão e construtor;
12. componentes renderizam tags;
13. partes visuais oferecem getters e setters jsDOM-like;
14. `render:` funciona dentro de listeners e agentes;
15. um elemento nativo `foreign` abre uma URL externa dentro da árvore visual;
16. `<Componente>.<parteForeign>.evalJs` retorna dados;
17. o modelo local responde pelo `llama-server`;
18. agentes executam ciclos RLM;
19. agentes consultam memória Git;
20. agentes consultam e geram OKFs;
21. a `proc runMacroObras` inicia a aplicação completa.

---

## 63. Resultado arquitetural

```text
src/app.nim
    ↓
glaucoplastic MacroObras:
    ↓
parser monolítico
    ↓
PlasticApplicationPlan
    ↓
validação e derivação
    ↓
geração de código Nim
    ↓
PlasticApplication
    ├── instalação
    ├── ORM
    ├── estados
    ├── componentes
    ├── renderização
    ├── WebView principal
    ├── elementos WebContents foreign
    ├── servidor interno do frontend
    ├── llama-server local
    ├── agentes RLM
    ├── memória Git
    └── OKF
```

O arquivo `glaucoplastic.nim` constitui o framework inteiro. O arquivo `src/app.nim` constitui a declaração do produto, a configuração do instalador e o ponto de execução.

---

# Apêndice A — Regras normativas corrigidas

As seguintes regras prevalecem sobre qualquer exemplo anterior:

1. `foreign` é um nó visual nativo usado dentro de `render:`.
2. `foreign` recebe uma URL e representa uma `WebContentsView`.
3. `foreign` pode declarar `statusCss`, scripts de `documentStart` e eventos.
4. O acesso ao elemento ocorre pelo caminho visual do componente, como `Painel.Documentacao.evalJs(...)`.
5. Não existe seção superior `foreign:`.
6. Não existe seção `public:`.
7. Agentes são declarados dentro de `agents:`.
8. Cada filho de `agents:` tem a forma `NomeDoConstrutor(nomeDaInstancia, propriedadesPersonalizadas):`.
9. O corpo do agente pode conter `purpose`, declarações, `render:` e listeners `when`.
10. Todo agente construído pela DSL continua sendo RLM, com memória Git e OKF incorporados.
