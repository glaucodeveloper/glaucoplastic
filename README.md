# GlaucoPlastic

Framework monolítico em Nim para aplicações desktop/web com DSL compilada por macro, interface WebView, elementos web externos, estado reativo, ORM, OKF, agentes locais, RLM e memória semântica Metis.

O projeto é importado como uma biblioteca Nimble:

```nim
import glaucoplastic
```

A aplicação consumidora é declarada dentro de uma macro:

```nim
glaucoplastic ConsumerApplication, application:
  # Nim normal e seções da DSL convivem no mesmo corpo.
```

A macro recebe a AST da aplicação, reconhece as estruturas da DSL, produz um plano interno e instancia os runtimes necessários. O corpo continua aceitando `let`, `if`, `for`, chamadas, procedimentos, JSON e demais construções normais de Nim.

> Estado atual: framework pessoal e experimental em desenvolvimento ativo. A implementação desktop atual está concentrada em Linux/WebKitGTK, com abstrações para WebView2, WebKitGTK e WKWebView.

---

## Objetivo

O GlaucoPlastic organiza uma aplicação como uma narrativa compilável:

- propriedades do produto e instalação;
- estados e relações reativas;
- componentes e árvore visual;
- páginas externas integradas por `foreign`;
- persistência por ORM e OKF;
- modelos locais;
- agentes definidos por domínio;
- capacidades RLM executadas pelo runtime.

A DSL não substitui Nim. Ela delimita estruturas que a macro precisa interpretar, enquanto o restante do corpo permanece código Nim comum.

---

## Estrutura central

```text
Código da aplicação
        │
        ▼
macro glaucoplastic
        │
        ├── leitura direta da AST
        ├── validação das seções
        ├── criação do PlasticPlan
        └── geração do código de runtime
                │
                ▼
        PlasticApplication
        ├── PlasticStateRuntime
        ├── PlasticOrmRuntime
        ├── PlasticOkfRuntime
        ├── PlasticWebViewRuntime
        ├── PlasticForeignRuntime
        ├── PlasticLlamaRuntime
        ├── PlasticRlmRuntime
        ├── PlasticMetisMemory
        └── PlasticAgent
```

O framework permanece monolítico em `src/glaucoplastic.nim`. A aplicação consumidora importa esse módulo e descreve o produto dentro de um único corpo macro.

### Estrutura do repositório

```text
glaucoplastic/
├── src/
│   └── glaucoplastic.nim
├── examples/
│   └── consumer/
│       ├── src/
│       │   └── consumer.nim
│       ├── scripts/
│       └── consumer.nimble
├── config.nims
└── glaucoplastic.nimble
```

Diretórios de build, modelos, caches, perfis WebView, logs, bancos locais e dados `.glauco` não pertencem ao histórico do repositório.

---

## Camadas funcionais

### Macro e plano

A macro analisa a AST em tempo de compilação e converte as seções reconhecidas em descritores e planos. Estados, componentes, hooks, entidades de ORM, espaços OKF, elementos `foreign`, agentes e instalação passam a possuir representação estrutural antes da execução.

Essa etapa permite que a sintaxe permaneça próxima do domínio da aplicação sem depender de interpretação textual em runtime.

### Aplicação e runtimes

`PlasticApplication` concentra as instâncias que formam a aplicação:

| Runtime | Responsabilidade |
|---|---|
| `PlasticStateRuntime` | Estados JSON, descritores e listeners |
| `PlasticOrmRuntime` | Entidades e persistência estruturada |
| `PlasticOkfRuntime` | Conhecimento explícito organizado em espaços |
| `PlasticWebViewRuntime` | Perfil persistente, cache, cookies e compatibilidade |
| `PlasticForeignRuntime` | Conteúdos web externos e comunicação com a aplicação |
| `PlasticLlamaRuntime` | Modelo GGUF servido por `llama.cpp` |
| `PlasticRlmRuntime` | Registro e execução de capabilities |
| `PlasticMetisMemory` | Memória semântica local e sessões |
| `PlasticAgent` | Propósito, domínio, hooks, sessão e execução semântica |

### Estado reativo

Os estados são declarados no corpo da aplicação:

```nim
states:
  Search isset {
    query: "",
    status: "Pronto",
    candidates: [],
    selectedTitle: "",
    selectedHref: "",
    collectionVersion: 0
  }

  when Search changed:
    Home.Status.textContent = states.Search.status
```

Alterações passam pelo runtime de estado, preservam valores JSON e acionam listeners vinculados à entidade correspondente.

### Componentes e renderização

Componentes descrevem partes reutilizáveis da árvore visual:

