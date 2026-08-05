# GlaucoPlastic Nim

Pacote Nimble importável com o framework concentrado em um único arquivo:

```text
src/glaucoplastic.nim
```

O monólito contém o parser compile-time da DSL, plano serializado, configuração
de MSI, estados, ORM persistente, OKF, memória Git, processo `llama-server`,
RLM, agentes e o contrato nativo dos elementos `foreign` WebContentsView.

## Estrutura

```text
glaucoplastic-nim/
├── glaucoplastic.nimble
├── src/glaucoplastic.nim
├── examples/macroobras/app.nim
├── examples/consumer/
├── scripts/
├── docs/
├── runtime/llama/
└── models/
```

O ZIP não incorpora o GGUF nem os binários do `llama.cpp`, porque esses
arquivos são grandes e variam por backend. Os scripts baixam os executáveis
para pastas locais do projeto:

```text
runtime/llama/linux-x64/bin/
runtime/llama/windows-x64/bin/
```

Nenhum binário do `llama.cpp` é instalado globalmente.

## Instalação Linux

```bash
chmod +x scripts/*.sh
./scripts/install-all-linux.sh
```

O bootstrap:

1. instala dependências de compilação e WebKitGTK quando disponível;
2. instala Nim/Nimble;
3. baixa o runtime mais recente do `llama.cpp`;
4. usa ou baixa o Qwen3-4B Q4_K_M em `~/models/Qwen3-4B`;
5. registra o pacote com `nimble develop`.

Backends do runtime:

```bash
LLAMA_BACKEND=cpu ./scripts/install-all-linux.sh
LLAMA_BACKEND=vulkan ./scripts/install-all-linux.sh
LLAMA_BACKEND=rocm ./scripts/install-all-linux.sh
```

## Instalação Windows

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-all-windows.ps1 -Backend cpu
```

Backends aceitos:

```text
cpu
vulkan
cuda12
cuda13
```

O bootstrap instala Nim pelo WinGet quando necessário, baixa o runtime do
`llama.cpp`, baixa o modelo, instala o WebView2 Evergreen Runtime e registra o
pacote com `nimble develop`.

Para preservar um WebView2 já administrado externamente:

```powershell
.\scripts\install-all-windows.ps1 -Backend cpu -SkipWebView2
```

## Modelo padrão

```text
repositório: Qwen/Qwen3-4B-GGUF
arquivo:     Qwen3-4B-Q4_K_M.gguf
pasta:       ~/models/Qwen3-4B/
```

O framework procura primeiro `GLAUCOPLASTIC_MODEL_PATH` e depois
`~/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf`.

Linux:

```bash
./scripts/configure-qwen3-model.sh
```

Windows:

```powershell
.\scripts\configure-qwen3-model.ps1
```

Sobrescritas:

```bash
GLAUCOPLASTIC_MODEL_PATH="$HOME/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf" \
./scripts/configure-qwen3-model.sh
```

## Uso como dependência Nimble

No diretório deste pacote:

```bash
nimble develop -y
```

No projeto consumidor:

```nim
# meu_projeto.nimble
version = "0.1.0"
srcDir = "src"

requires "nim >= 2.0.0"
requires "glaucoplastic >= 0.1.0"
```

Código:

```nim
import glaucoplastic

glaucoplastic MinhaAplicacao, app:
  product:
    title "Minha Aplicação"

  okfs:
    Geral:
      purpose "Conhecimento da aplicação."

  components:
    Home(titulo):
      render:
        main(part = Root):
          h1(part = Titulo) titulo
          foreign(part = Portal, url = "https://example.com"):
            statusCss:
              loading ":host { opacity: .5; }"
              ready ":host { opacity: 1; }"

  states:
    Titulo string = "Minha Aplicação"

    when states.Titulo changed:
      Home.Titulo.textContent = states.Titulo

  agents:
    Assistente("assistente", okfPrincipal = Geral):
      purpose "Auxilie o usuário usando estado, ORM, Git e OKF."

  render:
    Home(states.Titulo)
