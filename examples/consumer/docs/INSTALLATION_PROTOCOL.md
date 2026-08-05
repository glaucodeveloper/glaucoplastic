# Protocolo de Instalacao do GlaucoPlastic

## Objetivo

Definir um fluxo repetivel para instalar o GlaucoPlastic em qualquer projeto Nim gerenciado por `nimble`, mantendo a declaracao da aplicacao, o runtime e os diretórios persistentes previsiveis.

## Premissas

- O projeto consumidor usa Nim 2.x.
- O projeto possui um `*.nimble` valido.
- O pacote `glaucoplastic` esta disponivel no ambiente do `nimble`.
- A aplicacao declara seus diretórios persistentes no manifesto da instalacao.

## Contrato minimo do projeto

```nim
version = "0.1.0"
srcDir = "src"
bin = @["app"]

requires "nim >= 2.0.0"
requires "glaucoplastic >= 0.1.0"
```

## Sequencia de instalacao

1. Adicione `glaucoplastic` em `requires` no arquivo `*.nimble`.
2. Importe o pacote no modulo principal da aplicacao.
3. Declare a aplicacao com a macro `glaucoplastic NomeDaAplicacao, app:`.
4. Defina `product`, `installation`, `orm`, `okfs`, `states`, `components` e `agents` conforme a necessidade do projeto.
5. Configure `product.safeStorage` quando o projeto precisar de credenciais no keyring do sistema.
6. Execute a aplicacao com `app.run()` no fluxo normal.
7. Valide a instalacao com `app.validateInstallation()` antes do primeiro arranque.
8. Gere o manifesto de instalacao quando o projeto precisar empacotar o desktop.

## Estrutura recomendada

```text
meu-projeto/
├── src/
│   └── app.nim
├── meu-projeto.nimble
├── docs/
│   ├── INSTALLATION_PROTOCOL.md
│   └── DESKTOP_PRD.md
└── build/
```

## Fluxo de desenvolvimento

1. Instale dependencias.
2. Rode o build do `nimble`.
3. Abra a aplicacao em modo desktop.
4. Ajuste a instalacao somente depois de validar os caminhos persistentes.

## Criterios de validacao

- O projeto compila com `nimble build`.
- O manifesto de instalacao e gerado sem erro.
- O diretorio de dados existe antes da primeira escrita em ORM, OKF ou memoria.
- A aplicacao inicia em desktop sem depender de bootstrap manual fora do protocolo.

## Exemplo de uso

```nim
import glaucoplastic

glaucoplastic MinhaAplicacao, app:
  product:
    title "Minha Aplicacao"
    version "0.1.0"
    safeStorage:
      service "minha-aplicacao.access"
      label "Minha Aplicacao"

  installation:
    windowsMsi:
      productName "Minha Aplicacao"
      manufacturer "GlaucoPlastic"
      version "0.1.0"
      scope perUser
      executable "minha-aplicacao.exe"

      installDirectory:
        root localAppDataPrograms
        path "MinhaAplicacao"

      applicationData:
        root localAppData
        path "MinhaAplicacao"
        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"
```

## Observacao operacional

O runtime valida e prepara os diretorios instalados automaticamente durante `validateInstallation()` e `run()`. A criacao inicial dos caminhos continua prevista no pacote/instalador, mas nao depende mais de um bootstrap ad hoc em producao.