```nim
components:
  SearchPanel(query, status):
    render:
      section Root:
        input SearchInput(value = query)
        p Status status
```

A seção `render` produz a árvore usada pelo backend desktop. Elementos identificados podem receber propriedades, eventos e atualizações provenientes dos estados.

---

## `foreign`: conteúdo web como elemento da aplicação

Um `foreign` representa uma página externa em um WebView nativo, preservando sua própria navegação e participando do layout da aplicação.

```nim
portal = foreign Portal(
  url = states.Search.url,
  title = "YouTube search preview"
):
  documentStart:
    evalJs "window.__GLAUCOPLASTIC_FOREIGN__ = true;"

  statusCss:
    loading ":host { opacity: .70; }"
    ready ":host { opacity: 1; }"
```

O runtime oferece:

- navegação para URLs externas;
- perfil persistente de cookies e armazenamento;
- scripts executados no início do documento;
- avaliação de JavaScript;
- eventos de carregamento e mudança de URL;
- comunicação entre o documento e o estado da aplicação;
- posicionamento do WebView nativo conforme a árvore visual.

Exemplo de fluxo:

```text
entrada do usuário
    → alteração de Search.url
    → foreign.navigate
    → página externa carregada
    → listener consulta o DOM
    → Search.candidates recebe os itens
    → agente escolhe um resultado
    → state.set atualiza a interface
```

---

# Semântica de agentes

Um agente do GlaucoPlastic não é somente um prompt nomeado. A declaração produz uma estrutura com identidade, propósito, domínio, sessão de memória, principal OKF, condições RLM, funções e hooks reativos.

```nim
agents:
  AssistenteGeral(
    "assistente-geral",
    okfPrincipal = Geral,
    session = "consumer-youtube"
  ):
    purpose """
    Selecionar o resultado mais adequado entre candidatos já coletados.
    """

    dominio:
      state Search:
        "Estado da busca e dos candidatos."

      when changes:
        """
        Compare states.Search.query com
        states.Search.candidates.items.
        """
        into states.Search

    rlm:
      conditions:
        """
        Escolha somente itens presentes nos candidatos.
        Use state.set para registrar a seleção.
        """
```

## O que cada parte significa

### Identidade

```nim
AssistenteGeral("assistente-geral", ...)
```

O primeiro nome representa o construtor semântico reconhecido pela DSL. O valor entre aspas identifica a instância concreta registrada na aplicação.

### `purpose`

Define o papel geral do agente. O propósito participa do contexto de execução, porém não determina sozinho quando o agente deve agir.

### `dominio`

A seção `dominio` declara as entidades e relações observadas pelo agente.

```nim
state Search:
```

indica que `Search` pertence ao domínio operacional desse agente.

```nim
when changes:
  ...
  into states.Search
```

associa uma mudança de estado a uma ação semântica e define o contexto principal entregue ao agente.

A semântica do domínio é convertida em plano pela macro. O runtime registra listeners e transforma cada ocorrência em um job de agente.

### `rlm`

A seção `rlm` restringe o modo de decisão e as capabilities permitidas pela tarefa. O modelo não executa Nim arbitrário. Ele devolve um programa JSON pequeno que o runtime valida e executa.

### `render`

Um agente também pode participar da composição visual. Esse uso é adequado para agentes ligados a uma parte específica da interface, como uma tela de inicialização, um assistente contextual ou um painel operacional.

---

## Execução assíncrona dos agentes

Hooks de agente são executados fora da thread da interface.

```text
mudança de estado
    │
    ▼
listener do domínio
    │
    ▼
fila do agente
    │
    ├── snapshot imutável do estado
    └── job identificado por entidade e hook
            │
            ▼
      worker assíncrono
            │
            ├── monta o contexto RLM
            ├── consulta o modelo local
            ├── valida o JSON
            └── prepara escritas de estado
                    │
                    ▼
          thread principal da interface
                    │
                    └── aplica state.set e renderiza
```

Cada agente possui sua própria fila e worker. Jobs equivalentes podem ser consolidados para preservar o evento mais recente. O worker lê um snapshot do estado e não modifica diretamente o runtime visual.

Chamadas de `state.set` realizadas pelo agente são acumuladas e aplicadas depois pela thread principal. Essa separação evita que uma inferência longa congele a janela ou altere estruturas de UI a partir de uma thread secundária.

---

# RLM e capabilities

RLM é a camada que transforma a resposta do modelo em operações explícitas da aplicação.

O formato esperado é:

