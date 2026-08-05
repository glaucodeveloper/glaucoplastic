# Validação da revisão 0.1.8

## Verificado neste ambiente

- estrutura do pacote;
- sintaxe dos scripts Bash com `bash -n`;
- versão Nimble atualizada para 0.1.8;
- teste configurado com `-d:glaucoplasticHeadless`;
- consumer interno sem dependência do catálogo Nimble;
- `config.nims` apontando para `../../src`;
- árvore HTML derivada da DSL coberta por assertions no teste;
- preservação de `runtime`, `models` e `.env.glaucoplastic` pelo instalador de atualização.

## Validação que precisa ocorrer no ambiente Manjaro

O ambiente de geração deste pacote não possui o compilador Nim nem uma sessão GTK. Portanto, a compilação da nova seção FFI e a abertura real da janela precisam ser confirmadas com Nim 2.2.10 no computador de destino.

Comandos:

```bash
nimble test
cd examples/consumer
nimble run -- --prepare-dev
nimble run
```

O último comando deve permanecer em execução até a janela ser fechada.
