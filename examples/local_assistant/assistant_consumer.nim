import std/os
import glaucoplastic

let LocalRpaRoot = currentSourcePath().parentDir

putEnv("GLAUCOPLASTIC_LLAMA_HOST", "127.0.0.1")
putEnv("GLAUCOPLASTIC_LLAMA_PORT", "19192")
putEnv("GLAUCOPLASTIC_LLM_ENDPOINT", "http://127.0.0.1:19192/v1")
putEnv("GLAUCOPLASTIC_METIS_MODE", getEnv("GLAUCOPLASTIC_METIS_MODE", "server"))
putEnv(
  "GLAUCOPLASTIC_METIS_ENDPOINT",
  getEnv("GLAUCOPLASTIC_METIS_ENDPOINT", "http://127.0.0.1:19192/v1")
)
putEnv(
  "GLAUCOPLASTIC_METIS_URL",
  getEnv("GLAUCOPLASTIC_METIS_URL", "http://127.0.0.1:19192/v1")
)
putEnv("GLAUCOPLASTIC_MODEL_ALIAS", "IAAR-Shanghai/Metis-4B")
putEnv("GLAUCOPLASTIC_METIS_ENABLED", "1")
putEnv("GLAUCOPLASTIC_METIS_STARTUP", getEnv("GLAUCOPLASTIC_METIS_STARTUP", "1"))
putEnv(
  "GLAUCOPLASTIC_METIS_LOAD_SAFETENSORS_ON_STARTUP",
  getEnv(
    "GLAUCOPLASTIC_METIS_LOAD_SAFETENSORS_ON_STARTUP",
    "1"
  )
)
putEnv("GLAUCOPLASTIC_DISABLE_MODEL_STARTUP", getEnv("GLAUCOPLASTIC_DISABLE_MODEL_STARTUP", "0"))
putEnv("GLAUCOPLASTIC_ASSISTANT_ENABLED", "1")
putEnv("GLAUCOPLASTIC_ASSISTANT_BUILTIN_SHELL", "0")
putEnv("GLAUCOPLASTIC_LLAMA_AUTO_DOWNLOAD_RUNTIME", "0")
putEnv("GLAUCOPLASTIC_LLAMA_AUTO_UPDATE_RUNTIME", "0")
putEnv("GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL", "0")
putEnv("GLAUCOPLASTIC_VOICE_RECOGNITION", "phone-adb")
putEnv("GLAUCOPLASTIC_RPA_MEMORY_ROOT", LocalRpaRoot / "rpa-memory")
putEnv("GLAUCOPLASTIC_RPA_SCREENSHOT_ROOT", LocalRpaRoot / "rpa-memory" / "screenshots")
putEnv("GLAUCOPLASTIC_RPA_BRIDGE", LocalRpaRoot / "tools" / "glaucoplastic_rpa.py")
putEnv("GLAUCOPLASTIC_RPA_PAUSE", getEnv("GLAUCOPLASTIC_RPA_PAUSE", "0.08"))

when defined(windows):
  putEnv(
    "GLAUCOPLASTIC_RPA_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_RPA_PYTHON",
      LocalRpaRoot / ".venv" / "Scripts" / "python.exe"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalRpaRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "Release" / "whisper-cli.exe"
    )
  )
else:
  putEnv(
    "GLAUCOPLASTIC_RPA_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_RPA_PYTHON",
      LocalRpaRoot / ".venv" / "bin" / "python"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalRpaRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "whisper-cli"
    )
  )

putEnv(
  "GLAUCOPLASTIC_WHISPER_MODEL",
  getEnv(
    "GLAUCOPLASTIC_WHISPER_MODEL",
    LocalRpaRoot / ".runtime" / "whisper.cpp" / "models" / "ggml-base.bin"
  )
)
putEnv("GLAUCOPLASTIC_FFMPEG_BINARY", getEnv("GLAUCOPLASTIC_FFMPEG_BINARY", "ffmpeg"))

