# Fontes técnicas usadas pelos instaladores

- llama.cpp releases: https://github.com/ggml-org/llama.cpp/releases
- llama.cpp server: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- Hugging Face CLI: https://huggingface.co/docs/huggingface_hub/guides/cli
- Modelo padrão: https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF
- WebView2: https://developer.microsoft.com/microsoft-edge/webview2/

Os scripts consultam a release mais recente do llama.cpp pela API do GitHub.
O modelo e os runtimes não são incluídos no ZIP devido ao tamanho; são baixados
explicitamente pelo usuário, respeitando licenças e autenticação do provedor.
