# Fluxo vertical responsivo da ISOCON

Patch aditivo para encaixar páginas curtas na altura da janela e preservar
páginas longas por meio de `overflow-y: auto`.

## Comportamento público

- `isocon-app` funciona como shell vertical;
- `#publicPage` ocupa o espaço disponível;
- o rodapé permanece no fim da tela em páginas curtas;
- páginas longas continuam usando a rolagem normal do navegador;
- heróis usam altura responsiva, sem altura fixa;
- sidebar de segmentos, menu móvel e chat recebem scroll-y quando necessário.

## Administração

- a janela administrativa ocupa `100dvh`;
- sidebar e topbar permanecem encaixadas;
- `.admin-main` recebe a rolagem vertical;
- login e formulários longos continuam acessíveis.

## Aplicação

```bash
chmod +x apply-patch.sh
./apply-patch.sh "$PWD"
```
