(() => {
  if (window.top !== window) return false;

  const VERSION = "foreign-overlay-v3";
  const HOST_ID = "glaucoplastic-assistant-foreign-host";

  if (
    window.__glaucoplasticAssistantForeignVersion === VERSION &&
    typeof window.__glaucoplasticAssistantForeignEnsure === "function"
  ) {
    window.__glaucoplasticAssistantForeignEnsure();
    return true;
  }

  window.__glaucoplasticAssistantForeignVersion = VERSION;

  const state =
    window.__glaucoplasticAssistantForeignState || {
      snapshot: null,
      initialized: false,
      lastResponseId: "",
      open: false,
      awaitingDispatch: false,
      processing: false,
      ensureTimer: 0,
      observer: null
    };

  window.__glaucoplasticAssistantForeignState = state;

  function valueText(value) {
    return value == null ? "" : String(value);
  }

  function documentParent() {
    return document.documentElement || document.body || null;
  }

  function emit(identity, value = null, checked = false) {
    const queue =
      window.__glaucoplasticAssistantForeignEvents ||
      (window.__glaucoplasticAssistantForeignEvents = []);

    queue.push({
      handlerId: "glaucoplastic-assistant",
      event: "assistant",
      identity,
      value,
      checked
    });
  }

  function scheduleEnsure(delay = 0) {
    if (state.ensureTimer) {
      clearTimeout(state.ensureTimer);
    }

    state.ensureTimer = window.setTimeout(() => {
      state.ensureTimer = 0;
      const host = ensureHost();

      if (!host) {
        scheduleEnsure(16);
      }
    }, Math.max(0, delay));

    return true;
  }

  function ensureHost() {
    const parent = documentParent();

    if (!parent) {
      scheduleEnsure(16);
      return null;
    }

    let host = document.getElementById(HOST_ID);

    if (host && !host.shadowRoot) {
      host.remove();
      host = null;
    }

    if (!host) {
      host = document.createElement("div");
      host.id = HOST_ID;
      host.style.cssText = [
        "all:initial",
        "position:fixed",
        "inset:0",
        "z-index:2147483647",
        "pointer-events:none",
        "contain:layout style paint"
      ].join(";");

      const shadow = host.attachShadow({ mode: "open" });

      shadow.innerHTML = `
        <style>
          :host { all: initial; }

          * { box-sizing: border-box; }

          button,
          textarea {
            font: inherit;
          }

          .root {
            position: fixed;
            inset: 0;
            z-index: 2147483647;
            pointer-events: none;
            color: #eef3f8;
            font-family:
              system-ui,
              -apple-system,
              BlinkMacSystemFont,
              "Segoe UI",
              sans-serif;
          }

          .panel {
            position: absolute;
            top: 0;
            right: 0;
            width: 336px;
            height: 100%;
            display: none;
            flex-direction: column;
            overflow: hidden;
            pointer-events: auto;
            border-left: 1px solid #2a3443;
            background: rgba(13, 18, 25, .985);
            box-shadow: -18px 0 44px rgba(0, 0, 0, .38);
          }

          .root.open .panel {
            display: flex;
          }

          .head {
            flex: 0 0 58px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
            padding: 10px 13px;
            border-bottom: 1px solid #2a3443;
          }

          .head div {
            display: grid;
            gap: 2px;
          }

          .head strong {
            font-size: 13px;
          }

          .head small {
            color: #909bad;
            font-size: 10px;
          }

          .badge {
            padding: 4px 7px;
            border: 1px solid #355344;
            border-radius: 999px;
            color: #6dd3a0;
            font-size: 9px;
            font-weight: 800;
            text-transform: uppercase;
            letter-spacing: .08em;
          }

          .messages {
            flex: 1 1 auto;
            min-height: 0;
            overflow: auto;
            display: flex;
            flex-direction: column;
            gap: 8px;
            padding: 12px 11px 92px;
          }

          .empty {
            margin: auto;
            max-width: 250px;
            color: #909bad;
            text-align: center;
            font-size: 12px;
            line-height: 1.45;
          }

          .message {
            width: auto;
            max-width: 92%;
            padding: 9px 10px;
            border: 1px solid #2a3443;
            border-radius: 10px;
            background: #121923;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            font-size: 12px;
            line-height: 1.45;
          }

          .message.user {
            align-self: flex-end;
            background: #19150e;
            border-color: #514328;
          }

          .message.assistant {
            align-self: flex-start;
          }

          .time {
            display: block;
            margin-top: 5px;
            color: #909bad;
            font-size: 9px;
          }

          .feedback {
            position: absolute;
            left: 10px;
            right: 10px;
            bottom: 78px;
            color: #ff9b9b;
            font-size: 10px;
            pointer-events: none;
          }

          .composer-shell {
            position: absolute;
            left: 50%;
            bottom: 14px;
            width: min(900px, calc(100vw - 32px));
            transform: translateX(-50%);
            pointer-events: auto;
          }

          .root.open .composer-shell {
            left: auto;
            right: 0;
            bottom: 0;
            width: 336px;
            transform: none;
            padding: 8px;
            border-top: 1px solid #2a3443;
            background: rgba(13, 18, 25, .985);
          }

          .composer {
            min-width: 0;
            display: grid;
            grid-template-columns: auto minmax(0, 1fr) auto;
            align-items: center;
            gap: 8px;
            padding: 7px;
            border: 1px solid #6f5d35;
            border-radius: 13px;
            background: rgba(10, 14, 20, .975);
            box-shadow: 0 16px 42px rgba(0, 0, 0, .44);
          }

          .root.open .composer {
            border-radius: 10px;
            box-shadow: none;
          }

          .round,
          .send {
            height: 44px;
            border: 1px solid #6f5d35;
            border-radius: 9px;
            background: #241d10;
            color: #f0b84c;
            cursor: pointer;
          }

          .round {
            width: 44px;
            padding: 0;
          }

          .round.listening {
            color: #ff8c8c;
            border-color: #7b3838;
          }

          .send {
            padding: 0 13px;
            font-weight: 750;
          }

          textarea {
            width: 100%;
            height: 44px;
            min-height: 44px;
            max-height: 104px;
            padding: 11px 12px;
            resize: none;
            overflow-y: auto;
            border: 1px solid #2a3443;
            border-radius: 9px;
            outline: none;
            background: #0b1016;
            color: #eef3f8;
          }

          textarea:focus {
            border-color: #6f5d35;
          }

          textarea:disabled,
          button:disabled {
            cursor: wait;
            opacity: .55;
          }

          .queue-state {
            min-height: 14px;
            margin: 5px 4px 0;
            color: #909bad;
            font-size: 10px;
            line-height: 1.3;
            text-align: right;
          }

          .processing-status {
            position: absolute;
            top: 12px;
            right: 12px;
            display: none;
            align-items: center;
            gap: 7px;
            padding: 7px 10px;
            border: 1px solid #6f5d35;
            border-radius: 999px;
            background: rgba(16, 20, 27, .96);
            color: #f0b84c;
            box-shadow: 0 12px 28px rgba(0, 0, 0, .34);
            font-size: 10px;
            font-weight: 800;
            text-transform: uppercase;
            letter-spacing: .08em;
            pointer-events: none;
          }

          .root.processing .processing-status {
            display: flex;
          }

          .root.open .processing-status {
            right: 348px;
          }

          .processing-dot {
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background: currentColor;
            animation: glauco-processing-pulse 1s ease-in-out infinite;
          }

          @keyframes glauco-processing-pulse {
            0%,
            100% {
              opacity: .35;
              transform: scale(.82);
            }

            50% {
              opacity: 1;
              transform: scale(1);
            }
          }

          .toasts {
            position: absolute;
            top: 52px;
            right: 12px;
            width: min(360px, calc(100vw - 24px));
            display: grid;
            gap: 7px;
            pointer-events: none;
          }

          .root.open .toasts {
            right: 348px;
          }

          .toast {
            padding: 10px 11px;
            border: 1px solid #6f5d35;
            border-radius: 10px;
            background: rgba(18, 24, 33, .985);
            color: #eef3f8;
            box-shadow: 0 16px 38px rgba(0, 0, 0, .44);
            opacity: 0;
            transform: translateY(-7px);
            transition: .18s ease;
            pointer-events: auto;
            cursor: pointer;
          }

          .toast.visible {
            opacity: 1;
            transform: translateY(0);
          }

          .toast strong {
            display: block;
            color: #f0b84c;
            font-size: 10px;
          }

          .toast span {
            display: -webkit-box;
            margin-top: 3px;
            color: #eef3f8;
            font-size: 11px;
            line-height: 1.35;
            -webkit-line-clamp: 3;
            -webkit-box-orient: vertical;
            overflow: hidden;
          }
        </style>

        <div class="root">
          <section class="panel">
            <header class="head">
              <div>
                <strong>Conversas</strong>
                <small>Mensagens da tarefa atual</small>
              </div>

              <span class="badge">Local</span>
            </header>

            <div class="messages">
              <div class="empty">
                A conversa atual aparecerá aqui.
              </div>
            </div>

            <div class="feedback"></div>
          </section>

          <div class="processing-status">
            <span class="processing-dot"></span>
            <span class="processing-text">Processando</span>
          </div>

          <div class="toasts"></div>

          <footer class="composer-shell">
            <div class="composer">
              <button
                class="round microphone"
                type="button"
                title="Falar"
              >◉</button>

              <textarea
                class="input"
                placeholder="Descreva o que deseja realizar..."
              ></textarea>

              <button class="send" type="button">
                Executar
              </button>
            </div>

            <div class="queue-state"></div>
          </footer>
        </div>
      `;

      parent.appendChild(host);
      bind(shadow);
    }

    renderCurrentState(host);
    installObserver();

    return host;
  }

  function installObserver() {
    if (state.observer || !document.documentElement) {
      return;
    }

    state.observer = new MutationObserver(() => {
      if (!document.getElementById(HOST_ID)) {
        scheduleEnsure(0);
      }
    });

    state.observer.observe(document.documentElement, {
      childList: true,
      subtree: true
    });
  }

  function controlsFrom(host = null) {
    const resolvedHost =
      host || document.getElementById(HOST_ID);

    if (!resolvedHost || !resolvedHost.shadowRoot) {
      return null;
    }

    const shadow = resolvedHost.shadowRoot;

    return {
      host: resolvedHost,
      root: shadow.querySelector(".root"),
      messages: shadow.querySelector(".messages"),
      feedback: shadow.querySelector(".feedback"),
      toasts: shadow.querySelector(".toasts"),
      microphone: shadow.querySelector(".microphone"),
      input: shadow.querySelector(".input"),
      send: shadow.querySelector(".send"),
      queueState: shadow.querySelector(".queue-state"),
      processingText:
        shadow.querySelector(".processing-text")
    };
  }

  function queueInfo(snapshot) {
    const queue = snapshot && snapshot.chatQueue || {};
    const queued = Number(queue.queued || 0);
    const active = Boolean(queue.active);
    const totalPending = Number(
      queue.totalPending ||
      queued + (active ? 1 : 0)
    );

    return {
      queued,
      active,
      totalPending
    };
  }

  function runtimeIsProcessing(snapshot) {
    const status = valueText(
      snapshot && snapshot.status
    ).toLowerCase();

    const queue = queueInfo(snapshot);

    return (
      status === "thinking" ||
      status === "processing" ||
      status === "running" ||
      queue.totalPending > 0
    );
  }

  function updateInteraction(controls) {
    if (!controls) return;

    const snapshot = state.snapshot || {};
    const queue = queueInfo(snapshot);
    const processing = runtimeIsProcessing(snapshot);

    state.processing = processing;

    if (processing || snapshot.lastError) {
      state.awaitingDispatch = false;
    }

    controls.root.classList.toggle(
      "processing",
      processing
    );

    controls.input.disabled = state.awaitingDispatch;
    controls.send.disabled = state.awaitingDispatch;
    controls.microphone.disabled = state.awaitingDispatch;

    controls.send.textContent =
      processing ? "Enfileirar" : "Executar";

    controls.input.placeholder =
      state.awaitingDispatch
        ? "Enviando mensagem..."
        : processing
          ? "Digite outra mensagem para acrescentar à fila..."
          : "Descreva o que deseja realizar...";

    if (controls.queueState) {
      if (state.awaitingDispatch) {
        controls.queueState.textContent =
          "Enviando para o processamento...";
      } else if (queue.totalPending === 1) {
        controls.queueState.textContent =
          "1 mensagem em processamento";
      } else if (queue.totalPending > 1) {
        controls.queueState.textContent =
          queue.totalPending +
          " mensagens em processamento ou na fila";
      } else {
        controls.queueState.textContent = "";
      }
    }

    if (controls.processingText) {
      controls.processingText.textContent = "Processando";
    }
  }

  function formatTime(value) {
    if (!value) return "";

    const date = new Date(value);

    if (Number.isNaN(date.getTime())) {
      return "";
    }

    return date.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit"
    });
  }

  function renderMessages(controls, snapshot) {
    if (!controls) return;

    const session =
      snapshot && snapshot.activeSession || {};
    const messages = session.messages || [];

    controls.messages.replaceChildren();

    if (!messages.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent =
        "A conversa atual aparecerá aqui.";
      controls.messages.appendChild(empty);
      return;
    }

    for (const message of messages) {
      const bubble = document.createElement("article");
      bubble.className =
        "message " +
        (message.role === "user"
          ? "user"
          : "assistant");

      const body = document.createElement("div");
      body.textContent = valueText(message.content);

      const time = document.createElement("span");
      time.className = "time";
      time.textContent = formatTime(message.createdAt);

      bubble.append(body, time);
      controls.messages.appendChild(bubble);
    }

    requestAnimationFrame(() => {
      controls.messages.scrollTop =
        controls.messages.scrollHeight;
    });
  }

  function showToast(message, responseId) {
    const content = valueText(message).trim();

    if (!content) return;

    const controls = controlsFrom();

    if (!controls) return;

    const toast = document.createElement("button");
    toast.type = "button";
    toast.className = "toast";

    const title = document.createElement("strong");
    title.textContent = "Glauco respondeu";

    const preview = document.createElement("span");
    preview.textContent =
      content.length > 240
        ? content.slice(0, 237) + "…"
        : content;

    toast.append(title, preview);

    toast.addEventListener("click", () => {
      setOpen(true);
      toast.remove();
    });

    controls.toasts.appendChild(toast);

    requestAnimationFrame(() => {
      toast.classList.add("visible");
    });

    setTimeout(() => {
      toast.classList.remove("visible");
      setTimeout(() => toast.remove(), 220);
    }, 9000);

    if (
      "Notification" in window &&
      Notification.permission === "granted" &&
      !document.hasFocus()
    ) {
      try {
        new Notification("Glauco", {
          body: preview.textContent,
          tag:
            "glauco-response-" +
            valueText(responseId)
        });
      } catch (_) {}
    }
  }

  function renderCurrentState(host = null) {
    const controls = controlsFrom(host);

    if (!controls) return false;

    controls.root.classList.toggle(
      "open",
      Boolean(state.open)
    );

    if (state.snapshot) {
      renderMessages(controls, state.snapshot);

      controls.feedback.textContent =
        valueText(state.snapshot.lastError);

      const voice = valueText(
        state.snapshot.voiceState
      ).toLowerCase();

      controls.microphone.classList.toggle(
        "listening",
        voice === "recording" ||
        voice === "starting"
      );

      if (
        state.snapshot.lastTranscriptId &&
        state.snapshot.lastTranscript &&
        !controls.input.value.trim()
      ) {
        controls.input.value =
          valueText(state.snapshot.lastTranscript);
      }
    }

    updateInteraction(controls);

    return true;
  }

  function applySnapshot(snapshot) {
    if (!snapshot || typeof snapshot !== "object") {
      return false;
    }

    state.snapshot = snapshot;

    const processing = runtimeIsProcessing(snapshot);

    if (processing || snapshot.lastError) {
      state.awaitingDispatch = false;
    }

    const host = ensureHost();

    if (!host) {
      scheduleEnsure(16);
      return false;
    }

    renderCurrentState(host);

    if (
      snapshot.lastResponseId &&
      snapshot.lastResponseId !==
        state.lastResponseId
    ) {
      const notify = state.initialized;
      state.lastResponseId =
        snapshot.lastResponseId;

      if (notify) {
        showToast(
          snapshot.lastResponse,
          snapshot.lastResponseId
        );
      }
    }

    state.initialized = true;
    return true;
  }

  function setOpen(open) {
    state.open = Boolean(open);

    const host = ensureHost();

    if (!host) {
      scheduleEnsure(16);
      return false;
    }

    const controls = controlsFrom(host);

    if (controls) {
      controls.root.classList.toggle(
        "open",
        state.open
      );
    }

    return true;
  }

  function send() {
    const controls = controlsFrom();

    if (!controls || state.awaitingDispatch) {
      return;
    }

    const value = controls.input.value.trim();

    if (!value) return;

    state.awaitingDispatch = true;
    updateInteraction(controls);

    emit("assistant:send", value);

    controls.input.value = "";
    controls.input.style.height = "44px";
  }

  function bind(shadow) {
    if (shadow.__glaucoplasticAssistantBound) {
      return;
    }

    shadow.__glaucoplasticAssistantBound = true;

    const input = shadow.querySelector(".input");
    const sendButton = shadow.querySelector(".send");
    const microphone =
      shadow.querySelector(".microphone");

    sendButton.addEventListener("click", send);

    input.addEventListener("keydown", event => {
      if (
        event.key === "Enter" &&
        !event.shiftKey
      ) {
        event.preventDefault();
        send();
      }
    });

    input.addEventListener("input", event => {
      const field = event.currentTarget;
      field.style.height = "44px";
      field.style.height =
        Math.min(field.scrollHeight, 104) + "px";
    });

    microphone.addEventListener("click", () => {
      if (state.awaitingDispatch) return;

      const voice = valueText(
        state.snapshot &&
        state.snapshot.voiceState
      ).toLowerCase();

      const recording =
        voice === "recording" ||
        voice === "starting";

      emit(
        recording
          ? "assistant:voice-stop"
          : "assistant:voice-start"
      );
    });
  }

  window.__glaucoplasticAssistantForeignApply =
    applySnapshot;

  window.__glaucoplasticAssistantForeignSetOpen =
    setOpen;

  window.__glaucoplasticAssistantForeignEnsure =
    scheduleEnsure;

  window.__glaucoplasticAssistantForeignApiReady =
    () => true;

  if (documentParent()) {
    ensureHost();
  } else {
    document.addEventListener(
      "DOMContentLoaded",
      () => scheduleEnsure(0),
      { once: true }
    );

    scheduleEnsure(16);
  }

  return true;
})();