glaucoplastic CognitiveRpaApplication, application:
  product:
    title "Glauco"
    description "Automação cognitiva local para executar e aprender rotinas no computador."
    version "0.4.0"

  config:
    llama:
      contextSize 12288
      maxTokens 2048
      logResponseBody false
    metis:
      enabled true
      startup true
      logSafetensors true

  states:
    TargetUrl = "https://www.google.com"

  okfs:
    AutomationMemory:
      purpose "Preservar rotinas operacionais confirmadas para reutilização e correção automática."
      summary "Objetivos, contexto, ações, efeitos observados, correções e trajetórias confirmadas."

  components:
    CognitiveRpaShell:
      workspace = foreign Workspace(
        url = binds states.TargetUrl,
        class = "rpa-foreign",
        title = "Área de trabalho"
      )

      render:
        style """
          :host {
            all: initial;
            position: fixed !important;
            inset: 0 !important;
            z-index: 2147483000;
            display: block !important;
            width: 100vw !important;
            height: 100dvh !important;
            min-width: 0 !important;
            min-height: 0 !important;
            overflow: hidden !important;
            contain: layout style paint;
            isolation: isolate;
            pointer-events: none;
            color-scheme: dark;
            color: #eef3f8;
            font-family:
              Inter, ui-sans-serif, system-ui, -apple-system,
              BlinkMacSystemFont, "Segoe UI", sans-serif;
            --rpa-bg: #0a0d12;
            --rpa-panel: #11161e;
            --rpa-panel-2: #171d27;
            --rpa-line: #283140;
            --rpa-text: #eef3f8;
            --rpa-muted: #8f9aab;
            --rpa-accent: #f0b84c;
            --rpa-safe: #6dd3a0;
            --rpa-sidebar-expanded: 252px;
            --rpa-sidebar-collapsed: 68px;
            --rpa-chat-width: 330px;
          }
          :host *, :host *::before, :host *::after {
            box-sizing: border-box;
          }
          .rpa-shell {
            position: absolute !important;
            inset: 0 !important;
            display: grid !important;
            visibility: visible !important;
            opacity: 1 !important;
            width: 100%; height: 100%; min-width: 0; min-height: 0;
            max-width: 100vw; max-height: 100dvh;
            display: grid;
            grid-template-columns:
              var(--rpa-sidebar-expanded) minmax(0, 1fr);
            grid-template-rows: 56px minmax(0, 1fr) 72px;
            overflow: hidden;
            background: transparent;
            pointer-events: none;
            transition: grid-template-columns .18s ease;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) {
            grid-template-columns: var(--rpa-sidebar-collapsed) minmax(0, 1fr);
          }
          .rpa-toggle-input {
            position: absolute; width: 1px; height: 1px;
            opacity: 0; pointer-events: none;
          }
          .rpa-topbar {
            display: flex !important;
            visibility: visible !important;
            opacity: 1 !important;
            grid-column: 1 / -1; grid-row: 1;
            display: flex; align-items: center; gap: 12px;
            padding: 0 12px;
            border-bottom: 1px solid var(--rpa-line);
            background: rgba(17, 22, 30, .97);
          }
          .rpa-brand {
            width: calc(var(--rpa-sidebar-expanded) - 12px);
            min-width: calc(var(--rpa-sidebar-expanded) - 12px);
            display: flex; align-items: center; gap: 9px;
            overflow: hidden;
            transition: width .18s ease, min-width .18s ease;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-brand {
            width: 44px; min-width: 44px;
          }
          .rpa-sidebar-toggle {
            width: 34px; height: 34px; flex: 0 0 34px;
            display: grid; place-items: center;
            border: 1px solid transparent; border-radius: 8px;
            color: var(--rpa-muted); cursor: pointer; user-select: none;
          }
          .rpa-sidebar-toggle:hover {
            color: var(--rpa-text); background: var(--rpa-panel-2);
            border-color: var(--rpa-line);
          }
          .rpa-brand-mark {
            width: 28px; height: 28px; flex: 0 0 28px;
            display: grid; place-items: center;
            border: 1px solid #725f33; border-radius: 8px;
            background: #201b11; color: var(--rpa-accent); font-weight: 800;
          }
          .rpa-brand-copy {
            overflow: hidden; white-space: nowrap;
            font-size: 14px; letter-spacing: .02em;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-brand-mark,
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-brand-copy {
            display: none;
          }
          .rpa-icon-button, .rpa-action, .rpa-nav-item, .rpa-nav-create {
            appearance: none; border: 1px solid transparent; border-radius: 8px;
            background: transparent; color: var(--rpa-muted);
            font: inherit; cursor: pointer;
          }
          .rpa-icon-button:hover, .rpa-nav-item:hover, .rpa-nav-create:hover {
            color: var(--rpa-text); background: var(--rpa-panel-2);
            border-color: var(--rpa-line);
          }
          .rpa-address {
            flex: 1; min-width: 160px; display: flex; align-items: center; gap: 7px;
          }
          .rpa-address input {
            width: 100%; height: 34px; padding: 0 11px;
            border: 1px solid var(--rpa-line); border-radius: 8px;
            outline: none; background: #0d1118; color: var(--rpa-text);
          }
          .rpa-address input:focus {
            border-color: #6f5d35;
            box-shadow: 0 0 0 2px rgba(240,184,76,.11);
          }
          .rpa-icon-button { height: 34px; padding: 0 10px; }
          #assistant-status {
            min-width: 54px; text-align: right;
            color: var(--rpa-muted); font-size: 12px;
          }
          .rpa-sidebar {
            display: flex !important;
            visibility: visible !important;
            opacity: 1 !important;
            grid-column: 1; grid-row: 2;
            min-height: 0; overflow: hidden;
            display: flex; flex-direction: column;
            border-right: 1px solid var(--rpa-line);
            background: var(--rpa-panel);
            padding: 10px 8px;
          }
          .rpa-navigation { display: grid; gap: 4px; }
          .rpa-nav-row {
            min-width: 0; display: grid;
            grid-template-columns: minmax(0, 1fr) auto; gap: 4px;
          }
          .rpa-nav-item {
            width: 100%; min-width: 0; height: 42px;
            display: grid; grid-template-columns: 38px minmax(0, 1fr);
            align-items: center; padding: 0 8px;
            text-align: left;
          }
          .rpa-nav-workspace {
            color: var(--rpa-text); background: #19170f;
            border-color: #4b4028;
          }
          .rpa-shell:has(.rpa-page-input:checked) .rpa-nav-workspace {
            color: var(--rpa-muted); background: transparent; border-color: transparent;
          }
          .rpa-shell:has(#rpa-page-workspace-toggle:checked) .rpa-nav-workspace,
          .rpa-shell:has(#rpa-page-tasks-toggle:checked) .rpa-nav-tasks,
          .rpa-shell:has(#rpa-page-automations-toggle:checked) .rpa-nav-automations,
          .rpa-shell:has(#rpa-page-history-toggle:checked) .rpa-nav-history,
          .rpa-shell:has(#rpa-page-memory-toggle:checked) .rpa-nav-memory,
          .rpa-shell:has(#rpa-page-settings-toggle:checked) .rpa-nav-settings,
          .rpa-shell[data-active-page="rpa-page-workspace-toggle"] .rpa-nav-workspace,
          .rpa-shell[data-active-page="rpa-page-tasks-toggle"] .rpa-nav-tasks,
          .rpa-shell[data-active-page="rpa-page-automations-toggle"] .rpa-nav-automations,
          .rpa-shell[data-active-page="rpa-page-history-toggle"] .rpa-nav-history,
          .rpa-shell[data-active-page="rpa-page-memory-toggle"] .rpa-nav-memory,
          .rpa-shell[data-active-page="rpa-page-settings-toggle"] .rpa-nav-settings {
            color: var(--rpa-text); background: #19170f;
            border-color: #4b4028;
          }
          .rpa-nav-icon {
            width: 38px; display: grid; place-items: center;
            color: currentColor; font-size: 16px;
          }
          .rpa-nav-label {
            overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
            font-size: 13px;
          }
          .rpa-nav-create {
            width: 38px; height: 42px; padding: 0;
            display: grid; place-items: center;
          }
          .rpa-nav-spacer { flex: 1; }
          .rpa-sidebar-footer {
            padding-top: 8px; border-top: 1px solid var(--rpa-line);
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-nav-item {
            grid-template-columns: 1fr; padding: 0;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-nav-label,
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-nav-create {
            display: none;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-nav-icon {
            width: 100%;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-nav-row {
            grid-template-columns: 1fr;
          }
          .rpa-stage {
            grid-column: 2; grid-row: 2;
            min-width: 0; min-height: 0; position: relative;
            padding: 10px;
            overflow: hidden;
            background: transparent;
            pointer-events: none;
          }
          .rpa-stage .glauco-foreign {
            width: 100%; height: 100%; min-height: 0; margin: 0;
            border: 0; border-radius: 10px;
            overflow: hidden;
            background: transparent;
            opacity: 0;
            visibility: hidden;
            pointer-events: none;
          }
          .rpa-stage .glauco-foreign::before {
            color: #111827; background: #f3f4f6;
          }
          .rpa-activity-panel {
            position: absolute; left: 22px; bottom: 22px; z-index: 20;
            width: min(440px, calc(100% - 44px)); max-height: min(46vh, 360px);
            display: none; overflow: hidden;
            border: 1px solid var(--rpa-line); border-radius: 12px;
            background: rgba(13, 18, 25, .96);
            box-shadow: 0 18px 44px rgba(0,0,0,.35);
          }
          .rpa-activity-panel:has(.assistant-message) { display: block; }
          .rpa-activity-title {
            margin: 0; padding: 10px 12px;
            border-bottom: 1px solid var(--rpa-line);
            color: var(--rpa-muted); font-size: 11px;
            font-weight: 750; letter-spacing: .08em; text-transform: uppercase;
          }
          #assistant-messages {
            display: grid; gap: 7px; max-height: 300px; overflow: auto;
            padding: 10px;
          }
          #assistant-messages .assistant-message {
            width: 100%; max-width: none; margin: 0; padding: 9px;
            border-radius: 8px; background: #0d1219;
            border: 1px solid var(--rpa-line);
            color: var(--rpa-text); font-size: 12px;
          }
          #assistant-messages .assistant-message.user {
            border-color: #4b4028; background: #17140e;
          }
          #assistant-messages .assistant-message-time { display: none; }
          .rpa-composer-shell {
            grid-column: 1 / -1; grid-row: 3;
            min-width: 0; min-height: 0; overflow: hidden;
            display: grid;
            grid-template-columns: var(--rpa-sidebar-expanded) minmax(0, 1fr);
            border-top: 1px solid var(--rpa-line);
            background: rgba(17,22,30,.98);
            transition: grid-template-columns .18s ease;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-composer-shell {
            grid-template-columns: var(--rpa-sidebar-collapsed) minmax(0, 1fr);
          }
          .rpa-composer-context {
            min-width: 0; display: flex; align-items: center; gap: 8px;
            padding: 12px 14px; overflow: hidden;
            border-right: 1px solid var(--rpa-line);
            color: var(--rpa-muted); font-size: 12px;
          }
          .rpa-status-dot {
            width: 8px; height: 8px; flex: 0 0 8px; border-radius: 50%;
            background: var(--rpa-safe);
          }
          .rpa-context-copy { white-space: nowrap; overflow: hidden; }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-composer-context {
            justify-content: center; padding: 12px 0;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-context-copy {
            display: none;
          }
          .rpa-composer {
            min-width: 0; min-height: 0; overflow: hidden;
            display: grid; grid-template-columns: auto minmax(0, 1fr) auto;
            align-items: center; gap: 9px; padding: 8px 14px;
          }
          .rpa-composer textarea {
            width: 100%; height: 48px; max-height: 48px; resize: none;
            overflow-y: auto;
            padding: 13px 14px; border: 1px solid var(--rpa-line);
            border-radius: 10px; outline: none;
            background: #0c1016; color: var(--rpa-text); font: inherit;
          }
          .rpa-composer textarea:focus { border-color: #6f5d35; }
          .rpa-action {
            height: 48px; padding: 0 17px; border-color: #6f5d35;
            background: #241d10; color: var(--rpa-accent); font-weight: 700;
          }
          .rpa-action:hover { background: #302612; }
          .rpa-mic {
            width: 48px; padding: 0; border-color: var(--rpa-line);
            background: #0c1016; color: var(--rpa-muted);
          }
          .rpa-mic.listening { color: #ff8c8c; border-color: #7b3838; }
          #assistant-error:empty, #assistant-voice-note:empty { display: none; }
          #assistant-error { padding: 0 10px 10px; color: #ff9b9b; font-size: 11px; }
          #assistant-voice-note { padding: 0 10px 10px; color: var(--rpa-muted); font-size: 11px; }
          .rpa-runtime-controls { display: none; }
          .rpa-page-heading {
            display: none; flex: 1; min-width: 0;
            flex-direction: column; justify-content: center;
          }
          .rpa-page-heading strong {
            overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
            font-size: 13px; font-weight: 700;
          }
          .rpa-page-heading small {
            overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
            color: var(--rpa-muted); font-size: 10px;
          }
          .rpa-page-input {
            position: absolute; width: 1px; height: 1px;
            opacity: 0; pointer-events: none;
          }
          .rpa-page {
            width: 100%; height: 100%; min-width: 0; min-height: 0;
            display: none;
          }
          #rpa-page-workspace { display: block; }
          .rpa-workspace-page { position: relative; }
          .rpa-shell:has(.rpa-page-input:checked) #rpa-page-workspace { display: none; }
          .rpa-shell:has(#rpa-page-workspace-toggle:checked) #rpa-page-workspace,
          .rpa-shell:has(#rpa-page-tasks-toggle:checked) #rpa-page-tasks,
          .rpa-shell:has(#rpa-page-automations-toggle:checked) #rpa-page-automations,
          .rpa-shell:has(#rpa-page-history-toggle:checked) #rpa-page-history,
          .rpa-shell:has(#rpa-page-memory-toggle:checked) #rpa-page-memory,
          .rpa-shell:has(#rpa-page-settings-toggle:checked) #rpa-page-settings,
          .rpa-shell[data-active-page="rpa-page-workspace-toggle"] #rpa-page-workspace,
          .rpa-shell[data-active-page="rpa-page-tasks-toggle"] #rpa-page-tasks,
          .rpa-shell[data-active-page="rpa-page-automations-toggle"] #rpa-page-automations,
          .rpa-shell[data-active-page="rpa-page-history-toggle"] #rpa-page-history,
          .rpa-shell[data-active-page="rpa-page-memory-toggle"] #rpa-page-memory,
          .rpa-shell[data-active-page="rpa-page-settings-toggle"] #rpa-page-settings {
            display: block;
          }
          .rpa-shell:has(.rpa-internal-page-input:checked) .rpa-address { display: none; }
          .rpa-shell:has(#rpa-page-tasks-toggle:checked) .rpa-heading-tasks,
          .rpa-shell:has(#rpa-page-automations-toggle:checked) .rpa-heading-automations,
          .rpa-shell:has(#rpa-page-history-toggle:checked) .rpa-heading-history,
          .rpa-shell:has(#rpa-page-memory-toggle:checked) .rpa-heading-memory,
          .rpa-shell:has(#rpa-page-settings-toggle:checked) .rpa-heading-settings {
            display: flex;
          }
          .rpa-workspace-page .glauco-foreign {
            width: 100%; height: 100%; min-height: 0; margin: 0;
            border: 0; border-radius: 10px;
            overflow: hidden;
            background: transparent;
            opacity: 0;
            visibility: hidden;
            pointer-events: none;
          }
          .rpa-content-page {
            overflow: auto; padding: 28px;
            background:
              radial-gradient(circle at top right, rgba(240,184,76,.045), transparent 30%),
              #0b0f15;
          }
          .rpa-shell:has(#rpa-page-tasks-toggle:checked) #rpa-page-tasks,
          .rpa-shell:has(#rpa-page-automations-toggle:checked) #rpa-page-automations,
          .rpa-shell:has(#rpa-page-history-toggle:checked) #rpa-page-history,
          .rpa-shell:has(#rpa-page-memory-toggle:checked) #rpa-page-memory,
          .rpa-shell:has(#rpa-page-settings-toggle:checked) #rpa-page-settings,
          .rpa-shell[data-active-page="rpa-page-tasks-toggle"] #rpa-page-tasks,
          .rpa-shell[data-active-page="rpa-page-automations-toggle"] #rpa-page-automations,
          .rpa-shell[data-active-page="rpa-page-history-toggle"] #rpa-page-history,
          .rpa-shell[data-active-page="rpa-page-memory-toggle"] #rpa-page-memory,
          .rpa-shell[data-active-page="rpa-page-settings-toggle"] #rpa-page-settings {
            display: flex; flex-direction: column; gap: 22px;
          }
          .rpa-page-header {
            display: flex; align-items: flex-end; justify-content: space-between;
            gap: 20px; padding-bottom: 18px;
            border-bottom: 1px solid var(--rpa-line);
          }
          .rpa-page-header h1 {
            margin: 4px 0 4px; font-size: clamp(24px, 3vw, 34px);
            line-height: 1.05; letter-spacing: -.025em;
          }
          .rpa-page-header p, .rpa-card-description, .rpa-setting-copy p,
          .rpa-empty-state p {
            margin: 0; color: var(--rpa-muted); line-height: 1.5;
          }
          .rpa-page-eyebrow, .rpa-card-kicker {
            color: var(--rpa-accent); font-size: 10px; font-weight: 800;
            letter-spacing: .12em; text-transform: uppercase;
          }
          .rpa-primary-button, .rpa-secondary-button {
            appearance: none; min-height: 38px; padding: 0 14px;
            border: 1px solid var(--rpa-line); border-radius: 9px;
            background: #10161f; color: var(--rpa-text); font: inherit;
            font-size: 12px; font-weight: 700; cursor: pointer;
          }
          .rpa-primary-button {
            border-color: #6f5d35; background: #241d10; color: var(--rpa-accent);
          }
          .rpa-primary-button:hover { background: #302612; }
          .rpa-secondary-button:hover { border-color: #465266; background: #171e28; }
          .rpa-page-grid {
            display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 16px; min-height: 0;
          }
          .rpa-task-grid { grid-template-columns: minmax(260px, .75fr) minmax(340px, 1.25fr); }
          .rpa-memory-grid { align-items: stretch; }
          .rpa-card, .rpa-summary-card {
            min-width: 0; border: 1px solid var(--rpa-line); border-radius: 12px;
            background: rgba(17, 22, 30, .88);
          }
          .rpa-card { padding: 18px; }
          .rpa-fill-card { flex: 1; min-height: 280px; }
          .rpa-current-task-card {
            display: flex; flex-direction: column; align-items: flex-start; gap: 16px;
          }
          .rpa-card-heading {
            width: 100%; display: flex; align-items: center;
            justify-content: space-between; gap: 14px; margin-bottom: 16px;
          }
          .rpa-card-heading h2, .rpa-setting-copy h2 {
            margin: 3px 0 0; font-size: 16px;
          }
          .rpa-live-badge, .rpa-local-badge {
            display: inline-flex; align-items: center; min-height: 25px;
            padding: 0 9px; border: 1px solid #315d4a; border-radius: 999px;
            background: #102219; color: var(--rpa-safe); font-size: 10px;
            font-weight: 800; text-transform: uppercase; letter-spacing: .08em;
          }
          .rpa-list { display: grid; gap: 8px; }
          #assistant-session-list .assistant-session,
          #assistant-thing-list > * {
            width: 100%; padding: 12px;
            border: 1px solid var(--rpa-line); border-radius: 9px;
            background: #0d1219; color: var(--rpa-text); text-align: left;
          }
          #assistant-session-list .assistant-session:hover {
            border-color: #4b5668; background: #121923;
          }
          #assistant-session-list .assistant-session small {
            display: block; margin-top: 3px; color: var(--rpa-muted);
          }
          .rpa-empty-state {
            min-height: 210px; display: grid; place-items: center;
            align-content: center; gap: 7px; padding: 30px;
            text-align: center; color: var(--rpa-muted);
            border: 1px dashed #313b4a; border-radius: 10px;
            background: rgba(8, 11, 16, .42);
          }
          .rpa-session-card:has(#assistant-session-list > *) .rpa-session-empty,
          .rpa-card:has(#assistant-thing-list > *) .rpa-memory-empty {
            display: none;
          }
          .rpa-empty-state[hidden] { display: none; }
          .rpa-empty-state strong { color: var(--rpa-text); font-size: 13px; }
          .rpa-empty-icon { font-size: 24px; color: #778397; }
          .rpa-summary-row {
            display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px;
          }
          .rpa-summary-card {
            display: flex; align-items: center; justify-content: space-between;
            gap: 14px; padding: 15px 16px;
          }
          .rpa-summary-card span { color: var(--rpa-muted); font-size: 12px; }
          .rpa-summary-card strong { font-size: 20px; }
          .rpa-search-input, .rpa-filter-select {
            height: 36px; min-width: 180px; padding: 0 11px;
            border: 1px solid var(--rpa-line); border-radius: 8px;
            outline: none; background: #0c1016; color: var(--rpa-text); font: inherit;
            font-size: 12px;
          }
          .rpa-search-input:focus, .rpa-filter-select:focus { border-color: #6f5d35; }
          .rpa-settings-stack { display: grid; gap: 12px; max-width: 900px; }
          .rpa-settings-card {
            display: flex; align-items: center; justify-content: space-between; gap: 22px;
          }
          .rpa-setting-copy { min-width: 0; }
          .rpa-setting-actions { display: flex; gap: 8px; }
          .rpa-switch { position: relative; flex: 0 0 auto; cursor: pointer; }
          .rpa-switch input {
            position: absolute; width: 1px; height: 1px; opacity: 0;
          }
          .rpa-switch-track {
            width: 44px; height: 24px; display: block; position: relative;
            border: 1px solid #3a4556; border-radius: 999px; background: #0b1017;
            transition: .16s ease;
          }
          .rpa-switch-track::after {
            content: ''; width: 18px; height: 18px; position: absolute;
            left: 2px; top: 2px; border-radius: 50%; background: #7d899a;
            transition: transform .16s ease, background .16s ease;
          }
          .rpa-switch input:checked + .rpa-switch-track {
            border-color: #6f5d35; background: #241d10;
          }
          .rpa-switch input:checked + .rpa-switch-track::after {
            transform: translateX(20px); background: var(--rpa-accent);
          }
          @media (max-width: 860px) {
            .rpa-shell {
              grid-template-columns: var(--rpa-sidebar-collapsed) minmax(0, 1fr);
            }
            .rpa-brand { width: 44px; min-width: 44px; }
            .rpa-brand-mark, .rpa-brand-copy, .rpa-nav-label, .rpa-nav-create,
            .rpa-context-copy { display: none; }
            .rpa-nav-item { grid-template-columns: 1fr; padding: 0; }
            .rpa-nav-icon { width: 100%; }
            .rpa-nav-row { grid-template-columns: 1fr; }
            .rpa-composer-shell {
              grid-template-columns: var(--rpa-sidebar-collapsed) minmax(0, 1fr);
            }
            .rpa-composer-context { justify-content: center; padding: 12px 0; }
            .rpa-content-page { padding: 18px; }
            .rpa-page-header { align-items: flex-start; flex-direction: column; }
            .rpa-page-grid, .rpa-task-grid, .rpa-memory-grid,
            .rpa-summary-row { grid-template-columns: 1fr; }
            .rpa-card-heading, .rpa-settings-card {
              align-items: flex-start; flex-direction: column;
            }
            .rpa-search-input, .rpa-filter-select { width: 100%; }
          }
          /* Chat lateral e compositor flutuante: não alteram a geometria do foreign. */
          :host { --rpa-chat-width: 330px; }
          .rpa-shell {
            grid-template-rows: 56px minmax(0, 1fr) !important;
          }
          .rpa-chat-toggle-button {
            min-width: 42px; height: 34px; padding: 0 10px;
            display: inline-flex; align-items: center; justify-content: center; gap: 7px;
            border: 1px solid var(--rpa-line); border-radius: 8px;
            background: #0c1118; color: var(--rpa-muted); cursor: pointer;
            user-select: none;
          }
          .rpa-chat-toggle-button:hover,
          .rpa-shell[data-chat-open="true"] .rpa-chat-toggle-button,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-chat-toggle-button {
            color: var(--rpa-text); border-color: #6f5d35; background: #211b10;
          }
          .rpa-chat-toggle-icon { font-size: 15px; line-height: 1; }
          .rpa-chat-toggle-label { font-size: 12px; font-weight: 700; }

          .rpa-chat-panel {
            position: absolute; top: 56px; right: 0; bottom: 0;
            width: var(--rpa-chat-width); min-width: 300px; max-width: min(380px, 92vw);
            z-index: 60; display: flex !important; flex-direction: column;
            min-height: 0; overflow: hidden;
            border-left: 1px solid var(--rpa-line);
            background: rgba(14, 19, 27, .985);
            box-shadow: -18px 0 42px rgba(0, 0, 0, .32);
            transform: translateX(calc(100% + 10px)); opacity: 0;
            pointer-events: none;
            transition: transform .2s ease, opacity .18s ease;
          }
          .rpa-shell[data-chat-open="true"] .rpa-chat-panel,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-chat-panel {
            transform: translateX(0); opacity: 1; pointer-events: auto;
          }
          .rpa-chat-header {
            flex: 0 0 auto; min-height: 58px; padding: 11px 14px;
            display: flex; align-items: center; justify-content: space-between; gap: 12px;
            border-bottom: 1px solid var(--rpa-line);
          }
          .rpa-chat-header > div { min-width: 0; display: grid; gap: 2px; }
          .rpa-chat-header strong { font-size: 13px; }
          .rpa-chat-header small { color: var(--rpa-muted); font-size: 10px; }
          .rpa-chat-local-badge {
            padding: 4px 7px; border: 1px solid #355344; border-radius: 999px;
            color: var(--rpa-safe); font-size: 9px; font-weight: 800;
            text-transform: uppercase; letter-spacing: .08em;
          }
          .rpa-chat-panel #assistant-messages {
            flex: 1 1 auto; min-height: 0; max-height: none !important;
            display: flex; flex-direction: column; gap: 8px;
            overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain;
            padding: 12px 11px 102px;
          }
          .rpa-chat-panel #assistant-messages .assistant-message {
            width: auto; max-width: 92%; margin: 0; padding: 9px 10px;
          }
          .rpa-chat-panel #assistant-messages .assistant-message.user {
            align-self: flex-end;
          }
          .rpa-chat-panel #assistant-messages .assistant-message.assistant {
            align-self: flex-start;
          }
          .rpa-chat-feedback {
            position: absolute; left: 0; right: 0; bottom: 82px;
            z-index: 2; pointer-events: none;
          }
          .rpa-chat-feedback #assistant-error:not(:empty) {
            display: block !important;
            margin: 8px 10px;
            padding: 9px 10px;
            border: 1px solid #7b3434;
            border-radius: 9px;
            background: rgba(74, 21, 21, .96);
            color: #ffb4b4;
            font-size: 11px;
            line-height: 1.4;
            white-space: normal;
            overflow-wrap: anywhere;
            pointer-events: auto;
          }
          #assistant-status[data-has-error="true"] {
            cursor: pointer;
            color: #ff8d8d !important;
          }

          .rpa-composer-shell {
            position: absolute !important;
            left: calc(var(--rpa-sidebar-expanded) + 18px); right: 18px; bottom: 16px;
            width: auto; height: auto; min-width: 0; min-height: 0;
            z-index: 70; display: flex !important; justify-content: center;
            overflow: visible !important; border: 0 !important;
            background: transparent !important; pointer-events: none;
            transition: left .18s ease, right .2s ease, width .2s ease,
              background .2s ease, border-color .2s ease;
          }
          .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-composer-shell {
            left: calc(var(--rpa-sidebar-collapsed) + 18px);
          }
          .rpa-composer-context { display: none !important; }
          .rpa-composer {
            width: min(900px, 100%); min-width: 0; min-height: 0;
            pointer-events: auto;
            display: grid; grid-template-columns: auto minmax(0, 1fr) auto;
            align-items: center; gap: 9px; padding: 8px;
            border: 1px solid #5b4b2c; border-radius: 13px;
            background: rgba(10, 14, 20, .96);
            box-shadow: 0 16px 42px rgba(0, 0, 0, .42);
            backdrop-filter: blur(14px);
          }
          .rpa-composer textarea {
            width: 100%; height: 46px; min-height: 46px; max-height: 110px;
            overflow-y: auto; resize: none;
          }
          .rpa-shell[data-chat-open="true"] .rpa-composer-shell,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-composer-shell {
            left: auto; right: 0; bottom: 0;
            width: var(--rpa-chat-width); min-width: 300px; max-width: min(380px, 92vw);
            padding: 10px;
            justify-content: stretch;
            border-top: 1px solid var(--rpa-line) !important;
            border-left: 1px solid var(--rpa-line) !important;
            background: rgba(14, 19, 27, .99) !important;
          }
          .rpa-shell[data-chat-open="true"] .rpa-composer,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-composer {
            width: 100%; padding: 7px; border-radius: 10px;
            box-shadow: none; backdrop-filter: none;
          }
          .rpa-shell[data-chat-open="true"] .rpa-action,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-action {
            padding-inline: 11px;
          }

          .rpa-notification-stack {
            position: absolute; top: 68px; right: 18px; z-index: 90;
            width: min(360px, calc(100vw - 36px));
            display: grid; gap: 8px; pointer-events: none;
            transition: right .2s ease;
          }
          .rpa-shell[data-chat-open="true"] .rpa-notification-stack,
          .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-notification-stack {
            right: calc(var(--rpa-chat-width) + 14px);
          }
          .rpa-agent-notification {
            width: 100%; padding: 11px 12px;
            display: grid; gap: 4px; text-align: left;
            border: 1px solid #6f5d35; border-radius: 11px;
            background: rgba(18, 24, 33, .98); color: var(--rpa-text);
            box-shadow: 0 16px 38px rgba(0, 0, 0, .42);
            opacity: 0; transform: translateY(-8px) scale(.985);
            pointer-events: auto; cursor: pointer;
            transition: opacity .18s ease, transform .18s ease;
          }
          .rpa-agent-notification.visible {
            opacity: 1; transform: translateY(0) scale(1);
          }
          .rpa-agent-notification strong {
            color: var(--rpa-accent); font-size: 11px;
          }
          .rpa-agent-notification span {
            color: var(--rpa-text); font-size: 12px; line-height: 1.4;
            overflow: hidden; display: -webkit-box; -webkit-line-clamp: 3;
            -webkit-box-orient: vertical;
          }

          @media (max-width: 860px) {
            :host { --rpa-chat-width: min(340px, calc(100vw - var(--rpa-sidebar-collapsed))); }
            .rpa-chat-toggle-label { display: none; }
            .rpa-composer-shell,
            .rpa-shell:has(#rpa-sidebar-toggle:checked) .rpa-composer-shell {
              left: calc(var(--rpa-sidebar-collapsed) + 10px); right: 10px;
            }
            .rpa-shell[data-chat-open="true"] .rpa-composer-shell,
            .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-composer-shell {
              left: auto; right: 0;
            }
            .rpa-shell[data-chat-open="true"] .rpa-notification-stack,
            .rpa-shell:has(#rpa-chat-toggle:checked) .rpa-notification-stack {
              right: 10px;
            }
          }

          
          /* Shell principal é a superfície oficial do assistente. */
          .rpa-composer-shell {
            display: flex !important;
            visibility: visible !important;
            opacity: 1 !important;
          }
          .rpa-composer,
          #assistant-composer,
          #assistant-send,
          #assistant-microphone {
            visibility: visible !important;
            opacity: 1 !important;
          }
          .rpa-composer { pointer-events: auto !important; }
          .rpa-chat-panel {
            display: flex !important;
            visibility: visible !important;
          }
          .rpa-notification-stack {
            display: grid !important;
            visibility: visible !important;
          }
          #assistant-messages {
            visibility: visible !important;
            opacity: 1 !important;
          }
          #assistant-status { position: relative; z-index: 120; }
          #assistant-status[data-status="thinking"] {
            color: var(--rpa-accent);
          }
          .rpa-stage .glauco-foreign { z-index: 0 !important; }

          /* Camadas interativas do shell sobre a página foreign. */
          .rpa-topbar,
          .rpa-sidebar,
          .rpa-content-page,
          .rpa-nav-item,
          .rpa-chat-toggle-button,
          .rpa-chat-panel,
          .rpa-composer,
          .rpa-agent-notification {
            pointer-events: auto !important;
          }

          .rpa-nav-item,
          .rpa-chat-toggle-button {
            position: relative;
            z-index: 160;
            touch-action: manipulation;
          }
          .rpa-workspace-page {
            pointer-events: none;
          }
          .rpa-content-page {
            position: relative;
            z-index: 30;
          }
        """

        divi class = "rpa-shell":
          header class = "rpa-topbar":
            divi class = "rpa-brand":
              label class = "rpa-sidebar-toggle", title = "Recolher navegação":
                input SidebarToggle(
                  id = "rpa-sidebar-toggle",
                  type = "checkbox",
                  class = "rpa-toggle-input"
                )
                span MenuIcon "☰"
              span BrandMark(class = "rpa-brand-mark") "G"
              strong class = "rpa-brand-copy":
                text "Glauco"

            divi class = "rpa-address":
              button GoBack(type = "button", class = "rpa-icon-button", title = "Voltar") "←"
              button GoForward(type = "button", class = "rpa-icon-button", title = "Avançar") "→"
              button Reload(type = "button", class = "rpa-icon-button", title = "Recarregar") "↻"
              input Address(
                value = binds states.TargetUrl,
                bindOn = "blur",
                type = "url",
                placeholder = "Endereço",
                autocomplete = "off",
                spellcheck = "false"
              )
              button OpenTarget(type = "button", class = "rpa-icon-button") "Abrir"

            divi class = "rpa-page-heading rpa-heading-tasks":
              strong "Tarefas"
              small "Objetivos e sessões"
            divi class = "rpa-page-heading rpa-heading-automations":
              strong "Automações"
              small "Rotinas confirmadas"
            divi class = "rpa-page-heading rpa-heading-history":
              strong "Histórico"
              small "Execuções anteriores"
            divi class = "rpa-page-heading rpa-heading-memory":
              strong "Memória"
              small "Conhecimento e trajetórias"
            divi class = "rpa-page-heading rpa-heading-settings":
              strong "Configurações"
              small "Preferências locais"

            label class = "rpa-chat-toggle-button", title = "Abrir ou fechar conversas":
              input ChatPanelToggle(
                id = "rpa-chat-toggle",
                type = "checkbox",
                class = "rpa-toggle-input"
              )
              span class = "rpa-chat-toggle-icon":
                text "▤"
              span class = "rpa-chat-toggle-label":
                text "Conversas"

            divi id = "assistant-status":
              span StatusText(id = "assistant-status-text") "Pronto"

          aside class = "rpa-sidebar":
            nav class = "rpa-navigation":
              label class = "rpa-nav-item rpa-nav-workspace", title = "Área de trabalho":
                input WorkspacePageToggle(
                  id = "rpa-page-workspace-toggle",
                  type = "radio",
                  name = "rpa-page",
                  class = "rpa-page-input"
                )
                span class = "rpa-nav-icon":
                  text "⌂"
                span class = "rpa-nav-label":
                  text "Área de trabalho"

              divi class = "rpa-nav-row":
                label class = "rpa-nav-item rpa-nav-tasks", title = "Tarefas":
                  input TasksPageToggle(
                    id = "rpa-page-tasks-toggle",
                    type = "radio",
                    name = "rpa-page",
                    class = "rpa-page-input rpa-internal-page-input"
                  )
                  span class = "rpa-nav-icon":
                    text "☑"
                  span class = "rpa-nav-label":
                    text "Tarefas"
                button NewSession(
                  id = "assistant-new-session",
                  type = "button",
                  class = "rpa-nav-create",
                  title = "Nova tarefa"
                ) "+"

              label class = "rpa-nav-item rpa-nav-automations", title = "Automações":
                input AutomationsPageToggle(
                  id = "rpa-page-automations-toggle",
                  type = "radio",
                  name = "rpa-page",
                  class = "rpa-page-input rpa-internal-page-input"
                )
                span class = "rpa-nav-icon":
                  text "▶"
                span class = "rpa-nav-label":
                  text "Automações"

              label class = "rpa-nav-item rpa-nav-history", title = "Histórico":
                input HistoryPageToggle(
                  id = "rpa-page-history-toggle",
                  type = "radio",
                  name = "rpa-page",
                  class = "rpa-page-input rpa-internal-page-input"
                )
                span class = "rpa-nav-icon":
                  text "◷"
                span class = "rpa-nav-label":
                  text "Histórico"

              label class = "rpa-nav-item rpa-nav-memory", title = "Memória":
                input MemoryPageToggle(
                  id = "rpa-page-memory-toggle",
                  type = "radio",
                  name = "rpa-page",
                  class = "rpa-page-input rpa-internal-page-input"
                )
                span class = "rpa-nav-icon":
                  text "◉"
                span class = "rpa-nav-label":
                  text "Memória"

            divi class = "rpa-nav-spacer"

            divi class = "rpa-sidebar-footer":
              label class = "rpa-nav-item rpa-nav-settings", title = "Configurações":
                input SettingsPageToggle(
                  id = "rpa-page-settings-toggle",
                  type = "radio",
                  name = "rpa-page",
                  class = "rpa-page-input rpa-internal-page-input"
                )
                span class = "rpa-nav-icon":
                  text "⚙"
                span class = "rpa-nav-label":
                  text "Configurações"

          main class = "rpa-stage":
            section id = "rpa-page-workspace", class = "rpa-page rpa-workspace-page":
              workspace

            section id = "rpa-page-tasks", class = "rpa-page rpa-content-page":
              header class = "rpa-page-header":
                divi:
                  span class = "rpa-page-eyebrow":
                    text "Operação"
                  h1 "Tarefas"
                  p "Objetivos em andamento e sessões recentes."

              divi class = "rpa-page-grid rpa-task-grid":
                article class = "rpa-card rpa-current-task-card":
                  divi class = "rpa-card-heading":
                    divi:
                      span class = "rpa-card-kicker":
                        text "Tarefa atual"
                      h2 id = "assistant-current-title":
                        text "Nova tarefa"
                    span class = "rpa-live-badge":
                      text "ativa"
                  p class = "rpa-card-description":
                    text "A execução, as decisões solicitadas e o resultado ficam associados a esta tarefa."

                article class = "rpa-card rpa-session-card":
                  divi class = "rpa-card-heading":
                    divi:
                      span class = "rpa-card-kicker":
                        text "Sessões"
                      h2 "Tarefas recentes"
                  divi id = "assistant-session-list", class = "rpa-list"
                  divi class = "rpa-empty-state rpa-session-empty":
                    span class = "rpa-empty-icon":
                      text "☑"
                    strong "Nenhuma tarefa anterior"
                    p "Crie uma tarefa para iniciar uma nova trajetória operacional."

            section id = "rpa-page-automations", class = "rpa-page rpa-content-page":
              header class = "rpa-page-header":
                divi:
                  span class = "rpa-page-eyebrow":
                    text "Rotinas"
                  h1 "Automações"
                  p "Trajetórias confirmadas que podem ser executadas novamente."

              divi class = "rpa-summary-row":
                article class = "rpa-summary-card":
                  span "Disponíveis"
                  strong id = "rpa-automation-count":
                    text "0"
                article class = "rpa-summary-card":
                  span "Executadas recentemente"
                  strong id = "rpa-automation-recent-count":
                    text "0"
                article class = "rpa-summary-card":
                  span "Precisam de revisão"
                  strong id = "rpa-automation-review-count":
                    text "0"

              article class = "rpa-card rpa-fill-card":
                divi class = "rpa-card-heading":
                  divi:
                    span class = "rpa-card-kicker":
                      text "Biblioteca"
                    h2 "Automações aprendidas"
                  input AutomationSearch(
                    id = "rpa-automation-search",
                    type = "search",
                    class = "rpa-search-input",
                    placeholder = "Buscar automação",
                    autocomplete = "off"
                  )
                divi id = "rpa-automation-list", class = "rpa-list"
                divi id = "rpa-automation-empty", class = "rpa-empty-state":
                  span class = "rpa-empty-icon":
                    text "▶"
                  strong "Nenhuma automação consolidada"
                  p "Uma rotina aparece aqui depois que sua execução e seu resultado forem confirmados."

            section id = "rpa-page-history", class = "rpa-page rpa-content-page":
              header class = "rpa-page-header":
                divi:
                  span class = "rpa-page-eyebrow":
                    text "Registro"
                  h1 "Histórico"
                  p "Execuções concluídas, interrompidas e corrigidas."

              article class = "rpa-card rpa-fill-card":
                divi class = "rpa-card-heading":
                  divi:
                    span class = "rpa-card-kicker":
                      text "Linha do tempo"
                    h2 "Atividade recente"
                  select HistoryFilter(id = "rpa-history-filter", class = "rpa-filter-select"):
                    option(value = "all") "Todas"
                    option(value = "completed") "Concluídas"
                    option(value = "interrupted") "Interrompidas"
                    option(value = "corrected") "Corrigidas"
                divi id = "rpa-history-list", class = "rpa-list"
                divi id = "rpa-history-empty", class = "rpa-empty-state":
                  span class = "rpa-empty-icon":
                    text "◷"
                  strong "O histórico ainda está vazio"
                  p "As execuções aparecerão aqui com objetivo, resultado e horário."

            section id = "rpa-page-memory", class = "rpa-page rpa-content-page":
              header class = "rpa-page-header":
                divi:
                  span class = "rpa-page-eyebrow":
                    text "Continuidade"
                  h1 "Memória"
                  p "Conhecimentos e trajetórias preservados para as próximas tarefas."

              divi class = "rpa-page-grid rpa-memory-grid":
                article class = "rpa-card":
                  divi class = "rpa-card-heading":
                    divi:
                      span class = "rpa-card-kicker":
                        text "Conhecimento"
                      h2 "Coisas lembradas"
                  divi id = "assistant-thing-list", class = "rpa-list"
                  divi class = "rpa-empty-state rpa-memory-empty":
                    span class = "rpa-empty-icon":
                      text "◉"
                    strong "Nenhuma informação consolidada"
                    p "Preferências e fatos úteis aparecerão aqui quando forem preservados."

                article class = "rpa-card":
                  divi class = "rpa-card-heading":
                    divi:
                      span class = "rpa-card-kicker":
                        text "Aprendizado operacional"
                      h2 "Trajetórias"
                  divi id = "rpa-memory-trajectory-list", class = "rpa-list"
                  divi id = "rpa-memory-trajectory-empty", class = "rpa-empty-state":
                    span class = "rpa-empty-icon":
                      text "↻"
                    strong "Nenhuma trajetória confirmada"
                    p "A memória operacional será criada depois da validação de uma rotina."

            section id = "rpa-page-settings", class = "rpa-page rpa-content-page":
              header class = "rpa-page-header":
                divi:
                  span class = "rpa-page-eyebrow":
                    text "Preferências"
                  h1 "Configurações"
                  p "Comportamento da interface e recursos locais."

              divi class = "rpa-settings-stack":
                article class = "rpa-card rpa-settings-card":
                  divi class = "rpa-setting-copy":
                    h2 "Resposta por voz"
                    p "Reproduzir em voz alta as respostas depois de uma tarefa."
                  label class = "rpa-switch":
                    input AutoSpeak(id = "assistant-auto-speak", type = "checkbox")
                    span class = "rpa-switch-track"

                article class = "rpa-card rpa-settings-card":
                  divi class = "rpa-setting-copy":
                    h2 "Controles de voz"
                    p "Repetir a última resposta ou interromper a reprodução atual."
                  divi class = "rpa-setting-actions":
                    button RepeatVoice(
                      id = "assistant-repeat-voice",
                      type = "button",
                      class = "rpa-secondary-button"
                    ) "Repetir"
                    button StopVoice(
                      id = "assistant-stop-voice",
                      type = "button",
                      class = "rpa-secondary-button"
                    ) "Parar"

                article class = "rpa-card rpa-settings-card":
                  divi class = "rpa-setting-copy":
                    h2 "Dados locais"
                    p "Tarefas, automações e memórias permanecem armazenadas neste computador."
                  span class = "rpa-local-badge":
                    text "Local"

          aside class = "rpa-chat-panel":
            header class = "rpa-chat-header":
              divi:
                strong "Conversas"
                small "Mensagens da tarefa atual"
              span class = "rpa-chat-local-badge":
                text "Local"
            divi id = "assistant-messages", class = "rpa-chat-messages"
            divi class = "rpa-chat-feedback":
              divi id = "assistant-error"
              divi id = "assistant-voice-note"

          divi id = "assistant-notifications", class = "rpa-notification-stack"

          footer class = "rpa-composer-shell":
            divi class = "rpa-composer-context":
              span class = "rpa-status-dot"
              divi class = "rpa-context-copy":
                strong "Objetivo"
                br()
                small "Descreva o que deseja realizar"

            divi class = "rpa-composer":
              button Microphone(
                id = "assistant-microphone",
                type = "button",
                class = "rpa-action rpa-mic",
                title = "Falar"
              ) "◉"
              textarea Composer(
                id = "assistant-composer",
                placeholder = "Ex.: abra o cadastro, encontre o cliente e atualize o telefone...",
                autocomplete = "off",
                spellcheck = "true"
              )
              button Send(
                id = "assistant-send",
                type = "button",
                class = "rpa-action"
              ) "Executar"

          divi class = "rpa-runtime-controls"



      when GoBack clicks:
        workspace.goBack()

      when GoForward clicks:
        workspace.goForward()

      when Reload clicks:
        workspace.reload()

      when OpenTarget clicks:
        workspace.navigate(states.TargetUrl)

      when Address enters:
        states.TargetUrl = eventValue

  agents:
    CognitiveRpa:
      purpose """
Executar objetivos no computador local, aprender rotinas confirmadas e adaptar
trajetórias quando uma interface mudar. Operar páginas pela estrutura DOM sempre
que ela estiver disponível e usar automação visual para aplicações nativas,
canvas, diálogos ou elementos inacessíveis semanticamente.
"""
      rlm:
        conditions """
Pedidos simples de navegação, como “abra example.com”, devem executar diretamente
NavigatePage. Normalize domínios sem esquema acrescentando https://. Não use
resumo da sessão, mensagens anteriores ou memória como prova de execução atual.

Consulte RecallTrajectories para tarefas com múltiplas etapas, para trajetórias já
aprendidas ou quando reutilizar experiência anterior trouxer vantagem concreta.
A memória orienta a ação; ela não substitui a observação atual.

Na página central, comece com ObservePage ou FindElement. Prefira
ClickElement, FillElement, SelectOption, ReadElement, SubmitForm,
ScrollPage e WaitPage. Use seletores estáveis, rótulos, nomes, funções e
texto visível. Após uma ação, espere o estado esperado e leia novamente o campo,
a mensagem ou a página que confirma o efeito.

Use PyAutoGUI quando a operação estiver fora do DOM: aplicações desktop,
diálogos do sistema, canvas, áreas renderizadas como imagem ou páginas cujo DOM
não forneça um alvo confiável. Nesse canal, observe a tela antes da ação, use uma
região ou âncora visual precisa e compare o resultado depois. Evite coordenadas
absolutas quando houver imagem de referência ou região estável.

Uma trajetória pode combinar DOM e PyAutoGUI. Registre em actions as tools
e argumentos efetivamente usados, em anchors os seletores semânticos e as
referências visuais, e em verification os sinais que confirmaram o resultado.
Consolide com RememberTrajectory apenas depois da confirmação. Quando uma rotina
lembrada falhar, altere o menor conjunto de passos e use CorrectTrajectory.

Peça confirmação antes de pagamento, exclusão, publicação, envio definitivo ou
outra ação irreversível. Não exponha na resposta nomes de tools, seletores,
coordenadas, hashes, caminhos de captura ou detalhes internos, salvo quando o
usuário pedir diagnóstico. Mostre apenas o andamento necessário e o resultado
observado em linguagem natural.
"""

        Tool ObservePage(path, selector, maxElements, maxText, visibleOnly):
          systemPrompt """
Observa o documento atual da foreign Workspace via JavaScript. Retorna URL,
título, texto, elemento focado e elementos interativos com seletor reutilizável,
papel semântico, valor, estado e retângulo. path é opcional; selector usa body
quando omitido; maxElements=120, maxText=6000 e visibleOnly=true são os padrões.
"""

        Tool FindElement(path, selector, text, role, limit, visibleOnly):
          systemPrompt """
Localiza elementos na foreign Workspace por seletor CSS, texto e/ou papel
semântico. role reconhece tanto role explícito quanto papéis nativos de button,
link, checkbox, radio, textbox, combobox e option. Retorna matches com seletores
reutilizáveis. path é opcional; limit=30 e visibleOnly=true por padrão.
"""

        Tool ClickElement(path, selector, text, role, index):
          systemPrompt """
Clica via JavaScript em um elemento visível da foreign Workspace. Resolva o alvo
por selector, text e/ou role; index escolhe entre coincidências e começa em 0.
A tool centraliza o elemento, foca quando possível, dispara click() e devolve o
alvo observado e o estado imediato da página. Confirme efeitos com WaitPage ou
ReadElement quando a ação alterar a interface.
"""

        Tool FillElement(path, selector, text, value, index, clear):
          systemPrompt """
Preenche input, textarea ou contenteditable via JavaScript na foreign Workspace.
selector ou text identificam o campo; text considera label, aria-label,
placeholder e name. value é o conteúdo; index começa em 0; clear=true substitui
o valor atual. Dispara input e change e retorna o valor efetivamente observado.
"""

        Tool SelectOption(path, selector, value, label, index):
          systemPrompt """
Seleciona uma opção de <select> via JavaScript. selector identifica o select;
value tenta correspondência exata e label permite correspondência pelo texto
visível da opção. index começa em 0. Dispara input e change e retorna valor e
rótulo observados.
"""

        Tool ReadElement(path, selector, text, property, index):
          systemPrompt """
Lê uma propriedade de um elemento da foreign Workspace via JavaScript. Localize
por selector e/ou text. property aceita text, value, html, outerHtml, href,
checked, selectedText, attributes ou uma propriedade simples do DOM. index
começa em 0; property=text é o padrão.
"""

        Tool SubmitForm(path, selector, index):
          systemPrompt """
Submete via JavaScript o formulário indicado na foreign Workspace. selector pode
apontar para o próprio form ou para um elemento dentro dele; index começa em 0.
Prefere requestSubmit() para preservar a semântica normal da página.
"""

        Tool ScrollPage(path, selector, deltaX, deltaY, block):
          systemPrompt """
Rola a foreign Workspace via JavaScript. Com selector, leva o elemento à área
visível antes da rolagem; sem selector, rola window. deltaX=0, deltaY=600 e
block=center são os padrões.
"""

        Tool WaitPage(path, selector, text, expectedText, state, index, timeoutMs, pollMs):
          systemPrompt """
Espera e reavalia o DOM da foreign Workspace até a condição ser confirmada.
state aceita visible, exists, absent, hidden, enabled ou text. Para state=text,
use expectedText. selector/text localizam o alvo; index começa em 0;
timeoutMs=10000 e pollMs=200 por padrão.
"""

        Tool NavigatePage(path, url, readyTimeoutMs):
          systemPrompt """
Para pedidos como abrir, acessar ou navegar para um site, execute esta tool
imediatamente. url é obrigatória; domínios sem esquema recebem https://. path é
opcional e resolve a foreign Workspace. A implementação navega o WebContents e
sonda o próprio documento via JavaScript até interactive/complete ou o backend
informar ready. readyTimeoutMs=8000 por padrão. Não informe sucesso antes do
resultado retornado pela tool.
"""

        Tool ObserveScreen():
          systemPrompt "Captura a tela ou uma região para operar interfaces fora do DOM."

        Tool LocateImage():
          systemPrompt "Localiza uma referência visual na tela e retorna sua posição."

        Tool ReadPixel():
          systemPrompt "Lê a cor de um ponto quando ela for um sinal de estado suficiente."

        Tool MovePointer():
          systemPrompt "Move o ponteiro e pode verificar a região afetada."

        Tool Click():
          systemPrompt "Clica em uma posição da tela e compara o estado anterior e posterior."

        Tool DragPointer():
          systemPrompt "Arrasta o ponteiro e verifica o efeito visual."

        Tool WriteText():
          systemPrompt "Digita no elemento atualmente focado e verifica o resultado."

        Tool PressKey():
          systemPrompt "Pressiona uma tecla e verifica a alteração produzida."

        Tool Hotkey():
          systemPrompt "Executa uma combinação de teclas e verifica seu efeito."

        Tool ScrollScreen():
          systemPrompt "Rola uma interface visual fora do DOM."

        Tool Wait():
          systemPrompt "Aguarda a estabilização de uma interface visual."

        Tool ExecuteVisualTrajectory():
          systemPrompt "Executa uma sequência PyAutoGUI já confirmada; trajetórias DOM devem ser chamadas passo a passo."

        Tool RecallTrajectories():
          systemPrompt "Busca rotinas locais por objetivo, contexto, âncoras, ações e efeitos."

        Tool GetTrajectory():
          systemPrompt "Obtém uma rotina lembrada para inspeção antes da execução."

        Tool RememberTrajectory():
          systemPrompt "Consolida uma rotina somente após o resultado ter sido confirmado."

        Tool CorrectTrajectory():
          systemPrompt "Atualiza uma rotina quando a interface ou o efeito observado divergir."

  assistant:
    enabled true
    name "Glauco"
    shell false
    rlmAgent "CognitiveRpa"
    systemPrompt """
Você executa tarefas locais na página central e no computador. Receba o objetivo,
observe o estado atual, recupere aprendizados úteis, execute ações pequenas e
confirme o resultado. Durante a execução, escreva somente informações úteis ao
usuário. Não apresente ferramentas, canais, seletores, coordenadas, hashes,
caminhos de arquivos, raciocínio interno ou detalhes de implementação. Ao final,
diga de forma direta o que foi concluído, o que não pôde ser confirmado e, quando
necessário, qual decisão do usuário ainda é exigida.
"""
    language "pt-BR"
    voice ""
    voiceRecognition "whisper.cpp"
    autoSpeak false
    autoSendVoice true
    backgroundLearning true
    maxRecentMessages 24
    maxMemoryItems 24
    responseMaxTokens 2048
    learningMaxTokens 768

  render:
    CognitiveRpaShell()

when isMainModule:
  application.run(startModel = true)
