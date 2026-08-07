import std/os
import glaucoplastic

let LocalAssistantRoot = currentSourcePath().parentDir

putEnv("GLAUCOPLASTIC_LLAMA_HOST", getEnv("GLAUCOPLASTIC_LLAMA_HOST", "127.0.0.1"))
putEnv("GLAUCOPLASTIC_LLAMA_PORT", getEnv("GLAUCOPLASTIC_LLAMA_PORT", "19191"))
putEnv("GLAUCOPLASTIC_MODEL_ALIAS", getEnv("GLAUCOPLASTIC_MODEL_ALIAS", "gemma-local"))
putEnv("GLAUCOPLASTIC_METIS_ENABLED", getEnv("GLAUCOPLASTIC_METIS_ENABLED", "1"))
putEnv("GLAUCOPLASTIC_VOICE_RECOGNITION", "phone-adb")
putEnv(
  "GLAUCOPLASTIC_WHISPER_MODEL",
  getEnv(
    "GLAUCOPLASTIC_WHISPER_MODEL",
    LocalAssistantRoot / ".runtime" / "whisper.cpp" / "models" / "ggml-base.bin"
  )
)
when defined(windows):
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalAssistantRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "Release" / "whisper-cli.exe"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_OFFICE_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_OFFICE_PYTHON",
      LocalAssistantRoot / ".venv" / "Scripts" / "python.exe"
    )
  )
else:
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalAssistantRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "whisper-cli"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_OFFICE_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_OFFICE_PYTHON",
      LocalAssistantRoot / ".venv" / "bin" / "python"
    )
  )
putEnv(
  "GLAUCOPLASTIC_OFFICE_BRIDGE",
  LocalAssistantRoot / "tools" / "glaucoplastic_office.py"
)
putEnv(
  "GLAUCOPLASTIC_OFFICE_OUTPUT",
  getEnv(
    "GLAUCOPLASTIC_OFFICE_OUTPUT",
    LocalAssistantRoot / "office-output"
  )
)
putEnv("GLAUCOPLASTIC_FFMPEG_BINARY", getEnv("GLAUCOPLASTIC_FFMPEG_BINARY", "ffmpeg"))

glaucoplastic VoiceAssistantApplication, application:
  product:
    title "Glauco Assistant"
    description "Assistente local White Plastic com voz, Markdown, sessões e ferramentas de escritório."
    version "0.2.0"

  config:
    llama:
      modelPath "/home/icarogdo/models/gemma-4-E4B-it-Q4_K_M.gguf"
      contextSize 8192
      maxTokens 1536
      logResponseBody false
    metis:
      enabled false

  states:
    AssistantStatus = "ready"
    IsListening = false
    IsSpeaking = false
    ActiveSessionId = ""

  okfs:
    AssistantMemory:
      purpose "Armazenar conhecimento persistente aprendido nas conversas."
      summary "Preferências, projetos, decisões, pessoas, documentos e pendências."

  components:
    AssistantShell:
      render:
        divi:
          text "Carregando o assistente..."

  agents:
    OfficeAssistant:
      purpose """
Atuar como assistente pessoal local com ferramentas produtivas de escritório.
Responder normalmente quando nenhuma ferramenta for necessária. Criar ou ler
arquivos somente quando o pedido exigir uma operação concreta e informar o
caminho final produzido.
"""
      rlm:
        conditions """
Use uma Tool de escritório apenas quando houver intenção explícita de criar,
ler, listar ou resumir arquivos. Para criação, prefira nomes claros e mantenha
os arquivos no workspace configurado. Depois de executar uma Tool, use o valor
atribuído em variables para explicar o resultado ao usuário.
"""

        Tool CreateDocument(title, paragraphs, filename), JsonNode:
          capability "office.document.create"
          systemPrompt "Cria um documento DOCX com título e parágrafos estruturados."

        Tool CreateSpreadsheet(title, sheets, filename), JsonNode:
          capability "office.spreadsheet.create"
          systemPrompt "Cria uma planilha XLSX com uma ou mais abas e linhas."

        Tool CreatePresentation(title, subtitle, slides, filename), JsonNode:
          capability "office.presentation.create"
          systemPrompt "Cria uma apresentação PPTX com slides e tópicos."

        Tool CreatePdf(title, paragraphs, filename), JsonNode:
          capability "office.pdf.create"
          systemPrompt "Cria um PDF textual organizado por título, seções e parágrafos."

        Tool ExtractOfficeText(path, maxChars), JsonNode:
          capability "office.text.extract"
          systemPrompt "Extrai texto de DOCX, XLSX, PPTX, PDF ou arquivo textual do workspace."

        Tool ListOfficeFiles(directory, pattern, recursive), JsonNode:
          capability "office.files.list"
          systemPrompt "Lista arquivos do workspace de escritório."

        Tool SummarizeOfficeWorkspace(), JsonNode:
          capability "office.workspace.summary"
          systemPrompt "Retorna um inventário resumido do workspace de escritório."

  assistant:
    name "Glauco"
    rlmAgent "OfficeAssistant"
    systemPrompt """
Você é um assistente pessoal local. Responda em português do Brasil com
clareza e contexto. Use Markdown para estruturar respostas extensas, exemplos,
listas e código. Use somente memórias pertinentes à pergunta atual. Não trate
inferência como fato. Quando o usuário corrigir uma informação, priorize a
correção mais recente.
"""
    language "pt-BR"
    voice ""
    voiceRecognition "whisper.cpp"
    autoSpeak true
    autoSendVoice true
    backgroundLearning true
    maxRecentMessages 18
    maxMemoryItems 16
    responseMaxTokens 1536
    learningMaxTokens 512

  render:
    divi:
      text "Carregando o assistente..."

when isMainModule:
  application.run(startModel = false)