```json
{
  "instructions": [
    {
      "capability": "state.set",
      "arguments": {
        "Search.selectedTitle": "Título escolhido",
        "Search.selectedHref": "https://..."
      }
    }
  ],
  "answer": {
    "selectedTitle": "Título escolhido",
    "selectedHref": "https://..."
  }
}
```

O runtime:

1. monta o contexto do agente;
2. inclui domínio, estados e capabilities;
3. consulta o endpoint local;
4. extrai e valida o JSON;
5. repete a resposta quando o JSON estiver incompleto;
6. executa cada capability;
7. retorna `answer` ou encerra após escritas de estado válidas.

### Capabilities atuais

| Grupo | Capabilities |
|---|---|
| Estado | `state.get`, `state.set` |
| ORM | `orm.find`, `orm.insert` |
| OKF | `okf.list`, `okf.search`, `okf.get`, `okf.persist`, `okf.tree` |
| Memória | `memory.query`, `memory.status`, `memory.save`, `memory.newSession`, `memory.rebuild`, `memory.reset` |
| WebContents | `webcontents.list`, `webcontents.describe`, `webcontents.eval_js`, `webcontents.navigate` |

Capabilities ligadas à interface precisam respeitar a thread principal. A escrita de estados já passa pela fila de resultados do agente. Operações de WebContents devem ser tratadas como ações de UI.

Variáveis úteis:

```bash
GLAUCOPLASTIC_LLM_DEBUG=1
GLAUCOPLASTIC_LLM_DEBUG_RESPONSE=1
GLAUCOPLASTIC_RLM_MAX_TOKENS=1024
GLAUCOPLASTIC_RLM_RESPONSE_ATTEMPTS=2
GLAUCOPLASTIC_RLM_ENABLE_THINKING=0
GLAUCOPLASTIC_LLM_TIMEOUT_MS=900000
```

---

# Llama, Metis, OKF e Git

Essas partes cumprem funções diferentes.

```text
llama.cpp  → raciocínio e geração
Metis      → memória semântica da execução
OKF        → conhecimento explícito da aplicação
Git        → histórico, proveniência e versões
```

## Modelo servido por `llama.cpp`

O modelo GGUF funciona como backbone do agente. Ele recebe o contexto RLM, escolhe capabilities, produz argumentos e formula a resposta.

Sua função principal é decidir e gerar. O histórico completo da aplicação não precisa permanecer no contexto imediato do modelo.

## Metis

Metis é a memória semântica local.

Ele registra trocas, organiza sessões e produz uma representação treinável ou consultável da experiência acumulada. O agente pode recuperar lembranças relacionadas por significado, mesmo quando os textos não possuem as mesmas palavras.

A implementação mantém artefatos como:

```text
.glauco/memory/
└── profiles/
    └── <profile>/
        ├── runtime.metis.pt
        ├── exchanges.jsonl
        ├── memory-events.jsonl
        └── sessions/
```

O runtime Metis usa Python local incorporado, Transformers e o checkpoint `IAAR-Shanghai/Metis-4B`. O worker de memória pode processar trocas de forma adiada, evitando que a resposta principal precise aguardar a consolidação semântica.

Metis responde principalmente:

> Qual experiência anterior possui relação semântica com esta situação?

## OKF

OKF representa conhecimento explícito e organizado.

Espaços OKF guardam documentos, propriedades, relações, fontes, metadados e materiais que precisam ser recuperados de forma determinística. Agentes consultam esse conteúdo por `okf.search`, `okf.get` e `okf.tree`.

OKF responde principalmente:

> Qual conhecimento foi registrado deliberadamente para este domínio?

## Git

Git representa memória histórica e versionada do projeto.

Ele registra mudanças em código, DSL, documentos e conhecimento textual versionável. Git fornece autoria, diff, rollback, branches e uma sequência auditável de decisões.

Git responde principalmente:

> O que mudou, quando mudou e em qual versão?

## Metis versus Git

| Propriedade | Metis | Git |
|---|---|---|
| Natureza | Memória semântica | Histórico versionado |
| Unidade principal | Trocas, eventos e representações | Arquivos, commits e diffs |
| Recuperação | Similaridade e contexto | Identidade, data, versão e conteúdo |
| Mutação | Consolidação do runtime | Commits explícitos |
| Auditoria humana | Indireta | Direta |
| Uso pelo agente | Recordação contextual | Proveniência e evolução |
| Arquivos grandes | Snapshot local fora do repositório | Código e documentos pequenos |
| Substitui o outro? | Não | Não |

Metis não deve ser armazenado diretamente no Git. Snapshots, checkpoints, modelos e caches são artefatos locais. Git deve guardar o código que define a memória, os formatos, os OKFs versionáveis e as decisões documentadas.

Na implementação atual:

