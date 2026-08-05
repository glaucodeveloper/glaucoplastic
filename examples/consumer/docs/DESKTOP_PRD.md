# PRD de Desktop

## Nome do projeto

GlaucoPlastic Desktop Launchpad

## Visao

Criar uma aplicacao desktop de referencia para demonstrar o protocolo de instalacao do GlaucoPlastic, a declaracao via `nimble` e a interface webview com layout Carbon.

## Problema

Projetos Nim que adotam o GlaucoPlastic precisam de um caminho claro para:

- declarar instalacao e diretórios persistentes,
- iniciar o runtime desktop sem ambiguidade,
- documentar o uso de `okfs` e `agents`,
- expor um painel inicial que sirva como guia operacional.

## Objetivos

- Fornecer uma home page desktop compacta e legivel.
- Exibir o protocolo de instalacao em um formato consumivel.
- Mostrar o PRD e o status do runtime no mesmo painel.
- Servir como modelo para futuros projetos Nim distribuiveis por `nimble`.

## Publico-alvo

- Desenvolvedores Nim que estao adotando o GlaucoPlastic.
- Maintainers que precisam de uma referencia de instalacao.
- Times de produto que querem alinhar desktop, runtime e documentacao.

## Escopo

### Dentro do escopo

- Home page Carbon com cards de operacao.
- Protocolo de instalacao para projetos Nim por `nimble`.
- PRD de desktop enxuto e reutilizavel.
- Exposicao do estado do runtime, OKF e agente principal.

### Fora do escopo

- Empacotamento multiplataforma completo.
- Sincronizacao remota.
- Fluxos colaborativos em tempo real.
- Editor visual de manifesto.

## Requisitos funcionais

1. A tela inicial deve apresentar resumo do projeto.
2. O usuario deve conseguir ler os passos de instalacao sem sair da home.
3. O layout deve distinguir instalacao, PRD e runtime.
4. O painel deve deixar claro quando o workspace esta pronto.
5. O exemplo deve continuar executando como aplicacao desktop.

## Requisitos nao funcionais

- Interface com densidade Carbon.
- Tipografia de leitura curta e contraste alto.
- Estrutura plana, sem brilho excessivo.
- Boa leitura em desktop e em telas menores.

## Indicadores de sucesso

- O exemplo compila com `nimble build`.
- A documentacao de instalacao esta acessivel no repo.
- A home page transmite o fluxo de uso em menos de 30 segundos.
- O PRD pode ser reaproveitado como baseline para um projeto real.

## Entregaveis

- `docs/INSTALLATION_PROTOCOL.md`
- `docs/DESKTOP_PRD.md`
- Home page Carbon no consumer example

## Riscos

- Misturar documento operacional com comportamento de runtime.
- Excesso de informacao na homepage.
- Divergencia entre o manifesto documentado e o manifesto real do projeto.

## Decisao de produto

Este projeto deve atuar como landing page tecnica e como referencia operacional do framework. A prioridade e esclarecer como um projeto Nim instala e executa o GlaucoPlastic, nao criar um marketing site.
