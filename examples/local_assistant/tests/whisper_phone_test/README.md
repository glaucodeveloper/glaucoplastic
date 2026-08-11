# Teste Nim isolado: captura + whisper.cpp

Este teste não usa WebView, bindings ou o Local Assistant. Ele separa:

1. captura de áudio;
2. análise do WAV;
3. normalização por FFmpeg;
4. transcrição pelo `whisper-cli`.

## Instalar dentro do projeto

```bash
./install.sh "$HOME/dev/glaucoplastic"
```

## Comparação principal

Fonte virtual do sistema:

```bash
./run-system.sh 6
```

Canal direto do celular:

```bash
./run-phone-api.sh 6
```

## Testar arquivo conhecido

```bash
nimble run -- \
  --mode=file \
  --input=/caminho/voz.wav
```

## Como interpretar

- `phone-api` correto e `system` incorreto:
  problema no FIFO/fonte virtual PipeWire.
- ambos incorretos:
  problema na captura Android, volume ou áudio recebido.
- arquivo conhecido correto, mas capturas incorretas:
  modelo e `whisper.cpp` estão funcionando.
- RMS abaixo de `0.001`:
  silêncio quase completo.
- RMS abaixo de `0.004`:
  sinal muito baixo e sujeito a `[MÚSICA DE FUNDO]`.

Os WAVs e o TXT ficam preservados no diretório exibido pelo teste.