- Metis está integrado ao runtime e disponível pelas capabilities `memory.*`;
- Git atua na camada do repositório e do histórico de desenvolvimento;
- ainda não existe uma capability RLM pública `git.*` no fonte atual;
- uma integração futura pode transformar alterações curadas de OKF em commits, preservando a distinção entre recordação semântica e registro auditável.

## Relação entre as três memórias

```text
interação recente
    │
    ├── exchanges.jsonl
    │       └── matéria-prima da memória
    │
    ├── Metis
    │       └── relações semânticas e recuperação contextual
    │
    ├── OKF
    │       └── conhecimento explícito selecionado
    │
    └── Git
            └── versões auditáveis de código e documentos
```

Uma informação pode atravessar as camadas:

1. surge em uma interação;
2. Metis preserva sua relevância semântica;
3. o agente ou a aplicação transforma a informação em conhecimento OKF;
4. documentos OKF selecionados podem ser versionados no Git.

---

# Preparação e distribuição dos modelos

Modelos não são baixados durante a execução normal da aplicação distribuída.

O fluxo esperado é:

```text
desenvolvimento
    → runtime/modelo preparado na máquina do desenvolvedor
    → nimble build
    → modelos copiados para a distribuição
    → cliente executa somente artefatos locais
```

Uma distribuição pode conter:

```text
dist/<produto>/
├── <executável>
└── models/
    ├── <modelo-gguf>
    └── metis/
        └── IAAR-Shanghai_Metis-4B/
```

Arquivos `.gguf`, `.safetensors`, snapshots Metis e diretórios `models/` permanecem fora do Git.

---

# Exemplo: busca assistida no YouTube

O consumer atual demonstra a relação entre UI, `foreign`, estados e agente:

```text
1. O usuário informa uma busca.
2. Search.url recebe a página de resultados.
3. O foreign navega para o YouTube.
4. O listener `Portal loaded` consulta os títulos visíveis no DOM.
5. Os itens são colocados em Search.candidates.
6. Search.collectionVersion é incrementado.
7. O hook do agente é enfileirado.
8. O RLM compara a query com os candidatos.
9. state.set grava selectedTitle, selectedHref e status.
10. A thread principal atualiza a interface.
```

A inferência não coleta o DOM. O listener do `foreign` realiza a coleta determinística; o agente recebe somente os dados já estruturados e executa a escolha semântica.

---

# Construção

## Requisitos gerais

- Nim 2.x;
- Nimble;
- backend WebView da plataforma;
- `llama-server` e modelo GGUF local;
- runtime Python e dependências do Metis;
- WebKitGTK no backend Linux atual.

## Consumer

```bash
cd examples/consumer
nimble build
```

Para executar com diagnóstico:

```bash
GLAUCOPLASTIC_UI_DEBUG=1 \
GLAUCOPLASTIC_LLM_DEBUG=1 \
GLAUCOPLASTIC_LLM_DEBUG_RESPONSE=1 \
nimble run --verbose
```

A build do consumer prepara a pasta de distribuição e inclui os modelos configurados. O runtime deve localizar os artefatos ao lado do executável e não iniciar download em uma instalação cliente.

---

# Dados locais

A aplicação configura sua área persistente a partir do runtime de instalação.

Exemplos de conteúdo local:

```text
<data-root>/
├── webview/
│   └── Default/
│       ├── data/
│       ├── cache/
│       └── cookies.sqlite
├── .glauco/
│   ├── okf/
│   └── memory/
└── bancos e arquivos próprios da aplicação
```

Dados de usuário, sessões, logs, caches, perfis WebView, modelos e builds devem permanecer ignorados pelo repositório.

---

# Limites atuais

- O framework está em evolução e a API ainda pode mudar.
- O backend Linux/WebKitGTK concentra a implementação desktop mais completa.
- A resposta dos modelos locais precisa obedecer ao protocolo JSON do RLM.
- A confiabilidade de `webcontents.eval_js` depende do backend e da thread de UI.
- Modelos grandes exigem planejamento de RAM, VRAM e distribuição.
- Memória Metis, conhecimento OKF e histórico Git permanecem camadas distintas.
- O repositório atual não expõe operações Git diretamente como capabilities de agente.

---

# Direção arquitetural

O GlaucoPlastic procura manter uma aplicação legível como uma composição de domínio:

```text
estrutura
    → propriedades
    → encaixe no domínio
    → relações
    → funções
    → execução
```

A macro fornece a estrutura; os runtimes preservam as propriedades; estados e agentes expressam relações; capabilities realizam funções; WebView, ORM, OKF, llama.cpp e Metis executam a aplicação concreta.