```

Um projeto consumidor completo está em `examples/consumer`.

## Exemplo MacroObras

```bash
nim c -r --path:src examples/macroobras/app.nim --prepare-dev
nim c -r --path:src examples/macroobras/app.nim --show-plan
nim c -r --path:src examples/macroobras/app.nim
```

`--prepare-dev` é uma operação explícita para testes. A inicialização normal do
framework não cria `data`, `okf`, `.glauco/memory` ou `.glauco/sessions`. Na
instalação Windows, esses diretórios são criados pelo MSI.

## MSI configurado na aplicação

A configuração reside no corpo `installation:` de `src/app.nim`. Para o
exemplo:

```bash
./scripts/install-llama-runtime-windows.sh
./scripts/configure-qwen3-model.sh
./scripts/build-msi.sh
```

Escolha o backend Windows durante a preparação cruzada:

```bash
LLAMA_WINDOWS_BACKEND=vulkan ./scripts/install-llama-runtime-windows.sh
```

Em Linux, o gerador usa Nim, MinGW-w64, `wixl` e Python. O fluxo:

1. compila o emissor de manifesto;
2. lê nome, versão e executável declarados pela aplicação;
3. compila o `.exe` Windows;
4. inclui runtime, DLLs e modelo declarados em `package:`;
5. gera o WXS;
6. cria os diretórios de dados e espaços OKF;
7. produz MSI e SHA-256.

## Elemento `foreign`

`foreign(...)` é um nó nativo dentro de `render:`. O runtime derivado contém:

- URL;
- status (`idle`, `loading`, `ready`, `navigating`, `failed`, `closed`);
- CSS por status;
- scripts de início do documento;
- planos de eventos;
- `navigate`, `evalJs`, injeção e mensagens.

O monólito fornece `PlasticForeignBackend`. O projeto consumidor registra o
backend nativo de seu toolkit. O ZIP inclui um backend mock para testes.

O contrato do `foreign` agora é tratado como uma view nativa filha da árvore do
host, sincronizada por mensagens do DOM para o runtime. No Linux isso é feito
com WebKitGTK; no Windows, o mesmo contrato é atendido por WebView2. O bridge
não depende de polling de posição.

O `clientFolder` do WebView também cai automaticamente no diretório de
execução (`./webview/Default`) e pode ser sobrescrito pela aplicação quando
necessário.

## Agentes

A DSL usa a seção plural:

```nim
agents:
  Analista(
    "analista-administrativo",
    especialidade = "obras",
    okfPrincipal = Obras
  ):
    purpose "Analise a obra."

    render:
      span "Agente disponível"

    when states.ObraSelecionada changed:
      discard
```

Todo agente recebe RLM, modelo local, memória Git, OKF, ORM, estados e
capabilities de WebContents.

## Validação

```bash
python3 scripts/validate-project.py
bash -n scripts/*.sh
python3 -m py_compile scripts/render_wix.py
```

Com Nim instalado:

```bash
nimble test
```

A ferramenta `plasticTree` imprime a AST e deve ser usada primeiro para confirmar
a forma `when states.X changed:` na versão Nim escolhida.

## Estado técnico

O pacote entrega uma base de implementação integrada, com persistência e
bootstrap reais. O parser transforma o corpo em plano JSON e deriva estados,
componentes, agentes, OKFs e elementos foreign. A emissão de código executável
para cada expressão arbitrária presente nos corpos da DSL ainda é uma camada a
ser expandida sobre esse plano. O backend físico de WebContents também deve ser
registrado pelo aplicativo consumidor.

## Interface Linux da versão 0.1.8

A execução normal materializa a DSL em uma janela GTK/WebKitGTK:

```bash
./scripts/install-ui-linux.sh

cd examples/consumer
nimble run -- --prepare-dev
nimble run
```

A opção `-d:glaucoplasticHeadless` mantém o runtime sem janela e usa o backend mock de `foreign`.
