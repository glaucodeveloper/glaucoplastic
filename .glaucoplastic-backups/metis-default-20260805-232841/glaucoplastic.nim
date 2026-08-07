## GlaucoPlastic
## Framework monolítico funcional: parser da DSL, planos, runtimes,
## frontend WebKitGTK/WebView, ORM, OKF, memória Metis, llama.cpp, RLM,
## agentes, instalação e geradores.
##
## Este arquivo foi estruturado para ser importado por outro projeto Nimble:
##
##   import glaucoplastic
##
## O backend nativo de WebContentsView é registrado por callbacks para manter
## o framework monolítico e permitir WebView2, WebKitGTK ou WKWebView sem
## impor um toolkit visual específico ao projeto consumidor.

import std/strtabs
import std/dynlib
import nimpy
import nimpy/py_lib

type
  PlasticPyGILState = cint
  PlasticPyGILEnsureProc = proc(): PlasticPyGILState {.cdecl, gcsafe.}
  PlasticPyGILReleaseProc = proc(state: PlasticPyGILState) {.cdecl, gcsafe.}
  PlasticPyEvalSaveThreadProc = proc(): pointer {.cdecl, gcsafe.}

var
  plasticPythonLibraryHandle: LibHandle
  plasticPyGILEnsureProc: PlasticPyGILEnsureProc
  plasticPyGILReleaseProc: PlasticPyGILReleaseProc
  plasticPyEvalSaveThreadProc: PlasticPyEvalSaveThreadProc

proc plasticInitializePythonThreading(pythonLibraryPath: string) =
  if plasticPyGILEnsureProc.isNil:
    # Inicializa CPython no thread principal uma única vez. Depois libera o
    # GIL; todas as chamadas posteriores, inclusive no worker Nim, passam por
    # PyGILState_Ensure/Release. O handle é carregado diretamente porque o
    # NimPy 0.2.1 não exporta o campo interno pyLib.module.
    discard pyImport("sys")

    if pythonLibraryPath.len == 0:
      raise newException(
        ValueError,
        "O caminho da libpython do runtime Metis está vazio."
      )

    plasticPythonLibraryHandle = loadLib(pythonLibraryPath, true)
    if plasticPythonLibraryHandle.isNil:
      raise newException(
        ValueError,
        "Não foi possível carregar a libpython do runtime Metis: " &
        pythonLibraryPath
      )

    plasticPyGILEnsureProc = cast[PlasticPyGILEnsureProc](
      plasticPythonLibraryHandle.symAddr("PyGILState_Ensure")
    )
    plasticPyGILReleaseProc = cast[PlasticPyGILReleaseProc](
      plasticPythonLibraryHandle.symAddr("PyGILState_Release")
    )
    plasticPyEvalSaveThreadProc = cast[PlasticPyEvalSaveThreadProc](
      plasticPythonLibraryHandle.symAddr("PyEval_SaveThread")
    )
    if plasticPyGILEnsureProc.isNil or plasticPyGILReleaseProc.isNil or
        plasticPyEvalSaveThreadProc.isNil:
      raise newException(
        ValueError,
        "A biblioteca Python não expõe a API necessária de GIL."
      )
    discard plasticPyEvalSaveThreadProc()

proc plasticAcquirePythonGIL(): PlasticPyGILState {.inline.} =
  plasticPyGILEnsureProc()

proc plasticReleasePythonGIL(state: PlasticPyGILState) {.inline.} =
  plasticPyGILReleaseProc(state)

import std/[
  base64,
  streams,
  nativesockets,
  httpcore,
  asyncdispatch,
  asynchttpserver,
  algorithm,
  httpclient,
  json,
  macros,
  options,
  os,
  osproc,
  locks,
  sequtils,
  sets,
  strformat,
  strutils,
  tables,
  times,
  uri
]


# Necessário para procedimentos {.async.} emitidos pela macro no consumidor.
export asyncdispatch


type
  PlasticNetworkWebRenderProc* = proc(): string {.closure.}
  PlasticNetworkWebEventProc* = proc(event: JsonNode) {.closure.}
  PlasticNetworkWebPollProc* = proc(): JsonNode {.closure.}

  PlasticNetworkWebOptions* = object
    enabled*: bool
    host*: string
    port*: int

proc plasticNetworkWebOptions*(
  parameters = commandLineParams()
): PlasticNetworkWebOptions =
  result.host = getEnv("GLAUCOPLASTIC_NW_HOST", "0.0.0.0")
  result.port = 8765

  let environmentPort = getEnv("GLAUCOPLASTIC_NW_PORT", "").strip
  if environmentPort.len > 0:
    try:
      result.port = parseInt(environmentPort)
    except ValueError:
      discard

  for parameter in parameters:
    if parameter == "--nw":
      result.enabled = true
    elif parameter.startsWith("--nw="):
      result.enabled = true
      let value = parameter["--nw=".len .. ^1].strip
      if value.len > 0:
        try:
          result.port = parseInt(value)
        except ValueError:
          result.host = value
    elif parameter.startsWith("--nw-port="):
      result.enabled = true
      let value = parameter["--nw-port=".len .. ^1].strip
      try:
        result.port = parseInt(value)
      except ValueError:
        raise newException(ValueError, "Porta inválida em --nw-port: " & value)
    elif parameter.startsWith("--nw-host="):
      result.enabled = true
      result.host = parameter["--nw-host=".len .. ^1].strip

  if result.host.len == 0:
    result.host = "0.0.0.0"
  if result.port < 1 or result.port > 65535:
    raise newException(ValueError, "A porta do modo --nw deve estar entre 1 e 65535.")

proc plasticNetworkWebBridgeScript(): string =
  r"""
  <script>
  (() => {
    if (window.__glaucoplasticNetworkBridgeInstalled) return;
    window.__glaucoplasticNetworkBridgeInstalled = true;
    window.__glaucoplasticNetworkWeb = true;

    let sending = false;
    let polling = false;

    function eventQueue() {
      return window.__glaucoplasticEvents ||
        (window.__glaucoplasticEvents = []);
    }

    function findIdentity(path) {
      return Array.from(
        document.querySelectorAll('[data-glauco-identity]')
      ).find(element => element.dataset.glaucoIdentity === path) || null;
    }

    function applyProperty(update) {
      if (!update || !update.path || !update.property) return;
      const element = findIdentity(update.path);
      if (!element) return;

      if (update.property === 'textContent' || update.property === 'innerHTML') {
        element[update.property] = typeof update.value === 'string'
          ? update.value
          : JSON.stringify(update.value);
      } else {
        element[update.property] = update.value;
      }
    }

    function applyPayload(payload) {
      if (!payload || typeof payload !== 'object') return;
      if (Array.isArray(payload.properties)) {
        payload.properties.forEach(applyProperty);
      }
      if (payload.assistant && window.__glaucoplasticAssistantApply) {
        window.__glaucoplasticAssistantApply(payload.assistant);
      }
    }

    async function postEvents() {
      if (sending) return;
      const queue = eventQueue();
      if (!queue.length) return;

      const events = queue.splice(0, queue.length);
      sending = true;
      try {
        const response = await fetch('/__glaucoplastic/events', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(events),
          cache: 'no-store'
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        applyPayload(await response.json());
      } catch (error) {
        queue.unshift(...events);
        console.error('GlaucoPlastic event transport:', error);
      } finally {
        sending = false;
      }
    }

    async function poll() {
      if (polling) return;
      polling = true;
      try {
        const response = await fetch('/__glaucoplastic/poll', {cache: 'no-store'});
        if (response.ok) applyPayload(await response.json());
      } catch (error) {
        console.debug('GlaucoPlastic poll:', error);
      } finally {
        polling = false;
      }
    }

    window.setInterval(postEvents, 50);
    window.setInterval(poll, 200);
    postEvents();
    poll();
  })();
  </script>
  """

proc plasticNetworkWebDocument(html: string): string =
  result = html
  let bridge = plasticNetworkWebBridgeScript()
  if result.contains("</body>"):
    result = result.replace("</body>", bridge & "\n</body>")
  else:
    result.add bridge

proc runPlasticNetworkWebServer*(
  host: string;
  port: int;
  renderHtml: PlasticNetworkWebRenderProc;
  dispatchEvent: PlasticNetworkWebEventProc;
  pollState: PlasticNetworkWebPollProc
) =
  if renderHtml.isNil or dispatchEvent.isNil or pollState.isNil:
    raise newException(ValueError, "O servidor --nw recebeu callbacks incompletos.")

  let server = newAsyncHttpServer()

  proc callback(request: Request) {.async, gcsafe.} =
    var status = Http200
    var contentType = "application/json; charset=utf-8"
    var body = ""

    try:
      case request.url.path
      of "/", "/index.html":
        contentType = "text/html; charset=utf-8"
        {.cast(gcsafe).}:
          body = plasticNetworkWebDocument(renderHtml())
      of "/__glaucoplastic/health":
        body = "{\"ok\":true}"
      of "/__glaucoplastic/poll":
        {.cast(gcsafe).}:
          body = $pollState()
      of "/__glaucoplastic/events":
        if request.reqMethod != HttpPost:
          status = Http405
          body = "{\"ok\":false,\"error\":\"POST required\"}"
        else:
          let parsed = parseJson(request.body)
          let events = if parsed.kind == JArray: parsed else: %*[parsed]
          {.cast(gcsafe).}:
            for event in events.items:
              if event.kind == JObject:
                dispatchEvent(event)
            body = $pollState()
      else:
        status = Http404
        body = "{\"ok\":false,\"error\":\"not found\"}"
    except CatchableError as error:
      status = Http400
      body = $(%*{"ok": false, "error": error.msg})

    await request.respond(
      status,
      body,
      newHttpHeaders({
        "Content-Type": contentType,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff"
      })
    )

  let displayHost = if host == "0.0.0.0": "127.0.0.1" else: host
  echo "GlaucoPlastic --nw: http://" & displayHost & ":" & $port
  echo "GlaucoPlastic --nw escutando em " & host & ":" & $port
  waitFor server.serve(Port(port), callback, address = host)


proc applyTemplate*(sourceText: string; replacements: openArray[tuple[key, value: string]]): string =
  result = sourceText
  for replacement in replacements:
    result = result.replace(replacement.key, replacement.value)

proc plasticDefaultLlamaModelRepo*(): string =
  getEnv("GLAUCOPLASTIC_MODEL_REPO", "unsloth/gemma-4-E4B-it-GGUF")

proc plasticDefaultLlamaModelFile*(): string =
  getEnv("GLAUCOPLASTIC_MODEL_FILE", "gemma-4-E4B-it-Q4_K_M.gguf")

proc plasticDefaultLlamaModelPath*(): string =
  let configured = getEnv("GLAUCOPLASTIC_MODEL_PATH")
  if configured.len > 0:
    return expandTilde(configured)

  let modelFile = plasticDefaultLlamaModelFile()
  for candidate in [
    getCurrentDir() / "models" / modelFile,
    getAppDir() / "models" / modelFile,
    getHomeDir() / "models" / modelFile
  ]:
    if fileExists(candidate):
      return candidate

  result = getAppDir() / "models" / modelFile

proc plasticDefaultLlamaModelDir*(modelPath = plasticDefaultLlamaModelPath()): string =
  if modelPath.len > 0:
    result = modelPath.parentDir
  else:
    result = getAppDir() / "models"

proc plasticDefaultLlamaDownloadScript*(): string =
  for candidate in [
    getAppDir() / "scripts" / "download-gemma4.sh",
    getCurrentDir() / "scripts" / "download-gemma4.sh",
    getAppDir() / "scripts" / "configure-qwen3-model.sh",
    getCurrentDir() / "scripts" / "configure-qwen3-model.sh"
  ]:
    if fileExists(candidate):
      return candidate
  result = ""

proc plasticDefaultLlamaAutoDownload*(): bool =
  getEnv("GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL", "0") != "0"

proc plasticParseIntFallback(value: string; fallback: int): int =
  try:
    parseInt(value.strip)
  except CatchableError:
    fallback

proc plasticSplitTargets(value: string): seq[string] =
  for rawPart in value.split({';', ','}):
    let part = rawPart.strip
    if part.len > 0:
      result.add part

proc plasticUniqueHosts(values: openArray[string]): seq[string] =
  for value in values:
    if value.len > 0 and value notin result:
      result.add value

proc plasticUniquePorts(values: openArray[int]): seq[int] =
  for value in values:
    if value > 0 and value notin result:
      result.add value

proc plasticDefaultLlamaHostCandidates*(): seq[string] =
  result = plasticUniqueHosts([
    getEnv("GLAUCOPLASTIC_LLAMA_HOST", "127.0.0.1"),
    "localhost",
    "0.0.0.0"
  ])

proc plasticDefaultLlamaPortCandidates*(): seq[int] =
  let configured = plasticParseIntFallback(
    getEnv("GLAUCOPLASTIC_LLAMA_PORT", "1223"),
    1223
  )
  var extraPorts: seq[int]
  for item in plasticSplitTargets(getEnv("GLAUCOPLASTIC_LLAMA_PORTS")):
    let port = plasticParseIntFallback(item, 0)
    if port > 0:
      extraPorts.add port

  result = plasticUniquePorts(@[configured, 1223, 1224, 1225, 1230, 8080] & extraPorts)

proc plasticLlamaPortSelectionTimeoutSeconds*(): int =
  max(
    5,
    plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_LLAMA_PORT_SELECTION_TIMEOUT_SECONDS", "45"),
      45
    )
  )

proc plasticLlamaPortProbeSeconds*(): int =
  max(
    1,
    plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_LLAMA_PORT_PROBE_SECONDS", "3"),
      3
    )
  )

proc plasticDebugTrace*(message: string) =
  try:
    if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.toLowerAscii notin [
      "1", "true", "yes", "on", "enabled"
    ]:
      return

    stderr.writeLine("[GlaucoPlastic] " & message)

    let path = getEnv(
      "GLAUCOPLASTIC_UI_TRACE_FILE",
      "/tmp/glaucoplastic-ui-trace.log"
    )
    let line = "[" & $epochTime().int64 & "] " & message & "\n"
    if not fileExists(path):
      writeFile(path, line)
    else:
      var logFile: File
      if open(logFile, path, fmAppend):
        defer:
          close(logFile)
        logFile.write(line)
  except CatchableError:
    discard

# -----------------------------------------------------------------------------
# Tipagens públicas — as implementações são materializadas pela macro
# -----------------------------------------------------------------------------

type
  PlasticError* = object of CatchableError
  PlasticInstallationError* = object of PlasticError
  PlasticRuntimeError* = object of PlasticError
  PlasticForeignBackendError* = object of PlasticError
  PlasticAgentError* = object of PlasticError

type
  PlasticPlan* = ref object
    root*: JsonNode

type
  PlasticInstallScope* = enum
    pisPerUser,
    pisPerMachine

  PlasticProductConfig* = object
    title*: string
    description*: string
    version*: string

  PlasticInstallationConfig* = object
    productName*: string
    manufacturer*: string
    version*: string
    upgradeCode*: string
    scope*: PlasticInstallScope
    executableName*: string
    iconPath*: string
    installRootName*: string
    installRelativePath*: string
    dataRootName*: string
    dataRelativePath*: string
    dataDirectories*: seq[string]
    assets*: seq[JsonNode]
    desktopShortcut*: bool
    startMenuShortcut*: bool

  PlasticInstallationRuntime* = ref object
    config*: PlasticInstallationConfig
    installRoot*: string
    dataRoot*: string
    dataPath*: string
    okfPath*: string
    metisMemoryPath*: string
    sessionPath*: string
    ormPath*: string

  PlasticSafeStorageConfig* = object
    serviceName*: string
    label*: string

  PlasticSafeStorageRuntime* = ref object
    config*: PlasticSafeStorageConfig

  PlasticSafeStorageCredential* = object
    username*: string
    secret*: string

type
  PlasticStateChange* = object
    name*: string
    path*: string
    previousValue*: JsonNode
    currentValue*: JsonNode
    changedAt*: DateTime

  PlasticStateListener* = proc(change: PlasticStateChange) {.closure.}

  PlasticStateRuntime* = ref object
    values*: Table[string, JsonNode]
    listeners*: Table[string, seq[PlasticStateListener]]
    descriptors*: JsonNode

type
  PlasticOrmRuntime* = ref object
    path*: string
    data*: JsonNode
    schema*: JsonNode

type
  PlasticOkfRuntime* = ref object
    rootPath*: string
    indexPath*: string
    index*: JsonNode
    spaces*: JsonNode

proc newPlasticOkfRuntime*(rootPath: string): PlasticOkfRuntime =
  let indexPath = rootPath / "index.json"
  PlasticOkfRuntime(
    rootPath: rootPath,
    indexPath: indexPath,
    index:
      if fileExists(indexPath):
        try:
          parseJson(readFile(indexPath))
        except CatchableError:
          %*{"version": 1, "items": []}
      else:
        %*{"version": 1, "items": []},
    spaces: newJObject()
  )

type
  PlasticMetisMemoryConfig* = object
    enabled*: bool
    startup*: bool
    prepareRuntime*: bool
    autoInstallDependencies*: bool
    autoDownloadModel*: bool
    pythonVersion*: string
    pythonVenv*: string
    modelId*: string
    profile*: string
    device*: string
    dtypeName*: string
    quantization*: string
    layout*: string
    queryTokens*: int
    memoryMode*: string
    workerMaxTokens*: int
    workerDelay*: float
    recentMessages*: int

  PlasticMetisMemoryJob* = object
    timestamp*: string
    session*: string
    userText*: string
    assistantText*: string
    extractWithLlama*: bool

  PlasticMetisWorkerState* = ref object
    memory*: PlasticMetisMemory
    llamaEndpoint*: string
    llamaModel*: string
    queueLock*: Lock
    modelLock*: Lock
    jobs*: seq[PlasticMetisMemoryJob]
    running*: bool
    stopping*: bool
    active*: bool
    processed*: int
    skipped*: int
    failed*: int
    lastError*: string

  PlasticMetisMemory* = ref object
    config*: PlasticMetisMemoryConfig
    rootPath*: string
    runtimeRoot*: string
    pythonVenvPath*: string
    pythonExecutable*: string
    pythonLibrary*: string
    pythonPaths*: seq[string]
    modelPath*: string
    modelCachePath*: string
    profileDir*: string
    snapshotPath*: string
    exchangesPath*: string
    eventsPath*: string
    torchModule*: PyObject
    transformersModule*: PyObject
    metisMemoryUtilsModule*: PyObject
    tokenizerObject*: PyObject
    modelObject*: PyObject
    inputDeviceObject*: PyObject
    workerState*: PlasticMetisWorkerState
    workerThread*: Thread[PlasticMetisWorkerState]
    runtimePrepared*: bool
    modelPrepared*: bool
    initialized*: bool
    lastError*: string

type
  PlasticForeignStatus* = enum
    pfsIdle,
    pfsLoading,
    pfsReady,
    pfsNavigating,
    pfsFailed,
    pfsClosed

  PlasticForeignUrlChangedProc* = proc(path, url: string) {.closure.}
  PlasticForeignEventProc* = proc(path, eventName: string) {.closure.}

  PlasticForeignElementRuntime* = ref object
    path*: string
    componentName*: string
    variableName*: string
    identityName*: string
    url*: string
    urlStateName*: string
    status*: PlasticForeignStatus
    statusCss*: Table[string, string]
    documentStartScripts*: seq[string]
    eventPlans*: JsonNode
    currentUrl*: string
    lastMessage*: JsonNode
    lastError*: JsonNode
    lastGeometryKey*: string
    lastLayoutSnapshot*: string
    nativeHandle*: pointer
    desktopOwner*: pointer
    eventHandler*: PlasticForeignEventProc
  PlasticForeignCreateProc* = proc(element: PlasticForeignElementRuntime) 
  PlasticForeignNavigateProc* = proc(element: PlasticForeignElementRuntime; url: string) 
  PlasticForeignEvalJsProc* = proc(element: PlasticForeignElementRuntime; script: string; timeoutMs: int): JsonNode 
  PlasticForeignInjectProc* = proc(element: PlasticForeignElementRuntime; script: string) 
  PlasticForeignLayoutProc* = proc(element: PlasticForeignElementRuntime; payload: string) 
  PlasticForeignCloseProc* = proc(element: PlasticForeignElementRuntime) 

  PlasticForeignBackend* = ref object
    name*: string
    create*: PlasticForeignCreateProc
    navigate*: PlasticForeignNavigateProc
    evalJs*: PlasticForeignEvalJsProc
    injectDocumentStart*: PlasticForeignInjectProc
    applyLayoutSnapshot*: PlasticForeignLayoutProc
    close*: PlasticForeignCloseProc

  PlasticForeignRuntime* = ref object
    backend*: PlasticForeignBackend
    elements*: Table[string, PlasticForeignElementRuntime]
    onUrlChanged*: PlasticForeignUrlChangedProc
    onEvent*: PlasticForeignEventProc

type
  PlasticLlamaConfig* = object
    host*: string
    port*: int
    modelAlias*: string
    contextSize*: int
    gpuLayers*: int
    temperature*: float
    maxTokens*: int
    logResponseBody*: bool

  PlasticLlamaRuntime* = ref object
    config*: PlasticLlamaConfig
    executablePath*: string
    modelPath*: string
    modelRepo*: string
    modelFile*: string
    modelDir*: string
    downloadScriptPath*: string
    autoDownloadModel*: bool
    runtimeRoot*: string
    releaseRepo*: string
    releaseVersion*: string
    releaseBackend*: string
    autoDownloadRuntime*: bool
    autoUpdateRuntime*: bool
    updateIntervalHours*: int
    installedTag*: string
    installedAsset*: string
    managedRuntime*: bool
    process*: Process
    endpoint*: string

proc plasticLlamaConnectionTargets*(
  config: PlasticLlamaConfig
): seq[tuple[host: string, port: int]] =
  let hosts = plasticDefaultLlamaHostCandidates()
  let ports = plasticDefaultLlamaPortCandidates()

  result.add (host: config.host, port: config.port)
  for host in hosts:
    for port in ports:
      let candidate = (host: host, port: port)
      var seen = false
      for existing in result:
        if existing.host == candidate.host and existing.port == candidate.port:
          seen = true
          break
      if not seen:
        result.add candidate

type
  PlasticAgentProperty* = object
    name*: string
    value*: JsonNode

  PlasticAgentDomainItem* = object
    kind*: string
    name*: string
    description*: string
    whenKind*: string
    whenBody*: JsonNode
    intoKind*: string
    intoName*: string

  PlasticAgentToolPlan* = object
    name*: string
    parameters*: JsonNode
    returnType*: string
    systemPrompt*: string
    body*: JsonNode

  PlasticDesktopRuntime* = ref object of RootObj
    running*: bool

  PlasticWebViewRuntime* = ref object
    ## Perfil persistente compartilhado pelo frontend e por todos os foreign.
    userFolder*: string
    dataFolder*: string
    cacheFolder*: string
    cookiesPath*: string
    persistent*: bool
    persistentCookies*: bool
    acceptThirdPartyCookies*: bool
    safeGraphics*: bool
    configured*: bool
    storagePrepared*: bool
    initialized*: bool

  PlasticUiEvent* = object
    handlerId*: string
    eventName*: string
    identityPath*: string
    value*: JsonNode
    checked*: bool
    key*: string

  PlasticUiEventHandler* = proc(event: PlasticUiEvent) {.closure.}
  PlasticUiPropertyWriter* = proc(
    path, propertyName: string;
    value: JsonNode
  ) {.closure.}

  PlasticAgentAsyncStateWrite* = object
    path*: seq[string]
    value*: JsonNode

  PlasticAgentAsyncJob* = object
    hookName*: string
    entityName*: string
    change*: PlasticStateChange
    hookNode*: JsonNode
    domainNode*: JsonNode
    stateSnapshot*: JsonNode

  PlasticAgentAsyncResult* = object
    writes*: seq[PlasticAgentAsyncStateWrite]
    error*: string

  PlasticAgentWorkerState* = ref object
    agent*: PlasticAgent
    lock*: Lock
    jobs*: seq[PlasticAgentAsyncJob]
    results*: seq[PlasticAgentAsyncResult]
    running*: bool
    stopping*: bool
    active*: bool

  PlasticAssistantConfig* = object
    enabled*: bool
    assistantName*: string
    systemPrompt*: string
    language*: string
    voiceName*: string
    voiceRecognition*: string
    whisperBinary*: string
    whisperModel*: string
    ffmpegBinary*: string
    rlmAgent*: string
    autoSpeak*: bool
    autoSendVoice*: bool
    backgroundLearning*: bool
    maxRecentMessages*: int
    maxMemoryItems*: int
    responseMaxTokens*: int
    learningMaxTokens*: int

  PlasticAssistantChatJob* = object
    sessionId*: string
    userText*: string
    messages*: JsonNode

  PlasticAssistantLearningJob* = object
    sessionId*: string
    userText*: string
    assistantText*: string

  PlasticAssistantVoiceJob* = object
    audioBase64*: string
    mimeType*: string

  PlasticAssistantVoiceWorkerState* = ref object
    runtime*: PlasticAssistantRuntime
    queueLock*: Lock
    jobs*: seq[PlasticAssistantVoiceJob]
    running*: bool
    stopping*: bool
    active*: bool
    processed*: int
    failed*: int
    lastError*: string

  PlasticAssistantChatWorkerState* = ref object
    runtime*: PlasticAssistantRuntime
    queueLock*: Lock
    jobs*: seq[PlasticAssistantChatJob]
    running*: bool
    stopping*: bool
    active*: bool
    processed*: int
    failed*: int
    lastError*: string

  PlasticAssistantLearningWorkerState* = ref object
    runtime*: PlasticAssistantRuntime
    queueLock*: Lock
    jobs*: seq[PlasticAssistantLearningJob]
    running*: bool
    stopping*: bool
    active*: bool
    processed*: int
    skipped*: int
    failed*: int
    lastError*: string

  PlasticAssistantRuntime* = ref object
    config*: PlasticAssistantConfig
    rootPath*: string
    sessionsPath*: string
    sessionsIndexPath*: string
    thingsPath*: string
    endpoint*: string
    modelAlias*: string
    activeSession*: string
    sessions*: JsonNode
    things*: JsonNode
    dataLock*: Lock
    sequence*: int64
    revision*: int64
    publishedRevision*: int64
    status*: string
    voiceState*: string
    lastResponse*: string
    lastResponseId*: string
    lastTranscript*: string
    lastTranscriptId*: string
    lastError*: string
    voiceCaptureProcess*: Process
    voiceCapturePath*: string
    agentRunner*: proc(input: JsonNode): JsonNode {.closure.}
    started*: bool
    voiceWorkerState*: PlasticAssistantVoiceWorkerState
    voiceThread*: Thread[PlasticAssistantVoiceWorkerState]
    chatState*: PlasticAssistantChatWorkerState
    chatThread*: Thread[PlasticAssistantChatWorkerState]
    learningState*: PlasticAssistantLearningWorkerState
    learningThread*: Thread[PlasticAssistantLearningWorkerState]

  PlasticApplication* = ref object
    nameValue*: string
    productValue*: PlasticProductConfig
    memoryValue*: JsonNode
    installationValue*: PlasticInstallationRuntime
    planValue*: PlasticPlan
    planJsonValue*: string
    statesValue*: PlasticStateRuntime
    ormValue*: PlasticOrmRuntime
    okfValue*: PlasticOkfRuntime
    metisMemoryValue*: PlasticMetisMemory
    assistantValue*: PlasticAssistantRuntime
    safeStorageValue*: PlasticSafeStorageRuntime
    foreignValue*: PlasticForeignRuntime
    llamaValue*: PlasticLlamaRuntime
    rlmValue*: PlasticRlmRuntime
    agentsValue*: Table[string, PlasticAgent]
    componentsValue*: JsonNode
    renderTreeValue*: JsonNode
    desktopValue*: PlasticDesktopRuntime
    webViewValue*: PlasticWebViewRuntime
    uiHandlersValue*: Table[string, PlasticUiEventHandler]
    uiHandlerIdsValue*: Table[string, string]
    foreignEventHandlersValue*: Table[string, seq[PlasticForeignEventProc]]
    uiPropertyWriterValue*: PlasticUiPropertyWriter
    startupActionsValue*: seq[proc() {.closure.}]
    startupExecutedValue*: bool
    runningValue*: bool
    agentPollStartedValue*: bool

  PlasticAgent* = ref object
    constructorName*: string
    instanceName*: string
    properties*: Table[string, JsonNode]
    purpose*: string
    memoryName*: string
    okfPrincipalName*: string
    okfPath*: string
    okfValue*: PlasticOkfRuntime
    metisSession*: string
    domainPlan*: JsonNode
    rlmConditions*: string
    toolPlans*: JsonNode
    application*: PlasticApplication
    sessionVariables*: Table[string, JsonNode]
    hookDispatching*: bool
    asyncExecution*: bool
    asyncStateSnapshot*: JsonNode
    asyncStateWrites*: seq[PlasticAgentAsyncStateWrite]
    stateWriteCount*: int
    workerState*: PlasticAgentWorkerState
    workerThread*: Thread[PlasticAgentWorkerState]
    maxIterations*: int
    maxRecursionDepth*: int

  PlasticCapability* = proc(
    agent: PlasticAgent;
    arguments: JsonNode
  ): JsonNode {.closure.}

  PlasticRlmRuntime* = ref object
    capabilities*: Table[string, PlasticCapability]


const PlasticAssistantHandlerId* = "glaucoplastic-assistant"

proc plasticAssistantUtcNow(): string =
  getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc plasticAssistantEnvEnabled(name: string; fallback: bool): bool =
  let fallbackText = if fallback: "1" else: "0"
  getEnv(name, fallbackText).strip.toLowerAscii in
    ["1", "true", "yes", "on", "enabled"]

proc plasticDefaultAssistantConfig*(applicationName: string): PlasticAssistantConfig =
  PlasticAssistantConfig(
    enabled: plasticAssistantEnvEnabled("GLAUCOPLASTIC_ASSISTANT_ENABLED", false),
    assistantName: getEnv("GLAUCOPLASTIC_ASSISTANT_NAME", applicationName),
    systemPrompt: getEnv(
      "GLAUCOPLASTIC_ASSISTANT_SYSTEM_PROMPT",
      "Você é um assistente pessoal local. Responda com clareza, preserve " &
      "continuidade entre sessões e não invente fatos sobre o usuário."
    ),
    language: getEnv("GLAUCOPLASTIC_ASSISTANT_LANGUAGE", "pt-BR"),
    voiceName: getEnv("GLAUCOPLASTIC_ASSISTANT_VOICE", ""),
    voiceRecognition: getEnv("GLAUCOPLASTIC_VOICE_RECOGNITION", "system-microphone"),
    whisperBinary: getEnv("GLAUCOPLASTIC_WHISPER_BINARY", "whisper-cli"),
    whisperModel: getEnv("GLAUCOPLASTIC_WHISPER_MODEL", ""),
    ffmpegBinary: getEnv("GLAUCOPLASTIC_FFMPEG_BINARY", "ffmpeg"),
    rlmAgent: getEnv("GLAUCOPLASTIC_ASSISTANT_RLM_AGENT", ""),
    autoSpeak: plasticAssistantEnvEnabled(
      "GLAUCOPLASTIC_ASSISTANT_AUTO_SPEAK",
      true
    ),
    autoSendVoice: plasticAssistantEnvEnabled(
      "GLAUCOPLASTIC_ASSISTANT_AUTO_SEND_VOICE",
      true
    ),
    backgroundLearning: plasticAssistantEnvEnabled(
      "GLAUCOPLASTIC_ASSISTANT_BACKGROUND_LEARNING",
      true
    ),
    maxRecentMessages: plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_ASSISTANT_RECENT_MESSAGES", "18"),
      18
    ),
    maxMemoryItems: plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_ASSISTANT_MEMORY_ITEMS", "16"),
      16
    ),
    responseMaxTokens: plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_ASSISTANT_RESPONSE_TOKENS", "1024"),
      1024
    ),
    learningMaxTokens: plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_ASSISTANT_LEARNING_TOKENS", "512"),
      512
    )
  )

proc plasticAssistantReadJson(path: string; fallback: JsonNode): JsonNode =
  if path.len == 0 or not fileExists(path):
    return fallback.copy
  try:
    result = parseJson(readFile(path))
  except CatchableError:
    result = fallback.copy

proc plasticAssistantWriteJson(path: string; value: JsonNode) =
  if path.len == 0:
    return
  createDir(path.parentDir)
  let temporaryPath = path & ".tmp"
  writeFile(temporaryPath, value.pretty())
  if fileExists(path):
    removeFile(path)
  moveFile(temporaryPath, path)

proc plasticAssistantNormalizeWords(value: string): seq[string] =
  var normalized = newStringOfCap(value.len)
  for character in value.toLowerAscii:
    if character.isAlphaNumeric:
      normalized.add character
    else:
      normalized.add ' '
  for part in normalized.splitWhitespace:
    if part.len >= 3 and part notin result:
      result.add part

proc plasticAssistantNextIdUnlocked(
  runtime: PlasticAssistantRuntime;
  prefix: string
): string =
  inc runtime.sequence
  prefix & "-" & $epochTime().int64 & "-" & $runtime.sequence

proc plasticAssistantSessionIndexUnlocked(
  runtime: PlasticAssistantRuntime;
  sessionId: string
): int =
  if runtime.sessions.kind != JArray:
    return -1
  for index in 0 ..< runtime.sessions.len:
    let session = runtime.sessions[index]
    if session.kind == JObject and session.hasKey("id") and
        session["id"].kind == JString and session["id"].getStr == sessionId:
      return index
  -1

proc plasticAssistantSessionPath(
  runtime: PlasticAssistantRuntime;
  sessionId: string
): string =
  var safe = ""
  for character in sessionId:
    if character.isAlphaNumeric or character in {'-', '_'}:
      safe.add character
  if safe.len == 0:
    safe = "session"
  runtime.sessionsPath / (safe & ".json")

proc plasticAssistantSaveUnlocked(runtime: PlasticAssistantRuntime) =
  createDir(runtime.rootPath)
  createDir(runtime.sessionsPath)

  var index = newJArray()
  if runtime.sessions.kind == JArray:
    for session in runtime.sessions.items:
      if session.kind != JObject or not session.hasKey("id") or
          session["id"].kind != JString:
        continue
      let sessionId = session["id"].getStr
      plasticAssistantWriteJson(
        runtime.plasticAssistantSessionPath(sessionId),
        session
      )
      index.add %*{
        "id": sessionId,
        "title": if session.hasKey("title"): session["title"] else: %"Nova sessão",
        "createdAt": if session.hasKey("createdAt"): session["createdAt"] else: %plasticAssistantUtcNow(),
        "updatedAt": if session.hasKey("updatedAt"): session["updatedAt"] else: %plasticAssistantUtcNow(),
        "summary": if session.hasKey("summary"): session["summary"] else: %""
      }

  plasticAssistantWriteJson(runtime.sessionsIndexPath, index)
  plasticAssistantWriteJson(runtime.thingsPath, runtime.things)

proc plasticAssistantNewSessionUnlocked(
  runtime: PlasticAssistantRuntime;
  title = "Nova sessão"
): string =
  let sessionId = runtime.plasticAssistantNextIdUnlocked("session")
  let timestamp = plasticAssistantUtcNow()
  let session = %*{
    "id": sessionId,
    "title": title,
    "createdAt": timestamp,
    "updatedAt": timestamp,
    "summary": "",
    "messages": newJArray()
  }
  if runtime.sessions.kind != JArray:
    runtime.sessions = newJArray()
  var sessions = newJArray()
  sessions.add session
  for existing in runtime.sessions.items:
    sessions.add existing.copy
  runtime.sessions = sessions
  runtime.activeSession = sessionId
  inc runtime.revision
  result = sessionId

proc newPlasticAssistantRuntime*(
  applicationName, dataRoot, endpoint, modelAlias: string
): PlasticAssistantRuntime =
  let rootPath = dataRoot / ".glauco" / "assistant"
  result = PlasticAssistantRuntime(
    config: plasticDefaultAssistantConfig(applicationName),
    rootPath: rootPath,
    sessionsPath: rootPath / "sessions",
    sessionsIndexPath: rootPath / "sessions.json",
    thingsPath: rootPath / "things.json",
    endpoint: endpoint,
    modelAlias: modelAlias,
    sessions: newJArray(),
    things: newJArray(),
    status: "idle",
    voiceState: "idle",
    publishedRevision: -1
  )
  initLock(result.dataLock)

proc prepare*(runtime: PlasticAssistantRuntime) =
  if runtime.isNil:
    return
  acquire(runtime.dataLock)
  try:
    createDir(runtime.rootPath)
    createDir(runtime.sessionsPath)
    runtime.things = plasticAssistantReadJson(
      runtime.thingsPath,
      newJArray()
    )
    if runtime.things.kind != JArray:
      runtime.things = newJArray()

    let index = plasticAssistantReadJson(
      runtime.sessionsIndexPath,
      newJArray()
    )
    runtime.sessions = newJArray()
    if index.kind == JArray:
      for metadata in index.items:
        if metadata.kind != JObject or not metadata.hasKey("id") or
            metadata["id"].kind != JString:
          continue
        let sessionId = metadata["id"].getStr
        let session = plasticAssistantReadJson(
          runtime.plasticAssistantSessionPath(sessionId),
          newJNull()
        )
        if session.kind == JObject:
          runtime.sessions.add session

    if runtime.sessions.len == 0:
      discard runtime.plasticAssistantNewSessionUnlocked()
    else:
      runtime.activeSession = runtime.sessions[0]["id"].getStr

    runtime.status = "ready"
    runtime.lastError = ""
    inc runtime.revision
    runtime.plasticAssistantSaveUnlocked()
  finally:
    release(runtime.dataLock)

proc plasticAssistantMessagesForPromptUnlocked(
  runtime: PlasticAssistantRuntime;
  sessionId, userText: string
): JsonNode =
  result = newJArray()
  result.add %*{
    "role": "system",
    "content": runtime.config.systemPrompt & "\n\n" &
      "Idioma preferencial: " & runtime.config.language & "."
  }

  var memoryItems = newJArray()
  let queryWords = plasticAssistantNormalizeWords(userText)
  var candidates: seq[tuple[score: int, item: JsonNode]] = @[]
  if runtime.things.kind == JArray:
    for item in runtime.things.items:
      if item.kind != JObject:
        continue
      if item.hasKey("status") and item["status"].kind == JString and
          item["status"].getStr == "forgotten":
        continue
      let scope =
        if item.hasKey("scope") and item["scope"].kind == JString:
          item["scope"].getStr
        else:
          "global"
      if scope != "global" and scope != "session:" & sessionId:
        continue
      let content =
        (if item.hasKey("title") and item["title"].kind == JString:
          item["title"].getStr else: "") & " " &
        (if item.hasKey("content") and item["content"].kind == JString:
          item["content"].getStr else: "")
      let words = plasticAssistantNormalizeWords(content)
      var score =
        if item.hasKey("pinned") and item["pinned"].kind == JBool and
            item["pinned"].getBool: 100 else: 0
      for word in queryWords:
        if word in words:
          inc score, 4
        elif content.toLowerAscii.contains(word):
          inc score
      if scope == "global":
        inc score
      candidates.add (score: score, item: item.copy)

  candidates.sort(proc(a, b: tuple[score: int, item: JsonNode]): int =
    cmp(b.score, a.score)
  )
  for index, candidate in candidates:
    if index >= max(0, runtime.config.maxMemoryItems):
      break
    memoryItems.add candidate.item

  if memoryItems.len > 0:
    result.add %*{
      "role": "system",
      "content": "Coisas persistentes conhecidas sobre o usuário e seus contextos:\n" &
        memoryItems.pretty()
    }

  let sessionIndex = runtime.plasticAssistantSessionIndexUnlocked(sessionId)
  if sessionIndex >= 0:
    let session = runtime.sessions[sessionIndex]
    if session.hasKey("summary") and session["summary"].kind == JString and
        session["summary"].getStr.strip.len > 0:
      result.add %*{
        "role": "system",
        "content": "Resumo da sessão: " & session["summary"].getStr
      }
    if session.hasKey("messages") and session["messages"].kind == JArray:
      let messages = session["messages"]
      let firstIndex = max(0, messages.len - runtime.config.maxRecentMessages)
      for index in firstIndex ..< messages.len:
        let message = messages[index]
        if message.kind == JObject and message.hasKey("role") and
            message.hasKey("content"):
          result.add %*{
            "role": message["role"],
            "content": message["content"]
          }

proc plasticAssistantLlamaChat(
  runtime: PlasticAssistantRuntime;
  messages: JsonNode;
  maxTokens: int;
  jsonResponse = false
): string =
  let timeoutMs = max(
    1_000,
    plasticParseIntFallback(
      getEnv("GLAUCOPLASTIC_ASSISTANT_TIMEOUT_MS", "900000"),
      900000
    )
  )
  var payload = %*{
    "model": runtime.modelAlias,
    "messages": messages,
    "temperature": 0.2,
    "max_tokens": maxTokens,
    "stream": false
  }
  if jsonResponse:
    payload["response_format"] = %*{"type": "json_object"}

  var client = newHttpClient(timeout = timeoutMs)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let response = client.request(
      runtime.endpoint & "/chat/completions",
      httpMethod = HttpPost,
      body = $payload
    )
    if not response.status.startsWith("200"):
      raise newException(
        PlasticRuntimeError,
        "llama-server retornou " & response.status & ": " & response.body
      )
    let responseJson = parseJson(response.body)
    let choice = responseJson["choices"][0]
    let message = choice["message"]
    if message.hasKey("content") and message["content"].kind == JString and
        message["content"].getStr.strip.len > 0:
      return message["content"].getStr.strip
    if message.hasKey("reasoning_content") and
        message["reasoning_content"].kind == JString:
      let reasoning = message["reasoning_content"].getStr.strip
      let objectStart = reasoning.find('{')
      let objectEnd = reasoning.rfind('}')
      if objectStart >= 0 and objectEnd >= objectStart:
        return reasoning[objectStart .. objectEnd]
    raise newException(PlasticRuntimeError, "O modelo devolveu resposta vazia.")
  finally:
    client.close()

proc plasticAssistantAppendMessageUnlocked(
  runtime: PlasticAssistantRuntime;
  sessionId, role, content: string
): string =
  let sessionIndex = runtime.plasticAssistantSessionIndexUnlocked(sessionId)
  if sessionIndex < 0:
    return ""
  var session = runtime.sessions[sessionIndex]
  if not session.hasKey("messages") or session["messages"].kind != JArray:
    session["messages"] = newJArray()
  let messageId = runtime.plasticAssistantNextIdUnlocked("message")
  let timestamp = plasticAssistantUtcNow()
  session["messages"].add %*{
    "id": messageId,
    "role": role,
    "content": content,
    "createdAt": timestamp
  }
  session["updatedAt"] = %timestamp
  if role == "user" and
      (not session.hasKey("title") or
       session["title"].kind != JString or
       session["title"].getStr in ["", "Nova sessão"]):
    let cleaned = content.strip.replace("\n", " ")
    session["title"] = %(
      if cleaned.len > 48: cleaned[0 .. 47] & "…" else: cleaned
    )
  # `session` referencia diretamente o JsonNode armazenado no array.
  # As mutações acima já foram aplicadas em `runtime.sessions`.
  inc runtime.revision
  result = messageId

proc plasticAssistantUpsertThingUnlocked(
  runtime: PlasticAssistantRuntime;
  sourceSession: string;
  candidate: JsonNode
) =
  if candidate.kind != JObject:
    return
  let title =
    if candidate.hasKey("title") and candidate["title"].kind == JString:
      candidate["title"].getStr.strip
    else:
      ""
  let content =
    if candidate.hasKey("content") and candidate["content"].kind == JString:
      candidate["content"].getStr.strip
    else:
      ""
  if title.len == 0 or content.len == 0:
    return

  let operation =
    if candidate.hasKey("operation") and candidate["operation"].kind == JString:
      candidate["operation"].getStr.toLowerAscii
    else:
      "upsert"
  let scope =
    if candidate.hasKey("scope") and candidate["scope"].kind == JString:
      candidate["scope"].getStr
    else:
      "global"
  let normalizedTitle = title.toLowerAscii

  var found = -1
  if runtime.things.kind != JArray:
    runtime.things = newJArray()
  for index in 0 ..< runtime.things.len:
    let item = runtime.things[index]
    if item.kind == JObject and item.hasKey("title") and
        item["title"].kind == JString and
        item["title"].getStr.toLowerAscii == normalizedTitle and
        item.hasKey("scope") and item["scope"].kind == JString and
        item["scope"].getStr == scope:
      found = index
      break

  if operation in ["delete", "forget", "remove"]:
    if found >= 0:
      runtime.things[found]["status"] = %"forgotten"
      runtime.things[found]["updatedAt"] = %plasticAssistantUtcNow()
    return

  let timestamp = plasticAssistantUtcNow()
  let thingId =
    if found >= 0 and runtime.things[found].hasKey("id"):
      runtime.things[found]["id"].copy
    else:
      %runtime.plasticAssistantNextIdUnlocked("thing")
  let thingKind =
    if candidate.hasKey("kind"):
      candidate["kind"].copy
    else:
      %"fact"
  let confidence =
    if candidate.hasKey("confidence"):
      candidate["confidence"].copy
    else:
      %0.75
  let pinned =
    if found >= 0 and runtime.things[found].hasKey("pinned"):
      runtime.things[found]["pinned"].copy
    else:
      %false
  let createdAt =
    if found >= 0 and runtime.things[found].hasKey("createdAt"):
      runtime.things[found]["createdAt"].copy
    else:
      %timestamp
  var thing = %*{
    "id": thingId,
    "kind": thingKind,
    "title": title,
    "content": content,
    "scope": scope,
    "confidence": confidence,
    "status": "active",
    "pinned": pinned,
    "sourceSessionId": sourceSession,
    "createdAt": createdAt,
    "updatedAt": timestamp
  }
  if found >= 0:
    # A expressão `runtime.things[found]` não é um lvalue atribuível no Nim.
    # Reconstruímos o array substituindo somente o item encontrado.
    var things = newJArray()
    var existingIndex = 0
    for existing in runtime.things.items:
      if existingIndex == found:
        things.add thing
      else:
        things.add existing.copy
      inc existingIndex
    runtime.things = things
  else:
    var things = newJArray()
    things.add thing
    for existing in runtime.things.items:
      things.add existing.copy
    runtime.things = things

proc plasticAssistantResultText(value: JsonNode): string {.gcsafe.}
proc runPlasticAssistantChatWorker(
  state: PlasticAssistantChatWorkerState
) {.thread.} =
  if state.isNil:
    return
  state.running = true
  while not state.stopping:
    var hasJob = false
    var job: PlasticAssistantChatJob
    acquire(state.queueLock)
    if state.jobs.len > 0:
      job = state.jobs[0]
      state.jobs.delete(0)
      state.active = true
      hasJob = true
    release(state.queueLock)

    if not hasJob:
      sleep(25)
      continue

    let runtime = state.runtime
    acquire(runtime.dataLock)
    runtime.status = "thinking"
    runtime.lastError = ""
    inc runtime.revision
    release(runtime.dataLock)

    try:
      var answer: string
      if not runtime.agentRunner.isNil:
        var agentResult = newJNull()
        {.cast(gcsafe).}:
          agentResult = runtime.agentRunner(%*{
            "message": job.userText,
            "prompt": job.userText,
            "session": job.sessionId
          })
        answer = plasticAssistantResultText(agentResult)
      else:
        answer = plasticAssistantLlamaChat(
          runtime,
          job.messages,
          max(64, runtime.config.responseMaxTokens)
        )
      acquire(runtime.dataLock)
      try:
        let responseId = runtime.plasticAssistantAppendMessageUnlocked(
          job.sessionId,
          "assistant",
          answer
        )
        runtime.lastResponse = answer
        runtime.lastResponseId = responseId
        runtime.status = "ready"
        runtime.plasticAssistantSaveUnlocked()
      finally:
        release(runtime.dataLock)

      if runtime.config.backgroundLearning:
        acquire(runtime.learningState.queueLock)
        runtime.learningState.jobs.add PlasticAssistantLearningJob(
          sessionId: job.sessionId,
          userText: job.userText,
          assistantText: answer
        )
        release(runtime.learningState.queueLock)
      inc state.processed
    except CatchableError as error:
      acquire(runtime.dataLock)
      runtime.status = "error"
      runtime.lastError = error.msg
      inc runtime.revision
      release(runtime.dataLock)
      state.lastError = error.msg
      inc state.failed

    acquire(state.queueLock)
    state.active = false
    release(state.queueLock)
  state.running = false

proc runPlasticAssistantLearningWorker(
  state: PlasticAssistantLearningWorkerState
) {.thread.} =
  if state.isNil:
    return
  state.running = true
  while not state.stopping:
    var hasJob = false
    var job: PlasticAssistantLearningJob
    acquire(state.queueLock)
    if state.jobs.len > 0:
      job = state.jobs[0]
      state.jobs.delete(0)
      state.active = true
      hasJob = true
    release(state.queueLock)

    if not hasJob:
      sleep(50)
      continue

    let runtime = state.runtime
    let prompt = """
Extraia somente informações duráveis que serão úteis em sessões futuras.
Não memorize cumprimentos, texto temporário, inferências frágeis, segredos,
credenciais ou dados sensíveis sem pedido explícito. Responda em JSON válido:
{
  "sessionSummary": "resumo curto do que ficou definido",
  "things": [
    {
      "kind": "preference|project|person|decision|task|vocabulary|instruction|fact",
      "title": "rótulo curto e estável",
      "content": "informação declarativa",
      "scope": "global ou session:ID",
      "confidence": 0.0,
      "operation": "upsert|forget"
    }
  ]
}
"""
    let messages = %*[
      %*{"role": "system", "content": prompt},
      %*{
        "role": "user",
        "content": "Sessão: " & job.sessionId &
          "\nUsuário: " & job.userText &
          "\nAssistente: " & job.assistantText
      }
    ]

    try:
      let content = plasticAssistantLlamaChat(
        runtime,
        messages,
        max(128, runtime.config.learningMaxTokens),
        true
      )
      let objectStart = content.find('{')
      let objectEnd = content.rfind('}')
      let payload = parseJson(
        if objectStart >= 0 and objectEnd >= objectStart:
          content[objectStart .. objectEnd]
        else:
          content
      )
      acquire(runtime.dataLock)
      try:
        let sessionIndex = runtime.plasticAssistantSessionIndexUnlocked(
          job.sessionId
        )
        if sessionIndex >= 0 and payload.hasKey("sessionSummary") and
            payload["sessionSummary"].kind == JString:
          runtime.sessions[sessionIndex]["summary"] =
            payload["sessionSummary"].copy
        if payload.hasKey("things") and payload["things"].kind == JArray:
          for candidate in payload["things"].items:
            runtime.plasticAssistantUpsertThingUnlocked(
              job.sessionId,
              candidate
            )
        runtime.plasticAssistantSaveUnlocked()
        inc runtime.revision
      finally:
        release(runtime.dataLock)
      inc state.processed
    except CatchableError as error:
      state.lastError = error.msg
      inc state.failed

    acquire(state.queueLock)
    state.active = false
    release(state.queueLock)
  state.running = false

proc runPlasticAssistantVoiceWorker(
  state: PlasticAssistantVoiceWorkerState
) {.thread.}

proc start*(runtime: PlasticAssistantRuntime) =
  if runtime.isNil or runtime.started:
    return
  runtime.prepare()
  runtime.voiceWorkerState = PlasticAssistantVoiceWorkerState(runtime: runtime)
  runtime.chatState = PlasticAssistantChatWorkerState(runtime: runtime)
  runtime.learningState = PlasticAssistantLearningWorkerState(runtime: runtime)
  initLock(runtime.voiceWorkerState.queueLock)
  initLock(runtime.chatState.queueLock)
  initLock(runtime.learningState.queueLock)
  runtime.started = true
  createThread(
    runtime.voiceThread,
    runPlasticAssistantVoiceWorker,
    runtime.voiceWorkerState
  )
  createThread(
    runtime.chatThread,
    runPlasticAssistantChatWorker,
    runtime.chatState
  )
  createThread(
    runtime.learningThread,
    runPlasticAssistantLearningWorker,
    runtime.learningState
  )

proc stop*(runtime: PlasticAssistantRuntime) =
  if runtime.isNil or not runtime.started:
    return
  runtime.voiceWorkerState.stopping = true
  runtime.chatState.stopping = true
  runtime.learningState.stopping = true
  joinThread(runtime.voiceThread)
  joinThread(runtime.chatThread)
  joinThread(runtime.learningThread)
  runtime.started = false

proc enqueueMessage*(runtime: PlasticAssistantRuntime; text: string) =
  if runtime.isNil:
    return
  let cleaned = text.strip
  if cleaned.len == 0:
    return
  if not runtime.started:
    runtime.start()

  var job: PlasticAssistantChatJob
  acquire(runtime.dataLock)
  try:
    if runtime.activeSession.len == 0 or
        runtime.plasticAssistantSessionIndexUnlocked(runtime.activeSession) < 0:
      discard runtime.plasticAssistantNewSessionUnlocked()
    let sessionId = runtime.activeSession
    discard runtime.plasticAssistantAppendMessageUnlocked(
      sessionId,
      "user",
      cleaned
    )
    job = PlasticAssistantChatJob(
      sessionId: sessionId,
      userText: cleaned,
      messages: runtime.plasticAssistantMessagesForPromptUnlocked(
        sessionId,
        cleaned
      )
    )
    runtime.status = "queued"
    runtime.lastError = ""
    runtime.plasticAssistantSaveUnlocked()
  finally:
    release(runtime.dataLock)

  acquire(runtime.chatState.queueLock)
  runtime.chatState.jobs.add job
  release(runtime.chatState.queueLock)

proc newSession*(runtime: PlasticAssistantRuntime): string =
  if runtime.isNil:
    return ""
  acquire(runtime.dataLock)
  try:
    result = runtime.plasticAssistantNewSessionUnlocked()
    runtime.plasticAssistantSaveUnlocked()
  finally:
    release(runtime.dataLock)

proc selectSession*(runtime: PlasticAssistantRuntime; sessionId: string) =
  if runtime.isNil:
    return
  acquire(runtime.dataLock)
  try:
    if runtime.plasticAssistantSessionIndexUnlocked(sessionId) >= 0:
      runtime.activeSession = sessionId
      inc runtime.revision
  finally:
    release(runtime.dataLock)

proc plasticAssistantToggleThing(
  runtime: PlasticAssistantRuntime;
  thingId: string;
  forget = false
) =
  if runtime.isNil:
    return
  acquire(runtime.dataLock)
  try:
    if runtime.things.kind == JArray:
      for index in 0 ..< runtime.things.len:
        let thing = runtime.things[index]
        if thing.kind == JObject and thing.hasKey("id") and
            thing["id"].kind == JString and thing["id"].getStr == thingId:
          if forget:
            runtime.things[index]["status"] = %"forgotten"
          else:
            let pinned = runtime.things[index].hasKey("pinned") and
              runtime.things[index]["pinned"].kind == JBool and
              runtime.things[index]["pinned"].getBool
            runtime.things[index]["pinned"] = %(not pinned)
          runtime.things[index]["updatedAt"] = %plasticAssistantUtcNow()
          inc runtime.revision
          runtime.plasticAssistantSaveUnlocked()
          break
  finally:
    release(runtime.dataLock)

proc plasticAssistantVoiceInputDevice*(): string =
  let configured = getEnv("GLAUCOPLASTIC_VOICE_INPUT_DEVICE", "").strip
  if configured.len > 0:
    return configured
  when defined(windows):
    "CABLE Output"
  elif defined(macosx):
    ":0"
  else:
    "glauco_phone_mic"

proc plasticAssistantVoiceCaptureArgs(
  runtime: PlasticAssistantRuntime;
  outputPath: string
): seq[string] =
  let device = plasticAssistantVoiceInputDevice()
  result = @["-hide_banner", "-loglevel", "error", "-y"]
  when defined(windows):
    result.add @["-f", "dshow", "-i", "audio=" & device]
  elif defined(macosx):
    result.add @["-f", "avfoundation", "-i", device]
  else:
    result.add @["-f", "pulse", "-i", device]
  result.add @[
    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputPath
  ]

proc plasticAssistantStartNativeCapture*(runtime: PlasticAssistantRuntime) =
  if runtime.isNil:
    return
  acquire(runtime.dataLock)
  let alreadyRecording = not runtime.voiceCaptureProcess.isNil
  release(runtime.dataLock)
  if alreadyRecording:
    return

  let voiceRoot = runtime.rootPath / "voice"
  createDir(voiceRoot)
  let outputPath = voiceRoot / (
    "native-input-" & $epochTime().int64 & "-" & $getCurrentProcessId() & ".wav"
  )
  try:
    let capture = startProcess(
      runtime.config.ffmpegBinary,
      args = runtime.plasticAssistantVoiceCaptureArgs(outputPath),
      options = {poUsePath, poStdErrToStdOut}
    )
    acquire(runtime.dataLock)
    runtime.voiceCaptureProcess = capture
    runtime.voiceCapturePath = outputPath
    runtime.voiceState = "recording"
    runtime.lastError = ""
    inc runtime.revision
    release(runtime.dataLock)
  except CatchableError as error:
    acquire(runtime.dataLock)
    runtime.voiceState = "error"
    runtime.lastError = "Falha ao abrir o microfone nativo: " & error.msg
    inc runtime.revision
    release(runtime.dataLock)

proc plasticAssistantStopNativeCapture*(runtime: PlasticAssistantRuntime) =
  if runtime.isNil:
    return
  var capture: Process
  var outputPath = ""
  acquire(runtime.dataLock)
  capture = runtime.voiceCaptureProcess
  outputPath = runtime.voiceCapturePath
  runtime.voiceCaptureProcess = nil
  runtime.voiceCapturePath = ""
  runtime.voiceState = "stopping"
  inc runtime.revision
  release(runtime.dataLock)

  if capture.isNil:
    acquire(runtime.dataLock)
    runtime.voiceState = "idle"
    inc runtime.revision
    release(runtime.dataLock)
    return

  try:
    let input = capture.inputStream
    if not input.isNil:
      input.write("q\n")
      input.flush()
    let exitCode = waitForExit(capture, 5000)
    if exitCode == -1:
      terminate(capture)
      discard waitForExit(capture, 2000)
  except CatchableError:
    try:
      terminate(capture)
      discard waitForExit(capture, 2000)
    except CatchableError:
      discard
  finally:
    try: close(capture)
    except CatchableError: discard

  if not fileExists(outputPath) or getFileSize(outputPath) <= 44:
    acquire(runtime.dataLock)
    runtime.voiceState = "error"
    runtime.lastError = "A captura nativa não produziu áudio. Entrada: " &
      plasticAssistantVoiceInputDevice()
    inc runtime.revision
    release(runtime.dataLock)
    return

  if not runtime.started:
    runtime.start()
  let encodedAudio = encode(readFile(outputPath))
  try: removeFile(outputPath)
  except CatchableError: discard
  acquire(runtime.voiceWorkerState.queueLock)
  runtime.voiceWorkerState.jobs.add PlasticAssistantVoiceJob(
    audioBase64: encodedAudio,
    mimeType: "audio/wav"
  )
  release(runtime.voiceWorkerState.queueLock)
  acquire(runtime.dataLock)
  runtime.voiceState = "queued"
  runtime.lastError = ""
  inc runtime.revision
  release(runtime.dataLock)

proc handleUiEvent*(
  runtime: PlasticAssistantRuntime;
  action: string;
  value: JsonNode;
  checked: bool
) =
  if runtime.isNil:
    return
  case action
  of "assistant:send":
    if value.kind == JString:
      runtime.enqueueMessage(value.getStr)
  of "assistant:new-session":
    discard runtime.newSession()
  of "assistant:select-session":
    if value.kind == JString:
      runtime.selectSession(value.getStr)
  of "assistant:auto-speak":
    acquire(runtime.dataLock)
    try:
      runtime.config.autoSpeak =
        if value.kind == JBool: value.getBool else: checked
      inc runtime.revision
    finally:
      release(runtime.dataLock)
  of "assistant:pin-thing":
    if value.kind == JString:
      runtime.plasticAssistantToggleThing(value.getStr)
  of "assistant:forget-thing":
    if value.kind == JString:
      runtime.plasticAssistantToggleThing(value.getStr, true)
  of "assistant:voice-start":
    runtime.plasticAssistantStartNativeCapture()
  of "assistant:voice-stop":
    runtime.plasticAssistantStopNativeCapture()
  of "assistant:voice-audio":
    if value.kind == JObject and value.hasKey("data") and
        value["data"].kind == JString:
      if not runtime.started:
        runtime.start()
      acquire(runtime.voiceWorkerState.queueLock)
      runtime.voiceWorkerState.jobs.add PlasticAssistantVoiceJob(
        audioBase64: value["data"].getStr,
        mimeType:
          if value.hasKey("mimeType") and value["mimeType"].kind == JString:
            value["mimeType"].getStr
          else:
            "audio/webm"
      )
      release(runtime.voiceWorkerState.queueLock)
      acquire(runtime.dataLock)
      runtime.voiceState = "queued"
      inc runtime.revision
      release(runtime.dataLock)
  else:
    discard

proc plasticAssistantSnapshot*(runtime: PlasticAssistantRuntime): JsonNode =
  if runtime.isNil:
    return newJNull()
  acquire(runtime.dataLock)
  try:
    var sessions = newJArray()
    var active = newJNull()
    if runtime.sessions.kind == JArray:
      for session in runtime.sessions.items:
        if session.kind != JObject:
          continue
        sessions.add %*{
          "id": if session.hasKey("id"): session["id"] else: %"",
          "title": if session.hasKey("title"): session["title"] else: %"Nova sessão",
          "updatedAt": if session.hasKey("updatedAt"): session["updatedAt"] else: %"",
          "summary": if session.hasKey("summary"): session["summary"] else: %""
        }
        if session.hasKey("id") and session["id"].kind == JString and
            session["id"].getStr == runtime.activeSession:
          active = session.copy

    var visibleThings = newJArray()
    if runtime.things.kind == JArray:
      for thing in runtime.things.items:
        if thing.kind == JObject and
            (not thing.hasKey("status") or thing["status"].kind != JString or
             thing["status"].getStr != "forgotten"):
          visibleThings.add thing.copy

    result = %*{
      "revision": runtime.revision,
      "status": runtime.status,
      "voiceState": runtime.voiceState,
      "lastError": runtime.lastError,
      "lastResponse": runtime.lastResponse,
      "lastResponseId": runtime.lastResponseId,
      "lastTranscript": runtime.lastTranscript,
      "lastTranscriptId": runtime.lastTranscriptId,
      "activeSessionId": runtime.activeSession,
      "sessions": sessions,
      "activeSession": active,
      "things": visibleThings,
      "config": {
        "assistantName": runtime.config.assistantName,
        "language": runtime.config.language,
        "voiceName": runtime.config.voiceName,
        "voiceRecognition": runtime.config.voiceRecognition,
        "autoSpeak": runtime.config.autoSpeak,
        "autoSendVoice": runtime.config.autoSendVoice,
        "backgroundLearning": runtime.config.backgroundLearning
      }
    }
  finally:
    release(runtime.dataLock)

proc plasticAssistantCss*(): string =
  result = r"""
    .plastic-assistant { position: fixed; inset: 0; width: 100%; height: 100dvh; min-height: 0; overflow: hidden; display: grid; grid-template-columns: 300px minmax(0, 1fr); background: #f4f5f7; color: #1e2329; }
    .plastic-assistant button, .plastic-assistant textarea { font: inherit; }
    .assistant-sidebar { height: 100%; min-height: 0; border-right: 1px solid #dfe3e8; background: #ffffff; padding: 18px 14px; display: flex; flex-direction: column; gap: 18px; overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain; }
    .assistant-brand { display: flex; align-items: center; gap: 10px; padding: 4px 6px; }
    .assistant-brand-mark { width: 36px; height: 36px; display: grid; place-items: center; border-radius: 11px; background: #1e2329; color: white; font-weight: 700; }
    .assistant-brand-copy strong { display: block; }
    .assistant-brand-copy small { color: #737b85; }
    .assistant-new-session { width: 100%; border: 0; border-radius: 10px; padding: 11px 13px; background: #1e2329; color: white; cursor: pointer; text-align: left; }
    .assistant-sidebar-title { margin: 0 6px 8px; color: #737b85; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; }
    .assistant-session-list, .assistant-thing-list { display: flex; flex-direction: column; gap: 5px; }
    .assistant-session { width: 100%; border: 0; border-radius: 9px; padding: 10px; background: transparent; color: inherit; cursor: pointer; text-align: left; }
    .assistant-session:hover, .assistant-session.active { background: #eef0f3; }
    .assistant-session strong { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .assistant-session small { color: #8a919b; }
    .assistant-things { margin-top: auto; }
    .assistant-thing { border: 1px solid #e1e4e8; border-radius: 10px; background: #fafbfc; padding: 9px; }
    .assistant-thing-head { display: flex; gap: 6px; align-items: center; }
    .assistant-thing-kind { font-size: 10px; text-transform: uppercase; color: #737b85; }
    .assistant-thing strong { flex: 1; font-size: 13px; }
    .assistant-thing p { margin: 6px 0 0; color: #5e6670; font-size: 12px; line-height: 1.35; }
    .assistant-thing-actions { display: flex; gap: 4px; margin-top: 7px; }
    .assistant-mini-button { border: 1px solid #dfe3e8; border-radius: 7px; background: white; padding: 4px 7px; cursor: pointer; font-size: 11px; }
    .assistant-main { min-width: 0; min-height: 0; height: 100%; overflow: hidden; display: grid; grid-template-rows: auto minmax(0, 1fr) auto auto; }
    .assistant-header { position: relative; z-index: 3; height: 66px; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 0 24px; border-bottom: 1px solid #dfe3e8; background: rgba(255,255,255,.96); backdrop-filter: blur(12px); }
    .assistant-header h1 { margin: 0; font-size: 17px; }
    .assistant-status { display: flex; align-items: center; gap: 8px; color: #737b85; font-size: 12px; }
    .assistant-status-dot { width: 8px; height: 8px; border-radius: 50%; background: #2fa36b; }
    .assistant-status[data-status="thinking"] .assistant-status-dot, .assistant-status[data-status="queued"] .assistant-status-dot { background: #d58b20; animation: assistant-pulse 1s infinite alternate; }
    .assistant-status[data-status="error"] .assistant-status-dot { background: #c44747; }
    @keyframes assistant-pulse { to { opacity: .35; } }
    .assistant-voice-controls { display: flex; gap: 7px; align-items: center; }
    .assistant-control { border: 1px solid #dfe3e8; border-radius: 9px; background: white; padding: 7px 10px; cursor: pointer; }
    .assistant-messages { min-height: 0; height: 100%; overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain; scrollbar-gutter: stable; scroll-behavior: smooth; padding: 26px max(22px, calc((100% - 860px) / 2)) 30px; display: flex; flex-direction: column; gap: 16px; }
    .assistant-empty { margin: auto; max-width: 520px; text-align: center; color: #737b85; }
    .assistant-message { max-width: 82%; border-radius: 16px; padding: 12px 15px; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
    .assistant-message.user { align-self: flex-end; background: #1e2329; color: white; border-bottom-right-radius: 5px; }
    .assistant-message.assistant { align-self: flex-start; background: white; border: 1px solid #e0e4e8; border-bottom-left-radius: 5px; }
    .assistant-message.assistant > div { white-space: normal; }
    .assistant-message.assistant p { margin: 0 0 .75em; }
    .assistant-message.assistant p:last-child { margin-bottom: 0; }
    .assistant-message.assistant h1, .assistant-message.assistant h2, .assistant-message.assistant h3 { margin: .25em 0 .6em; line-height: 1.25; }
    .assistant-message.assistant h1 { font-size: 1.35em; }
    .assistant-message.assistant h2 { font-size: 1.18em; }
    .assistant-message.assistant h3 { font-size: 1.05em; }
    .assistant-message.assistant ul, .assistant-message.assistant ol { margin: .45em 0 .8em; padding-left: 1.4em; }
    .assistant-message.assistant blockquote { margin: .6em 0; padding: .2em 0 .2em .9em; border-left: 3px solid #cfd5dc; color: #5e6670; }
    .assistant-message.assistant code { border-radius: 5px; background: #eef0f3; padding: .12em .34em; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .92em; }
    .assistant-message.assistant pre { margin: .75em 0; overflow: auto; border: 1px solid #dfe3e8; border-radius: 10px; background: #f4f5f7; padding: 12px; }
    .assistant-message.assistant pre code { background: transparent; padding: 0; }
    .assistant-message.assistant a { color: #245c9e; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .assistant-message.assistant .markdown-table-wrap { width: 100%; margin: .8em 0; overflow-x: auto; border: 1px solid #dfe3e8; border-radius: 10px; background: #fff; }
    .assistant-message.assistant table { width: 100%; min-width: 520px; border-collapse: collapse; border-spacing: 0; font-size: .94em; }
    .assistant-message.assistant th, .assistant-message.assistant td { padding: 9px 11px; border-right: 1px solid #e3e7eb; border-bottom: 1px solid #e3e7eb; text-align: left; vertical-align: top; }
    .assistant-message.assistant th:last-child, .assistant-message.assistant td:last-child { border-right: 0; }
    .assistant-message.assistant tbody tr:last-child td { border-bottom: 0; }
    .assistant-message.assistant thead th { background: #f3f5f7; font-weight: 650; color: #252a30; }
    .assistant-message.assistant tbody tr:nth-child(even) { background: #fafbfc; }
    .assistant-message-time { display: block; margin-top: 6px; opacity: .55; font-size: 10px; }
    .assistant-error { position: relative; z-index: 3; margin: 0 max(22px, calc((100% - 860px) / 2)); border: 1px solid #efc6c6; border-radius: 10px; background: #fff3f3; color: #9e3434; padding: 10px 12px; }
    .assistant-composer-shell { position: relative; z-index: 4; padding: 16px max(22px, calc((100% - 860px) / 2)) max(22px, env(safe-area-inset-bottom)); border-top: 1px solid #dfe3e8; background: rgba(255,255,255,.97); backdrop-filter: blur(14px); box-shadow: 0 -10px 30px rgba(31,35,41,.055); }
    .assistant-composer { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 9px; align-items: end; border: 1px solid #cfd5dc; border-radius: 16px; padding: 8px; box-shadow: 0 8px 26px rgba(31,35,41,.06); }
    .assistant-composer textarea { width: 100%; min-height: 42px; max-height: 150px; overflow-y: auto; resize: none; border: 0; outline: 0; background: transparent; color: inherit; padding: 10px 4px; }
    .assistant-round-button { width: 42px; height: 42px; border: 0; border-radius: 12px; display: grid; place-items: center; cursor: pointer; background: #eef0f3; color: #1e2329; }
    .assistant-round-button.primary { background: #1e2329; color: white; }
    .assistant-round-button.listening { background: #c44747; color: white; animation: assistant-pulse .7s infinite alternate; }
    .assistant-composer-note { margin: 7px 3px 0; color: #8a919b; font-size: 11px; }
    @media (max-width: 780px) { .plastic-assistant { grid-template-columns: 1fr; } .assistant-sidebar { display: none; } .assistant-message { max-width: 92%; } }
  """

proc plasticAssistantBodyHtml*(runtime: PlasticAssistantRuntime): string =
  let name =
    if runtime.isNil or runtime.config.assistantName.strip.len == 0:
      "Assistente"
    else:
      runtime.config.assistantName
  result = """
    <div class="plastic-assistant" id="plastic-assistant-root">
      <aside class="assistant-sidebar">
        <div class="assistant-brand">
          <div class="assistant-brand-mark">G</div>
          <div class="assistant-brand-copy"><strong>""" & name & """</strong><small>GlaucoPlastic</small></div>
        </div>
        <button class="assistant-new-session" id="assistant-new-session">+ Nova sessão</button>
        <section><h2 class="assistant-sidebar-title">Sessões</h2><div class="assistant-session-list" id="assistant-session-list"></div></section>
        <section class="assistant-things"><h2 class="assistant-sidebar-title">Coisas aprendidas</h2><div class="assistant-thing-list" id="assistant-thing-list"></div></section>
      </aside>
      <main class="assistant-main">
        <header class="assistant-header">
          <div><h1 id="assistant-current-title">Nova sessão</h1><div class="assistant-status" id="assistant-status" data-status="idle"><span class="assistant-status-dot"></span><span id="assistant-status-text">Pronto</span></div></div>
          <div class="assistant-voice-controls">
            <label class="assistant-control"><input type="checkbox" id="assistant-auto-speak"> falar respostas</label>
            <button class="assistant-control" id="assistant-repeat-voice" title="Repetir resposta">Repetir</button>
            <button class="assistant-control" id="assistant-stop-voice" title="Interromper voz">Parar voz</button>
          </div>
        </header>
        <div class="assistant-messages" id="assistant-messages"><div class="assistant-empty">Crie uma conversa por texto ou voz. Preferências, projetos, decisões e pendências podem continuar disponíveis em outras sessões.</div></div>
        <div id="assistant-error" class="assistant-error" hidden></div>
        <footer class="assistant-composer-shell">
          <div class="assistant-composer">
            <button class="assistant-round-button" id="assistant-microphone" title="Falar">◉</button>
            <textarea id="assistant-composer" rows="1" placeholder="Escreva ou fale..."></textarea>
            <button class="assistant-round-button primary" id="assistant-send" title="Enviar">➜</button>
          </div>
          <div class="assistant-composer-note" id="assistant-voice-note">Enter envia; Shift+Enter cria uma linha.</div>
        </footer>
      </main>
    </div>
  """

proc plasticAssistantScript*(runtime: PlasticAssistantRuntime = nil): string =
  let initialVoiceBackend =
    if runtime.isNil: ""
    else: runtime.config.voiceRecognition
  result = "<script>window.__glaucoplasticAssistantVoiceBackend = " &
    $(%initialVoiceBackend) & ";</script>" & r"""
    <script>
      (() => {
        const state = {
          snapshot: null,
          spokenMessageId: '',
          lastAssistantText: '',
          recognition: null,
          mediaRecorder: null,
          mediaStream: null,
          audioChunks: [],
          transcriptId: '',
          listening: false
        };

        const byId = id => document.getElementById(id);
        const queue = () => window.__glaucoplasticEvents ||
          (window.__glaucoplasticEvents = []);
        const emit = (identity, value = null, checked = false) => {
          queue().push({
            handlerId: 'glaucoplastic-assistant',
            event: 'assistant',
            identity,
            bindState: '',
            value,
            checked,
            key: ''
          });
        };
        const text = value => value == null ? '' : String(value);
        const escapeHtml = value => text(value)
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
        function markdownInline(value) {
          let html = escapeHtml(value);
          html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
          html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
          html = html.replace(/__([^_]+)__/g, '<strong>$1</strong>');
          html = html.replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
          html = html.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
            '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
          return html;
        }
        function markdownTableCells(line) {
          let value = text(line).trim();
          if (value.startsWith('|')) value = value.slice(1);
          if (value.endsWith('|')) value = value.slice(0, -1);

          const cells = [];
          let cell = '';
          let escaped = false;
          let inlineCode = false;

          for (const character of value) {
            if (escaped) {
              cell += character;
              escaped = false;
              continue;
            }
            if (character === '\\') {
              cell += character;
              escaped = true;
              continue;
            }
            if (character === '`') {
              inlineCode = !inlineCode;
              cell += character;
              continue;
            }
            if (character === '|' && !inlineCode) {
              cells.push(cell.trim());
              cell = '';
              continue;
            }
            cell += character;
          }
          cells.push(cell.trim());
          return cells;
        }
        function markdownTableDivider(line) {
          const cells = markdownTableCells(line);
          return cells.length > 0 && cells.every(cell =>
            /^:?-{3,}:?$/.test(cell.replace(/\s+/g, ''))
          );
        }
        function markdownTableAlignment(cell) {
          const compact = cell.replace(/\s+/g, '');
          if (compact.startsWith(':') && compact.endsWith(':')) return 'center';
          if (compact.endsWith(':')) return 'right';
          return 'left';
        }
        function renderMarkdownTable(headerLine, dividerLine, bodyLines) {
          const headers = markdownTableCells(headerLine);
          const dividers = markdownTableCells(dividerLine);
          const width = Math.max(headers.length, dividers.length);
          const alignments = Array.from({length: width}, (_, index) =>
            markdownTableAlignment(dividers[index] || '---')
          );
          const normalize = cells => Array.from(
            {length: width},
            (_, index) => cells[index] || ''
          );
          const head = normalize(headers).map((cell, index) =>
            `<th style="text-align:${alignments[index]}">${markdownInline(cell)}</th>`
          ).join('');
          const body = bodyLines.map(line => {
            const cells = normalize(markdownTableCells(line));
            return `<tr>${cells.map((cell, index) =>
              `<td style="text-align:${alignments[index]}">${markdownInline(cell)}</td>`
            ).join('')}</tr>`;
          }).join('');
          return `<div class="markdown-table-wrap"><table><thead><tr>${head}</tr></thead>${body ? `<tbody>${body}</tbody>` : ''}</table></div>`;
        }
        function renderMarkdown(value) {
          const source = text(value).replace(/\r\n/g, '\n');
          const fences = [];
          const tokenized = source.replace(/```([^\n]*)\n([\s\S]*?)```/g,
            (_, language, code) => {
              const token = `@@GLAUCO_CODE_${fences.length}@@`;
              fences.push(`<pre><code data-language="${escapeHtml(language.trim())}">${escapeHtml(code.replace(/\n$/, ''))}</code></pre>`);
              return token;
            });
          const lines = tokenized.split('\n');
          const blocks = [];
          let listType = '';
          const closeList = () => {
            if (listType) blocks.push(`</${listType}>`);
            listType = '';
          };
          for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
            const rawLine = lines[lineIndex];
            const line = rawLine.trimEnd();
            const nextLine = lineIndex + 1 < lines.length
              ? lines[lineIndex + 1].trimEnd()
              : '';
            if (
              line.includes('|') &&
              markdownTableDivider(nextLine) &&
              markdownTableCells(line).length === markdownTableCells(nextLine).length
            ) {
              closeList();
              const tableRows = [];
              let cursor = lineIndex + 2;
              while (cursor < lines.length) {
                const candidate = lines[cursor].trimEnd();
                if (!candidate.trim() || !candidate.includes('|')) break;
                tableRows.push(candidate);
                cursor++;
              }
              blocks.push(renderMarkdownTable(line, nextLine, tableRows));
              lineIndex = cursor - 1;
              continue;
            }
            const codeMatch = line.match(/^@@GLAUCO_CODE_(\d+)@@$/);
            if (codeMatch) {
              closeList();
              blocks.push(fences[Number(codeMatch[1])]);
              continue;
            }
            const heading = line.match(/^(#{1,6})\s+(.+)$/);
            if (heading) {
              closeList();
              const level = heading[1].length;
              blocks.push(`<h${level}>${markdownInline(heading[2])}</h${level}>`);
              continue;
            }
            const unordered = line.match(/^\s*[-*+]\s+(.+)$/);
            const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
            if (unordered || ordered) {
              const nextType = unordered ? 'ul' : 'ol';
              if (listType !== nextType) {
                closeList();
                listType = nextType;
                blocks.push(`<${listType}>`);
              }
              blocks.push(`<li>${markdownInline((unordered || ordered)[1])}</li>`);
              continue;
            }
            const quote = line.match(/^>\s?(.*)$/);
            if (quote) {
              closeList();
              blocks.push(`<blockquote>${markdownInline(quote[1])}</blockquote>`);
              continue;
            }
            if (!line.trim()) {
              closeList();
              continue;
            }
            closeList();
            blocks.push(`<p>${markdownInline(line)}</p>`);
          }
          closeList();
          return blocks.join('');
        }
        const clear = element => {
          while (element && element.firstChild) element.removeChild(element.firstChild);
        };
        const button = (label, className, onClick) => {
          const element = document.createElement('button');
          element.type = 'button';
          element.className = className;
          element.textContent = label;
          element.addEventListener('click', onClick);
          return element;
        };
        const formatTime = value => {
          if (!value) return '';
          const date = new Date(value);
          if (Number.isNaN(date.getTime())) return '';
          return date.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
        };

        function selectedVoice(config) {
          if (!window.speechSynthesis) return null;
          const voices = speechSynthesis.getVoices();
          const configured = text(config && config.voiceName).toLowerCase();
          if (configured) {
            const exact = voices.find(voice => voice.name.toLowerCase() === configured);
            if (exact) return exact;
            const partial = voices.find(voice => voice.name.toLowerCase().includes(configured));
            if (partial) return partial;
          }
          const language = text(config && config.language).toLowerCase();
          return voices.find(voice => voice.lang.toLowerCase() === language) ||
            voices.find(voice => voice.lang.toLowerCase().startsWith(language.split('-')[0])) ||
            null;
        }

        function speak(value, force = false) {
          const snapshot = state.snapshot;
          if (!window.speechSynthesis || !value) return;
          if (!force && !(snapshot && snapshot.config && snapshot.config.autoSpeak)) return;
          speechSynthesis.cancel();
          const utterance = new SpeechSynthesisUtterance(value);
          utterance.lang = text(snapshot && snapshot.config && snapshot.config.language) || 'pt-BR';
          const voice = selectedVoice(snapshot && snapshot.config);
          if (voice) utterance.voice = voice;
          utterance.rate = 1;
          utterance.pitch = 1;
          utterance.onstart = () => {
            const note = byId('assistant-status-text');
            if (note) note.textContent = 'Falando';
          };
          utterance.onend = utterance.onerror = () => {
            const note = byId('assistant-status-text');
            if (note && state.snapshot) note.textContent = statusLabel(state.snapshot.status);
          };
          state.lastAssistantText = value;
          speechSynthesis.speak(utterance);
        }

        function stopSpeaking() {
          if (window.speechSynthesis) speechSynthesis.cancel();
        }

        function statusLabel(status) {
          switch (status) {
            case 'queued': return 'Na fila';
            case 'thinking': return 'Pensando';
            case 'error': return 'Falha';
            case 'ready': return 'Pronto';
            default: return status || 'Pronto';
          }
        }

        function renderSessions(snapshot) {
          const list = byId('assistant-session-list');
          clear(list);
          for (const session of snapshot.sessions || []) {
            const item = button('', 'assistant-session' +
              (session.id === snapshot.activeSessionId ? ' active' : ''), () => {
                emit('assistant:select-session', session.id);
              });
            const title = document.createElement('strong');
            title.textContent = text(session.title) || 'Nova sessão';
            const summary = document.createElement('small');
            summary.textContent = text(session.summary) || 'Conversa';
            item.append(title, summary);
            list.appendChild(item);
          }
        }

        function renderThings(snapshot) {
          const list = byId('assistant-thing-list');
          clear(list);
          const things = (snapshot.things || []).slice(0, 20);
          if (!things.length) {
            const empty = document.createElement('p');
            empty.className = 'assistant-composer-note';
            empty.textContent = 'Nenhuma coisa consolidada ainda.';
            list.appendChild(empty);
            return;
          }
          for (const thing of things) {
            const card = document.createElement('article');
            card.className = 'assistant-thing';
            const head = document.createElement('div');
            head.className = 'assistant-thing-head';
            const kind = document.createElement('span');
            kind.className = 'assistant-thing-kind';
            kind.textContent = text(thing.kind || 'coisa');
            const title = document.createElement('strong');
            title.textContent = text(thing.title);
            head.append(kind, title);
            const body = document.createElement('p');
            body.textContent = text(thing.content);
            const actions = document.createElement('div');
            actions.className = 'assistant-thing-actions';
            actions.append(
              button(thing.pinned ? 'Desafixar' : 'Fixar', 'assistant-mini-button', () => emit('assistant:pin-thing', thing.id)),
              button('Esquecer', 'assistant-mini-button', () => emit('assistant:forget-thing', thing.id))
            );
            card.append(head, body, actions);
            list.appendChild(card);
          }
        }

        function renderMessages(snapshot) {
          const container = byId('assistant-messages');
          const previousScrollTop = container.scrollTop;
          const previousDistanceFromBottom = Math.max(
            0,
            container.scrollHeight - container.scrollTop - container.clientHeight
          );
          const wasNearBottom = previousDistanceFromBottom < 96;
          const session = snapshot.activeSession || {};
          const sessionId = text(session.id || snapshot.activeSessionId);
          const changedSession = sessionId !== (container.dataset.sessionId || '');

          clear(container);
          const messages = session.messages || [];
          container.dataset.sessionId = sessionId;
          container.dataset.messageCount = String(messages.length);

          if (!messages.length) {
            const empty = document.createElement('div');
            empty.className = 'assistant-empty';
            empty.textContent = 'Converse por texto ou voz. O aprendizado útil aparecerá na lateral.';
            container.appendChild(empty);
            return;
          }

          for (const message of messages) {
            const bubble = document.createElement('article');
            bubble.className = 'assistant-message ' + (message.role === 'user' ? 'user' : 'assistant');
            const body = document.createElement('div');
            if (message.role === 'user') {
              body.textContent = text(message.content);
            } else {
              body.innerHTML = renderMarkdown(message.content);
            }
            const time = document.createElement('span');
            time.className = 'assistant-message-time';
            time.textContent = formatTime(message.createdAt);
            bubble.append(body, time);
            container.appendChild(bubble);
          }

          requestAnimationFrame(() => {
            if (changedSession || wasNearBottom) {
              container.scrollTop = container.scrollHeight;
            } else {
              container.scrollTop = previousScrollTop;
            }
          });
        }

        function applySnapshot(snapshot) {
          if (!snapshot || typeof snapshot !== 'object') return;
          state.snapshot = snapshot;
          renderSessions(snapshot);
          renderThings(snapshot);
          renderMessages(snapshot);

          const currentTitle = byId('assistant-current-title');
          if (currentTitle) currentTitle.textContent =
            text(snapshot.activeSession && snapshot.activeSession.title) || 'Nova sessão';
          const status = byId('assistant-status');
          if (status) status.dataset.status = snapshot.status || 'idle';
          const statusText = byId('assistant-status-text');
          if (statusText) statusText.textContent = statusLabel(snapshot.status);
          const nativeVoiceState = text(snapshot.voiceState).toLowerCase();
          const microphone = byId('assistant-microphone');
          const voiceNote = byId('assistant-voice-note');
          const recording = nativeVoiceState === 'recording' ||
            nativeVoiceState === 'starting';
          state.listening = recording;
          if (microphone) microphone.classList.toggle('listening', recording);
          if (voiceNote) {
            if (nativeVoiceState === 'recording') {
              voiceNote.textContent = 'Ouvindo pelo microfone nativo; clique novamente para transcrever.';
            } else if (nativeVoiceState === 'stopping') {
              voiceNote.textContent = 'Finalizando a gravação…';
            } else if (nativeVoiceState === 'queued' || nativeVoiceState === 'transcribing') {
              voiceNote.textContent = 'Transcrevendo localmente com whisper.cpp…';
            } else if (nativeVoiceState === 'error' && snapshot.lastError) {
              voiceNote.textContent = text(snapshot.lastError);
            }
          }

          const autoSpeak = byId('assistant-auto-speak');
          if (autoSpeak) autoSpeak.checked = !!(snapshot.config && snapshot.config.autoSpeak);
          const error = byId('assistant-error');
          if (error) {
            error.hidden = !snapshot.lastError;
            error.textContent = text(snapshot.lastError);
          }

          if (snapshot.lastTranscriptId &&
              snapshot.lastTranscriptId !== state.transcriptId) {
            state.transcriptId = snapshot.lastTranscriptId;
            if (!(snapshot.config && snapshot.config.autoSendVoice)) {
              const composer = byId('assistant-composer');
              if (composer) composer.value = text(snapshot.lastTranscript);
            }
          }

          if (snapshot.lastResponseId &&
              snapshot.lastResponseId !== state.spokenMessageId) {
            state.spokenMessageId = snapshot.lastResponseId;
            state.lastAssistantText = text(snapshot.lastResponse);
            speak(state.lastAssistantText);
          }
        }

        function sendComposer() {
          const composer = byId('assistant-composer');
          const value = composer ? composer.value.trim() : '';
          if (!value) return;
          emit('assistant:send', value);
          composer.value = '';
          composer.style.height = 'auto';
        }

        function installSystemRecorder() {
          const microphone = byId('assistant-microphone');
          const note = byId('assistant-voice-note');
          if (!microphone) return;
          microphone.addEventListener('click', () => {
            if (state.listening) {
              emit('assistant:voice-stop');
              note.textContent = 'Finalizando áudio e enviando ao Whisper…';
            } else {
              emit('assistant:voice-start');
              note.textContent = 'Abrindo o microfone nativo do computador…';
            }
          });
        }

        function installNativeRecorder() {
          const microphone = byId('assistant-microphone');
          const note = byId('assistant-voice-note');

          if (
            !navigator.mediaDevices ||
            !navigator.mediaDevices.getUserMedia ||
            !window.MediaRecorder
          ) {
            microphone.disabled = true;
            note.textContent =
              'Captura de microfone indisponível neste WebView.';
            return;
          }

          microphone.addEventListener('click', async () => {
            if (
              state.mediaRecorder &&
              state.mediaRecorder.state === 'recording'
            ) {
              state.mediaRecorder.stop();
              return;
            }

            try {
              state.mediaStream =
                await navigator.mediaDevices.getUserMedia({
                  audio: true
                });

              state.audioChunks = [];

              const preferred = [
                'audio/webm;codecs=opus',
                'audio/ogg;codecs=opus',
                'audio/mp4'
              ].find(type =>
                MediaRecorder.isTypeSupported(type)
              );

              state.mediaRecorder = preferred
                ? new MediaRecorder(
                    state.mediaStream,
                    { mimeType: preferred }
                  )
                : new MediaRecorder(state.mediaStream);

              state.mediaRecorder.ondataavailable = event => {
                if (event.data && event.data.size) {
                  state.audioChunks.push(event.data);
                }
              };

              state.mediaRecorder.onstart = () => {
                state.listening = true;
                microphone.classList.add('listening');
                note.textContent =
                  'Gravando; clique novamente para transcrever com Whisper…';
              };

              state.mediaRecorder.onstop = () => {
                state.listening = false;
                microphone.classList.remove('listening');

                const mimeType =
                  state.mediaRecorder.mimeType ||
                  (
                    state.audioChunks[0] &&
                    state.audioChunks[0].type
                  ) ||
                  'audio/webm';

                const blob = new Blob(
                  state.audioChunks,
                  { type: mimeType }
                );

                const reader = new FileReader();

                reader.onloadend = () => {
                  const encoded =
                    String(reader.result || '')
                      .split(',')
                      .pop() || '';

                  emit('assistant:voice-audio', {
                    data: encoded,
                    mimeType
                  });

                  note.textContent =
                    'Transcrevendo localmente com whisper.cpp…';
                };

                reader.readAsDataURL(blob);

                if (state.mediaStream) {
                  for (
                    const track of
                    state.mediaStream.getTracks()
                  ) {
                    track.stop();
                  }
                }
              };

              state.mediaRecorder.start();
            } catch (error) {
              note.textContent =
                'Falha ao abrir o microfone: ' +
                text(
                  error &&
                  error.message ||
                  error
                );
            }
          });
        }


        function installPhoneAdbRecorder() {
          const microphone = byId('assistant-microphone');
          const note = byId('assistant-voice-note');
          const endpoint = 'http://127.0.0.1:5003';
          let recording = false;

          async function phoneRequest(path, method = 'GET') {
            const response = await fetch(endpoint + path, {
              method,
              cache: 'no-store',
              headers: { 'Accept': 'application/json' }
            });
            const payload = await response.json().catch(() => ({}));
            if (!response.ok || payload.ok === false) {
              throw new Error(payload.error || ('HTTP ' + response.status));
            }
            return payload;
          }

          microphone.addEventListener('click', async () => {
            if (microphone.disabled) return;
            microphone.disabled = true;
            try {
              if (!recording) {
                await phoneRequest('/record/start', 'POST');
                recording = true;
                state.listening = true;
                microphone.classList.add('listening');
                note.textContent = 'Ouvindo pelo microfone do celular; clique novamente para transcrever…';
              } else {
                note.textContent = 'Recebendo áudio do celular…';
                const payload = await phoneRequest('/record/stop', 'POST');
                recording = false;
                state.listening = false;
                microphone.classList.remove('listening');
                emit('assistant:voice-audio', {
                  data: payload.data || '',
                  mimeType: payload.mimeType || 'audio/wav'
                });
                note.textContent = 'Transcrevendo localmente com whisper.cpp…';
              }
            } catch (error) {
              recording = false;
              state.listening = false;
              microphone.classList.remove('listening');
              note.textContent = 'Falha no microfone do celular: ' + text(error && error.message || error);
            } finally {
              microphone.disabled = false;
            }
          });

          phoneRequest('/status').then(status => {
            note.textContent = status.phoneConnected
              ? 'Microfone do celular conectado por ADB.'
              : 'Abra o Audio Phone Speaker e confirme a permissão de microfone.';
          }).catch(() => {
            note.textContent = 'Inicie audio_sender.py para usar o microfone do celular.';
          });
          return true;
        }

        function installWebRecognition() {
          const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
          const microphone = byId('assistant-microphone');
          const note = byId('assistant-voice-note');
          if (!Recognition) return false;
          const recognition = new Recognition();
          recognition.lang = 'pt-BR';
          recognition.interimResults = true;
          recognition.continuous = false;
          state.recognition = recognition;
          recognition.onstart = () => {
            state.listening = true;
            microphone.classList.add('listening');
            note.textContent = 'Ouvindo…';
          };
          recognition.onresult = event => {
            let transcript = '';
            let finalResult = false;
            for (let index = event.resultIndex; index < event.results.length; index++) {
              transcript += event.results[index][0].transcript;
              finalResult = finalResult || event.results[index].isFinal;
            }
            const composer = byId('assistant-composer');
            if (composer) composer.value = transcript.trim();
            if (finalResult && state.snapshot && state.snapshot.config &&
                state.snapshot.config.autoSendVoice) setTimeout(sendComposer, 120);
          };
          recognition.onerror = event => {
            note.textContent = 'Falha no reconhecimento: ' + text(event.error);
          };
          recognition.onend = () => {
            state.listening = false;
            microphone.classList.remove('listening');
          };
          microphone.addEventListener('click', () => {
            if (state.listening) recognition.stop();
            else recognition.start();
          });
          return true;
        }

function installVoiceInput() {
          const backend = text(
            state.snapshot &&
              state.snapshot.config &&
              state.snapshot.config.voiceRecognition ||
            window.__glaucoplasticAssistantVoiceBackend
          ).toLowerCase();

          const nativeSystemBackend =
            backend.includes('system') ||
            backend.includes('native') ||
            backend.includes('pipewire') ||
            backend.includes('pulse');

          if (
            backend.includes('phone') ||
            backend.includes('adb')
          ) {
            installPhoneAdbRecorder();
          } else if (
            nativeSystemBackend ||
            window.__glaucoplasticWebMode
          ) {
            installSystemRecorder();
          } else if (
            backend &&
            !backend.includes('web') &&
            !backend.includes('speechrecognition')
          ) {
            installNativeRecorder();
          } else if (!installWebRecognition()) {
            installNativeRecorder();
          }
        }

window.__glaucoplasticAssistantApply = applySnapshot;
        byId('assistant-new-session')?.addEventListener('click', () => emit('assistant:new-session'));
        byId('assistant-send')?.addEventListener('click', sendComposer);
        byId('assistant-composer')?.addEventListener('keydown', event => {
          if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            sendComposer();
          }
        });
        byId('assistant-composer')?.addEventListener('input', event => {
          const composer = event.currentTarget;
          composer.style.height = 'auto';
          composer.style.height = Math.min(composer.scrollHeight, 150) + 'px';
        });
        byId('assistant-auto-speak')?.addEventListener('change', event => {
          emit('assistant:auto-speak', !!event.currentTarget.checked, !!event.currentTarget.checked);
          if (!event.currentTarget.checked) stopSpeaking();
        });
        byId('assistant-repeat-voice')?.addEventListener('click', () => speak(state.lastAssistantText, true));
        byId('assistant-stop-voice')?.addEventListener('click', stopSpeaking);
        installVoiceInput();
        if (window.speechSynthesis) speechSynthesis.getVoices();
      })();
    </script>
  """

# WHITE_PLASTIC_FOR_GLAUCO_V1
proc plasticOfficeRuntimePython*(): string =
  let configured = getEnv("GLAUCOPLASTIC_OFFICE_PYTHON", "").strip
  if configured.len > 0:
    return expandTilde(configured)
  when defined(windows):
    "python"
  else:
    "python3"

proc plasticOfficeRuntimeBridge*(): string =
  let configured = getEnv("GLAUCOPLASTIC_OFFICE_BRIDGE", "").strip
  if configured.len > 0:
    return expandTilde(configured)
  getCurrentDir() / "tools" / "glaucoplastic_office.py"

proc plasticOfficeInvoke*(capability: string; arguments: JsonNode): JsonNode =
  let python = plasticOfficeRuntimePython()
  let bridge = plasticOfficeRuntimeBridge()
  if not fileExists(bridge):
    raise newException(
      PlasticAgentError,
      "Office bridge not found: " & bridge
    )
  let tempRoot = getTempDir() / "glaucoplastic-office"
  createDir(tempRoot)
  let inputPath = tempRoot / (
    "arguments-" & $epochTime().int64 & "-" & $getCurrentProcessId() & ".json"
  )
  writeFile(inputPath, $arguments)
  defer:
    if fileExists(inputPath):
      removeFile(inputPath)
  let command = @[python, bridge, capability, inputPath]
    .mapIt(quoteShell(it))
    .join(" ")
  let execution = execCmdEx(
    command,
    options = {poUsePath, poStdErrToStdOut}
  )
  let payload = execution.output.strip
  if payload.len == 0:
    raise newException(
      PlasticAgentError,
      "Office tool returned empty output: " & capability
    )
  try:
    result = parseJson(payload)
  except CatchableError as error:
    raise newException(
      PlasticAgentError,
      "Invalid Office tool JSON for " & capability & ": " &
        error.msg & "\\n" & payload
    )
  if execution.exitCode != 0 or
      (result.kind == JObject and result.hasKey("ok") and
       result["ok"].kind == JBool and not result["ok"].getBool):
    raise newException(
      PlasticAgentError,
      "Office tool failed: " & capability & "\\n" & payload
    )

proc plasticAssistantVoiceExtension(mimeType: string): string =
  let normalized = mimeType.toLowerAscii
  if normalized.contains("webm"): return ".webm"
  if normalized.contains("ogg"): return ".ogg"
  if normalized.contains("mp4") or normalized.contains("m4a"): return ".m4a"
  if normalized.contains("wav"): return ".wav"
  ".audio"

proc plasticAssistantWhisperLanguage(language: string): string =
  let normalized = language.strip.replace('_', '-')
  if normalized.len == 0: return "auto"
  normalized.split('-')[0].toLowerAscii

proc plasticAssistantTranscribeNative(
  runtime: PlasticAssistantRuntime;
  job: PlasticAssistantVoiceJob
): string =
  if runtime.config.whisperModel.strip.len == 0:
    raise newException(
      PlasticRuntimeError,
      "Whisper model not configured. Set GLAUCOPLASTIC_WHISPER_MODEL."
    )
  let voiceRoot = runtime.rootPath / "voice"
  createDir(voiceRoot)
  let token = $epochTime().int64 & "-" & $getCurrentProcessId()
  let sourcePath = voiceRoot / (
    "source-" &
    token &
    plasticAssistantVoiceExtension(job.mimeType)
  )
  let wavPath = voiceRoot / (
    "prepared-" &
    token &
    ".wav"
  )
  let outputPrefix = voiceRoot / ("transcript-" & token)
  writeFile(sourcePath, decode(job.audioBase64))

  let ffmpegCommand = @[
    runtime.config.ffmpegBinary,
    "-hide_banner", "-loglevel", "error", "-y",
    "-i", sourcePath,
    "-ar", "16000",
    "-ac", "1",
    "-c:a", "pcm_s16le",
    wavPath
  ].mapIt(quoteShell(it)).join(" ")
  let ffmpegResult = execCmdEx(
    ffmpegCommand,
    options = {poUsePath, poStdErrToStdOut}
  )
  if ffmpegResult.exitCode != 0:
    raise newException(
      PlasticRuntimeError,
      "FFmpeg failed while preparing microphone audio:\\n" & ffmpegResult.output
    )

  let whisperCommand = @[
    runtime.config.whisperBinary,
    "-m", expandTilde(runtime.config.whisperModel),
    "-f", wavPath,
    "-l", plasticAssistantWhisperLanguage(runtime.config.language),
    "-nt", "-np", "-otxt", "-of", outputPrefix
  ].mapIt(quoteShell(it)).join(" ")
  let whisperResult = execCmdEx(
    whisperCommand,
    options = {poUsePath, poStdErrToStdOut}
  )
  let transcriptPath = outputPrefix & ".txt"
  if whisperResult.exitCode != 0 or not fileExists(transcriptPath):
    raise newException(
      PlasticRuntimeError,
      "whisper.cpp failed:\\n" & whisperResult.output
    )
  result = readFile(transcriptPath).strip
  if not plasticAssistantEnvEnabled("GLAUCOPLASTIC_KEEP_VOICE_AUDIO", false):
    for path in [sourcePath, wavPath, transcriptPath]:
      if fileExists(path): removeFile(path)

proc plasticAssistantResultText(value: JsonNode): string {.gcsafe.} =
  case value.kind
  of JString:
    value.getStr.strip
  of JObject:
    if value.hasKey("answer") and value["answer"].kind == JString:
      value["answer"].getStr.strip
    elif value.hasKey("content") and value["content"].kind == JString:
      value["content"].getStr.strip
    else:
      value.pretty()
  else:
    value.pretty()

proc runPlasticAssistantVoiceWorker(
  state: PlasticAssistantVoiceWorkerState
) {.thread.} =
  if state.isNil: return
  state.running = true
  while not state.stopping:
    var hasJob = false
    var job: PlasticAssistantVoiceJob
    acquire(state.queueLock)
    if state.jobs.len > 0:
      job = state.jobs[0]
      state.jobs.delete(0)
      state.active = true
      hasJob = true
    release(state.queueLock)
    if not hasJob:
      sleep(25)
      continue
    let runtime = state.runtime
    acquire(runtime.dataLock)
    runtime.voiceState = "transcribing"
    runtime.lastError = ""
    inc runtime.revision
    release(runtime.dataLock)
    try:
      let transcript = runtime.plasticAssistantTranscribeNative(job)
      var autoSend = false
      acquire(runtime.dataLock)
      runtime.lastTranscript = transcript
      runtime.lastTranscriptId =
        "transcript-" & $epochTime().int64 & "-" & $state.processed
      runtime.voiceState = "idle"
      autoSend = runtime.config.autoSendVoice
      inc runtime.revision
      release(runtime.dataLock)
      if transcript.len > 0 and autoSend:
        runtime.enqueueMessage(transcript)
      inc state.processed
    except CatchableError as error:
      acquire(runtime.dataLock)
      runtime.voiceState = "error"
      runtime.lastError = error.msg
      inc runtime.revision
      release(runtime.dataLock)
      state.lastError = error.msg
      inc state.failed
    acquire(state.queueLock)
    state.active = false
    release(state.queueLock)
  state.running = false


proc activeOkfRuntime*(agent: PlasticAgent): PlasticOkfRuntime =
  if not agent.isNil and not agent.okfValue.isNil:
    return agent.okfValue
  if not agent.isNil and not agent.application.isNil:
    return agent.application.okfValue
  nil

proc plasticOkfConsultationSkillText*(): string =
  result = """
Consulte os OKFs existentes antes de responder sobre conhecimento persistido.
Use okf.search para busca global, okf.<espaco>.search para busca restrita,
okf.get para documentos completos e okf.tree para conhecer a organização.
Toda leitura de OKF devolve interpretação do LLM junto do dado bruto.
"""

proc plasticOkfGenerationSkillText*(): string =
  result = """
Quando o pedido exigir produzir ou estruturar conhecimento:
1. consulte OKFs existentes;
2. identifique relações;
3. escolha o espaço adequado;
4. produza título, resumo, elementos, propriedades, relações e funções;
5. registre fontes e metadados;
6. use okf.generate ou okf.update;
7. devolva o identificador persistido.
"""

type
  PlasticRenderEnvironment* = Table[string, JsonNode]

when defined(linux):
  type
    PlasticGtkAllocation* {.bycopy.} = object
      x*, y*, width*, height*: cint

    PlasticGSourceFunc* = proc(data: pointer): cint {.cdecl.}
    PlasticGAsyncReadyCallback* = proc(
      sourceObject: pointer;
      result: pointer;
      userData: pointer
    ) {.cdecl.}

    PlasticJsEvalRequest* = ref object
      completed*: bool
      failed*: bool
      text*: string

    PlasticLlamaBootState* = ref object
      lock*: Lock
      done*: bool
      failed*: bool
      message*: string
      phase*: string
      connection*: string
      model*: string
      detail*: string
      progress*: int
      llama*: PlasticLlamaRuntime
      metis*: PlasticMetisMemory

    PlasticLinuxDesktopRuntime* = ref object of PlasticDesktopRuntime
      application*: PlasticApplication
      window*: pointer
      overlay*: pointer
      fixed*: pointer
      bootWidget*: pointer
      bootSpinner*: pointer
      bootProgress*: pointer
      bootTitle*: pointer
      bootStatus*: pointer
      bootVisualProgress*: int
      bootTraceProgress*: int
      bootTracePhase*: string
      websiteDataManager*: pointer
      webContext*: pointer
      mainWebView*: pointer
      width*: int
      height*: int
      geometryTimer*: cuint
      autoStartModel*: bool
      llamaBootTimer*: cuint
      llamaBootThread*: Thread[PlasticLlamaBootState]
      llamaBootState*: PlasticLlamaBootState
      consoleReplTimer*: cuint
      consoleReplThread*: Thread[PlasticConsoleReplState]
      consoleReplState*: PlasticConsoleReplState

    PlasticConsoleReplState* = ref object
      desktop*: PlasticLinuxDesktopRuntime
      lock*: Lock
      pendingLines*: seq[string]
      running*: bool

  type
    PlasticLinuxUiCandidate* = object
      backend*: string
      disableDmabuf*: bool
      reason*: string

when defined(linux):
  const PlasticAgentGLibLib = "libglib-2.0.so(|.0)"

  proc plasticAgentTimeoutAdd(
    interval: cuint;
    callback: PlasticGSourceFunc;
    data: pointer
  ): cuint
    {.cdecl, importc: "g_timeout_add", dynlib: PlasticAgentGLibLib.}

proc stateAccessPathAst(node: NimNode): seq[string] =
  case node.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    if node.repr notin ["state", "states"]:
      result.add node.repr
  of nnkDotExpr:
    result.add stateAccessPathAst(node[0])
    result.add stateAccessPathAst(node[1])
  of nnkCall, nnkCommand:
    if node.len == 0:
      discard
    else:
      for index in 0 ..< node.len:
        if index == 0 and node[index].repr in ["state", "states"]:
          continue
        result.add stateAccessPathAst(node[index])
  else:
    let raw = node.repr
    if raw.len > 0:
      for token in raw
          .replace("(", " ")
          .replace(")", " ")
          .replace(",", " ")
          .split({'.', ' ', '\t'}):
        let cleaned = token.strip
        if cleaned.len > 0 and cleaned notin ["state", "states"]:
          result.add cleaned

proc buildStateAccessExpr*(applicationSymbol: NimNode; statePath: NimNode): NimNode =
  let path = stateAccessPathAst(statePath)
  if path.len == 0:
    error(
      "Use `state Nome` ou `state Nome.propriedade`.",
      statePath
    )

  let pathLiteral = newTree(nnkBracket)
  for part in path:
    pathLiteral.add newLit(part)

  result = newCall(
    ident("glaucoplasticStateGetPathInternal"),
    newDotExpr(applicationSymbol, ident("statesValue")),
    pathLiteral
  )

proc buildStringSeqLiteral(values: seq[string]): NimNode =
  result = newTree(nnkBracket)
  for value in values:
    result.add newLit(value)

proc buildStateAssignmentExpr(
  applicationSymbol: NimNode;
  statePath: NimNode;
  valueExpr: NimNode
): NimNode =
  let path = stateAccessPathAst(statePath)
  if path.len == 0:
    error("Use `state Nome` ou `state Nome.propriedade`.", statePath)

  newCall(
    ident("glaucoplasticStateSetPathInternal"),
    newDotExpr(applicationSymbol, ident("statesValue")),
    buildStringSeqLiteral(path),
    newCall(ident("plasticJson"), valueExpr)
  )

macro glaucoplasticFragment*(fragmentName: untyped; body: untyped): untyped =
  ## Exporta um fragmento de plano reutilizável por outro arquivo.
  ##
  ## O fragmento é serializado como JSON em uma constante exportada. O arquivo
  ## consumidor importa o módulo Nim normalmente e lista a constante no bloco
  ## `modules:` da aplicação principal.
  proc isIdentifier(node: NimNode): bool =
    not node.isNil and node.kind in {nnkIdent, nnkSym}

  proc astLiteral(node: NimNode): JsonNode =
    case node.kind
    of nnkPrefix:
      if node.len == 2 and node[0].repr in ["%", "%*"]:
        return astLiteral(node[1])
      result = newJNull()
    of nnkPar:
      if node.len == 1:
        return astLiteral(node[0])
      result = newJNull()
    of nnkTableConstr:
      proc literalKeyName(keyNode: NimNode): string =
        case keyNode.kind
        of nnkIdent, nnkSym, nnkAccQuoted:
          result = keyNode.repr
        of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
          result = keyNode.strVal
        else:
          result = keyNode.repr

      result = newJObject()
      for child in node:
        if child.kind == nnkExprColonExpr:
          let key = literalKeyName(child[0])
          if key.len > 0:
            result[key] = astLiteral(child[1])
    of nnkBracket:
      result = newJArray()
      for child in node:
        result.add astLiteral(child)
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      result = %node.strVal
    of nnkIntLit .. nnkUInt64Lit:
      result = %node.intVal
    of nnkFloatLit .. nnkFloat128Lit:
      result = %node.floatVal
    of nnkIdent:
      case node.strVal
      of "true":
        result = %true
      of "false":
        result = %false
      of "nil":
        result = newJNull()
      else:
        result = newJNull()
    else:
      result = newJNull()

  proc astDslName(node: NimNode): string =
    case node.kind
    of nnkIdent, nnkSym:
      result = node.strVal
    of nnkAccQuoted:
      for child in node:
        result.add astDslName(child)
    else:
      let raw = node.repr
      if raw.len >= 2 and raw[0] == '`' and raw[^1] == '`':
        result = raw[1 .. ^2]
      else:
        result = raw

  proc callBaseAst(node: NimNode): NimNode =
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return newEmptyNode()
    if node[0].kind in {nnkCall, nnkCommand}:
      return callBaseAst(node[0])
    node[0]

  proc rawCallArgumentsAst(node: NimNode): seq[NimNode] =
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return
    if node[0].kind in {nnkCall, nnkCommand}:
      let nested = rawCallArgumentsAst(node[0])
      for child in nested:
        result.add child
      for index in 1 ..< node.len:
        result.add node[index]
      return
    for index in 1 ..< node.len:
      result.add node[index]

  proc callArgumentsAst(node: NimNode): seq[NimNode] =
    for argument in rawCallArgumentsAst(node):
      if argument.kind == nnkExprColonExpr:
        result.add argument[1]
      else:
        result.add argument

  proc callBodyAst(node: NimNode): NimNode =
    if node.kind notin {nnkCall, nnkCommand}:
      return newEmptyNode()
    if node.len == 0:
      return newEmptyNode()
    let candidate = node[^1]
    if candidate.kind == nnkStmtList:
      return candidate
    if candidate.kind == nnkCommand and candidate.len == 1:
      let nestedBody = callBodyAst(candidate[0])
      if nestedBody.kind == nnkStmtList:
        return nestedBody
    newEmptyNode()

  proc astToPlanJson(node: NimNode): JsonNode =
    result = newJObject()
    result["source"] = %node.repr
    result["astKind"] = %($node.kind)

    case node.kind
    of nnkStmtList:
      result["kind"] = %"root"
      result["children"] = newJArray()
      for child in node:
        result["children"].add astToPlanJson(child)
    of nnkCall, nnkCommand:
      result["kind"] = %"call"
      var callName = astDslName(callBaseAst(node))
      if callName == "divi":
        callName = "div"
      result["name"] = %callName
      result["arguments"] = newJArray()
      for argument in callArgumentsAst(node):
        result["arguments"].add astToPlanJson(argument)
      let bodyNode = callBodyAst(node)
      result["children"] =
        if bodyNode.kind == nnkStmtList:
          var children = newJArray()
          for child in bodyNode:
            children.add astToPlanJson(child)
          children
        else:
          newJArray()
    of nnkExprEqExpr:
      let argumentName = astDslName(node[0])
      result["kind"] = %"namedArgument"
      result["name"] = %argumentName
      result["value"] = astToPlanJson(node[1])
    of nnkInfix:
      if node.len == 3 and astDslName(node[0]) == "isset":
        result["kind"] = %"assignment"
        result["left"] = astToPlanJson(node[1])
        result["value"] = astToPlanJson(node[2])
        result["name"] = %node[1].repr.splitWhitespace()[0]
      else:
        result["kind"] = %"expression"
        result["children"] = newJArray()
        for child in node:
          result["children"].add astToPlanJson(child)
    of nnkAsgn:
      result["kind"] = %"assignment"
      result["left"] = astToPlanJson(node[0])
      result["value"] = astToPlanJson(node[1])
      result["name"] = %node[0].repr.splitWhitespace()[0]
    of nnkWhenStmt:
      result["kind"] = %"when"
      result["branches"] = newJArray()
      for child in node:
        result["branches"].add astToPlanJson(child)
      if node.len > 0 and node[0].kind == nnkElifBranch:
        result["condition"] = astToPlanJson(node[0][0])
        result["children"] = newJArray()
        for child in node[0][1]:
          result["children"].add astToPlanJson(child)
    of nnkElifBranch:
      result["kind"] = %"whenBranch"
      result["condition"] = astToPlanJson(node[0])
      result["children"] = newJArray()
      for child in node[1]:
        result["children"].add astToPlanJson(child)
    of nnkTableConstr:
      result["kind"] = %"map"
      result["children"] = newJArray()
      for child in node:
        result["children"].add astToPlanJson(child)
    of nnkExprColonExpr:
      result["kind"] = %"mapEntry"
      result["name"] = %astDslName(node[0])
      result["value"] = astToPlanJson(node[1])
    of nnkDotExpr:
      result["kind"] = %"path"
      result["name"] = %node.repr
      result["children"] = newJArray()
      for child in node:
        result["children"].add astToPlanJson(child)
    of nnkIdent, nnkSym:
      result["kind"] = %"identifier"
      result["name"] = %node.strVal
      let literal = astLiteral(node)
      if literal.kind != JNull or node.strVal == "nil":
        result["literal"] = literal
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit,
       nnkIntLit .. nnkUInt64Lit,
       nnkFloatLit .. nnkFloat128Lit:
      result["kind"] = %"literal"
      result["literal"] = astLiteral(node)
    else:
      result["kind"] = %"expression"
      result["children"] = newJArray()
      for child in node:
        result["children"].add astToPlanJson(child)
      let literal = astLiteral(node)
      if literal.kind != JNull:
        result["literal"] = literal

  if not isIdentifier(fragmentName):
    error("O nome do fragmento deve ser um identificador.", fragmentName)

  let fragmentJson = astToPlanJson(body)
  let exportedFragmentName = postfix(fragmentName.copyNimTree, "*")
  let fragmentLiteral = macros.newLit($fragmentJson)
  result = newStmtList()
  result.add quote do:
    const `exportedFragmentName` = `fragmentLiteral`

# -----------------------------------------------------------------------------
# Macro narrativa única
# -----------------------------------------------------------------------------

macro glaucoplastic*(arguments: varargs[untyped]): untyped =
  ## Recebe a invocação como AST bruto e normaliza as formas aceitas pelo
  ## parser do Nim. Isto evita que o binder de uma assinatura fixa preencha
  ## o argumento intermediário com `nnkNilLit` na forma de comando:
  ##
  ##   glaucoplastic ConsumerApplication, application:
  ##     ...
  ##
  ## A expansão trabalha somente com NimNode; nenhum código é reanalisado
  ## por texto.
  proc isIdentifier(node: NimNode): bool =
    not node.isNil and node.kind in {nnkIdent, nnkSym}

  proc isStatementBody(node: NimNode): bool =
    not node.isNil and node.kind == nnkStmtList

  proc isMissingArgument(node: NimNode): bool =
    node.isNil or node.kind in {nnkEmpty, nnkNilLit}

  proc unpackVariableAndBody(
    node: NimNode;
    variableNode: var NimNode;
    bodyNode: var NimNode
  ): bool =
    ## Algumas versões/contextos do parser agrupam `application:` e o bloco
    ## em um único nó. Essa forma é equivalente aos dois argumentos separados.
    if node.isNil:
      return false

    case node.kind
    of nnkCall, nnkCommand:
      if node.len >= 2 and
          isIdentifier(node[0]) and
          isStatementBody(node[^1]):
        variableNode = node[0].copyNimTree
        bodyNode = node[^1].copyNimTree
        return true

    of nnkExprColonExpr:
      if node.len == 2 and
          isIdentifier(node[0]) and
          isStatementBody(node[1]):
        variableNode = node[0].copyNimTree
        bodyNode = node[1].copyNimTree
        return true

    else:
      discard

    false

  var applicationName: NimNode
  var applicationVariable: NimNode
  var body: NimNode

  when defined(glaucoplasticAstDebug):
    echo "[glaucoplastic] argumentos brutos:"
    echo arguments.treeRepr

  case arguments.len
  of 3:
    applicationName = arguments[0].copyNimTree

    if isIdentifier(arguments[1]) and isStatementBody(arguments[2]):
      applicationVariable = arguments[1].copyNimTree
      body = arguments[2].copyNimTree

    elif isMissingArgument(arguments[1]) and
        unpackVariableAndBody(arguments[2], applicationVariable, body):
      discard

    else:
      error(
        "Invocação inválida. Use: glaucoplastic ConsumerApplication, application: <bloco>",
        arguments
      )

  of 2:
    applicationName = arguments[0].copyNimTree

    if not unpackVariableAndBody(
        arguments[1],
        applicationVariable,
        body
      ):
      error(
        "O segundo argumento deve declarar a variável e conter o bloco da aplicação.",
        arguments[1]
      )

  else:
    error(
      "glaucoplastic espera o nome da aplicação, a variável e o bloco declarativo.",
      arguments
    )

  if not isIdentifier(applicationName):
    error("O nome da aplicação deve ser um identificador.", applicationName)

  if not isIdentifier(applicationVariable):
    error("A variável da aplicação deve ser um identificador.", applicationVariable)

  if not isStatementBody(body):
    error("O corpo da aplicação deve ser um bloco Nim.", body)

  when defined(glaucoplasticAstDebug):
    echo "[glaucoplastic] nome normalizado:"
    echo applicationName.treeRepr
    echo "[glaucoplastic] variável normalizada:"
    echo applicationVariable.treeRepr
    echo "[glaucoplastic] corpo normalizado:"
    echo body.treeRepr

  # Símbolos internos do runtime de estados. Os nomes públicos `get` e `set`
  # possuem muitos concorrentes no ambiente semântico do módulo consumidor
  # (`Option.get`, `HttpClient.get`, `system.set`, entre outros). As closures
  # geradas usam símbolos higiênicos; `get*` e `set*` permanecem como wrappers
  # da API pública do GlaucoPlastic.
  let stateGetInternalSym =
    genSym(nskProc, "glaucoplasticStateGet")
  let stateSetInternalSym =
    genSym(nskProc, "glaucoplasticStateSet")
  let stateSetPathInternalSym =
    genSym(nskProc, "glaucoplasticStateSetPath")

  proc astLiteral(node: NimNode): JsonNode =
    case node.kind
    of nnkPrefix:
      if node.len == 2 and node[0].repr in ["%", "%*"]:
        return astLiteral(node[1])
      result = newJNull()
    of nnkPar:
      if node.len == 1:
        return astLiteral(node[0])
      result = newJNull()
    of nnkTableConstr:
      proc literalKeyName(keyNode: NimNode): string =
        case keyNode.kind
        of nnkIdent, nnkSym, nnkAccQuoted:
          result = keyNode.repr
        of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
          result = keyNode.strVal
        else:
          result = keyNode.repr

      result = newJObject()
      for child in node:
        if child.kind == nnkExprColonExpr:
          let key = literalKeyName(child[0])
          if key.len > 0:
            result[key] = astLiteral(child[1])
    of nnkBracket:
      result = newJArray()
      for child in node:
        result.add astLiteral(child)
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      result = %node.strVal
    of nnkIntLit .. nnkUInt64Lit:
      result = %node.intVal
    of nnkFloatLit .. nnkFloat128Lit:
      result = %node.floatVal
    of nnkIdent:
      case node.strVal
      of "true":
        result = %true
      of "false":
        result = %false
      of "nil":
        result = newJNull()
      else:
        result = newJNull()
    else:
      result = newJNull()

  proc astDslName(node: NimNode): string =
    ## Produz o nome semântico da DSL. Identificadores escapados, como
    ## `` `div` ``, são normalizados para "div".
    case node.kind
    of nnkIdent, nnkSym:
      result = node.strVal
    of nnkAccQuoted:
      for child in node:
        result.add astDslName(child)
    else:
      let raw = node.repr
      if raw.len >= 2 and raw[0] == '`' and raw[^1] == '`':
        result = raw[1 .. ^2]
      else:
        result = raw

  proc callBaseAst(node: NimNode): NimNode
  proc rawCallArgumentsAst(node: NimNode): seq[NimNode]
  proc callArgumentsAst(node: NimNode): seq[NimNode]
  proc callBodyAst(node: NimNode): NimNode
  proc astToPlanJson(node: NimNode): JsonNode

  proc astChildrenJson(node: NimNode; startIndex, endIndex: int): JsonNode =
    result = newJArray()
    if endIndex <= startIndex:
      return
    for index in startIndex ..< endIndex:
      result.add astToPlanJson(node[index])

  proc astToPlanJson(node: NimNode): JsonNode =
    result = newJObject()
    result["source"] = %node.repr
    result["astKind"] = %($node.kind)

    case node.kind
    of nnkStmtList:
      result["kind"] = %"root"
      result["children"] = astChildrenJson(node, 0, node.len)

    of nnkCall, nnkCommand:
      result["kind"] = %"call"

      var callName = astDslName(callBaseAst(node))
      if callName == "divi":
        callName = "div"

      let arguments = newJArray()
      for argument in callArgumentsAst(node):
        arguments.add astToPlanJson(argument)

      let bodyNode = callBodyAst(node)

      result["name"] = %callName
      result["arguments"] = arguments
      result["children"] =
        if bodyNode.kind == nnkStmtList:
          astChildrenJson(bodyNode, 0, bodyNode.len)
        else:
          newJArray()

    of nnkExprEqExpr:
      let argumentName = astDslName(node[0])
      result["kind"] = %"namedArgument"
      result["name"] = %argumentName
      result["value"] = astToPlanJson(node[1])

    of nnkInfix:
      if node.len == 3 and astDslName(node[0]) == "isset":
        result["kind"] = %"assignment"
        result["left"] = astToPlanJson(node[1])
        result["value"] = astToPlanJson(node[2])
        result["name"] = %node[1].repr.splitWhitespace()[0]
      else:
        result["kind"] = %"expression"
        result["children"] = astChildrenJson(node, 0, node.len)

    of nnkAsgn:
      result["kind"] = %"assignment"
      result["left"] = astToPlanJson(node[0])
      result["value"] = astToPlanJson(node[1])
      result["name"] = %node[0].repr.splitWhitespace()[0]

    of nnkWhenStmt:
      result["kind"] = %"when"
      result["children"] = astChildrenJson(node, 0, node.len)

    of nnkElifBranch:
      result["kind"] = %"whenBranch"
      result["condition"] = astToPlanJson(node[0])
      result["children"] = astChildrenJson(node[1], 0, node[1].len)

    of nnkElse:
      result["kind"] = %"whenElse"
      result["children"] = astChildrenJson(node[0], 0, node[0].len)

    of nnkTableConstr:
      result["kind"] = %"map"
      result["children"] = astChildrenJson(node, 0, node.len)

    of nnkExprColonExpr:
      result["kind"] = %"mapEntry"
      result["name"] = %astDslName(node[0])
      result["value"] = astToPlanJson(node[1])

    of nnkDotExpr:
      result["kind"] = %"path"
      result["name"] = %node.repr
      result["children"] = astChildrenJson(node, 0, node.len)

    of nnkIdent, nnkSym:
      result["kind"] = %"identifier"
      result["name"] = %node.strVal
      let literal = astLiteral(node)
      if literal.kind != JNull or node.strVal == "nil":
        result["literal"] = literal

    of nnkStrLit, nnkRStrLit, nnkTripleStrLit,
       nnkIntLit .. nnkUInt64Lit,
       nnkFloatLit .. nnkFloat128Lit:
      result["kind"] = %"literal"
      result["literal"] = astLiteral(node)

    else:
      result["kind"] = %"expression"
      result["children"] = astChildrenJson(node, 0, node.len)
      let literal = astLiteral(node)
      if literal.kind != JNull:
        result["literal"] = literal


  proc astPath(node: NimNode): seq[string] =
    case node.kind
    of nnkIdent, nnkSym:
      result.add node.strVal
    of nnkAccQuoted:
      result.add astDslName(node)
    of nnkDotExpr:
      for child in node:
        result.add astPath(child)
    else:
      discard

  proc callBaseAst(node: NimNode): NimNode =
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return newEmptyNode()
    if node[0].kind in {nnkCall, nnkCommand}:
      return callBaseAst(node[0])
    node[0]

  proc rawCallArgumentsAst(node: NimNode): seq[NimNode] =
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return
    if node[0].kind in {nnkCall, nnkCommand}:
      result.add rawCallArgumentsAst(node[0])
    let hasBody = node.len > 1 and node[^1].kind == nnkStmtList
    let argumentEnd = if hasBody: node.len - 1 else: node.len
    for index in 1 ..< argumentEnd:
      result.add node[index]

  proc callArgumentsAst(node: NimNode): seq[NimNode] =
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return

    # O parser pode empilhar nnkCall/nnkCommand no callee. Conservamos os
    # argumentos dessas camadas antes de ler a camada exterior.
    if node[0].kind in {nnkCall, nnkCommand}:
      result.add callArgumentsAst(node[0])

    let hasDirectBody = node.len > 1 and node[^1].kind == nnkStmtList
    let argumentEnd = if hasDirectBody: node.len - 1 else: node.len
    var argumentStart = 1

    # Formas aceitas pelo parser para a identidade posicional:
    #
    #   button Ir(type = "button") "Ir"
    #   foreign Portal(url = ...)
    #
    # Em uma delas, `Ir(...)`/`Portal(...)` é o primeiro argumento externo;
    # em outra, há mais uma camada de nnkCommand. `callBaseAst` remove essas
    # camadas sem converter o código em texto.
    if node.kind == nnkCommand and argumentEnd > 1 and
        node[1].kind in {nnkCall, nnkCommand}:
      let identityBase = callBaseAst(node[1])
      if identityBase.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
        result.add identityBase
        result.add callArgumentsAst(node[1])
        argumentStart = 2

    for index in argumentStart ..< argumentEnd:
      result.add node[index]

  proc callBodyAst(node: NimNode): NimNode =
    ## Encontra o bloco associado a uma chamada independentemente da
    ## quantidade de camadas nnkCall/nnkCommand produzidas pelo parser.
    ##
    ## A implementação anterior só verificava o último filho e node[1]. Isso
    ## alcançava `main Root(...)`, mas podia perder os corpos aninhados de
    ## `nav Navegacao(...)` e, consequentemente, `button Voltar(...)`.
    if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
      return newEmptyNode()

    # Primeiro procura um corpo diretamente anexado a esta camada.
    for index in countdown(node.len - 1, 0):
      if node[index].kind == nnkStmtList:
        return node[index]

    # Depois atravessa somente wrappers de chamada/comando. Argumentos
    # nomeados e seus valores não são percorridos como estrutura visual.
    for index in countdown(node.len - 1, 0):
      if node[index].kind in {nnkCall, nnkCommand}:
        let nestedBody = callBodyAst(node[index])
        if nestedBody.kind == nnkStmtList:
          return nestedBody

    newEmptyNode()

  proc callNameAst(node: NimNode): string =
    let base = callBaseAst(node)
    if base.kind == nnkEmpty:
      return ""
    let path = astPath(base)
    if path.len > 0:
      path.join(".")
    else:
      astDslName(base)

  proc namedArgumentAst(node: NimNode; name: string): NimNode =
    for argument in callArgumentsAst(node):
      if argument.kind == nnkExprEqExpr and
          astDslName(argument[0]).cmpIgnoreCase(name) == 0:
        return argument[1]
    newEmptyNode()

  proc literalNameAst(node: NimNode): string =
    case node.kind
    of nnkIdent, nnkSym, nnkAccQuoted:
      astDslName(node)
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      node.strVal
    else:
      node.repr

  proc statePathAst(node: NimNode): string =
    ## Reconhece somente acessos que declaram explicitamente a raiz DSL:
    ##
    ##   states.Search.query
    ##   state.Search.query
    ##
    ## `stateAccessPathAst` também é usado para normalizar alvos e, por
    ## compatibilidade, aceita representações textuais amplas. Ele não pode ser
    ## usado aqui para decidir se um valor é um estado, pois literais como
    ## `1`, `"texto"` e expressões como `url & query` também produzem tokens e
    ## acabavam resolvidos como caminhos inexistentes, retornando JNull.
    let path = astPath(node)
    if path.len > 1 and path[0] in ["state", "states"]:
      return path[1 .. ^1].join(".")
    ""

  proc normalizedUiEventName(eventName: string): string =
    ## Normaliza a sintaxe declarativa dos componentes (`when Ir clicks:`).
    case eventName.toLowerAscii
    of "onclick", "click", "clicks", "clicked": "click"
    of "onchange", "change", "changes": "change"
    of "oninput", "input", "inputs": "input"
    of "onblur", "blur", "blurs": "blur"
    of "onfocus", "focus", "focuses", "focused": "focus"
    of "onenter", "enter", "enters": "enter"
    of "onconnected", "connected", "connect", "connecteds": "connected"
    else: ""

  proc positionalIdentityAst(node: NimNode): string =
    ## A identidade declarativa é o primeiro argumento posicional:
    ##
    ##   button Ir(type = "button") "Ir"
    ##   foreign Portal(url = binds states.Url)
    ##
    ## O argumento pode chegar como identificador ou como callee de uma
    ## chamada aninhada (`Ir(...)`). Nenhuma forma textual é reanalisada.
    for argument in callArgumentsAst(node):
      if argument.kind == nnkExprEqExpr:
        continue

      case argument.kind
      of nnkIdent, nnkSym, nnkAccQuoted:
        return literalNameAst(argument)

      of nnkCall, nnkCommand:
        let identityBase = callBaseAst(argument)
        if identityBase.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
          return literalNameAst(identityBase)
        return ""

      else:
        # O primeiro argumento posicional é conteúdo/valor, logo o elemento
        # não declarou identidade.
        return ""

    ""

  proc validateComponentSyntax(node: NimNode) =
    ## Impede a convivência da sintaxe antiga com a identidade posicional.
    case node.kind
    of nnkCall, nnkCommand:
      for argument in callArgumentsAst(node):
        if argument.kind != nnkExprEqExpr:
          continue
        let argumentName = astDslName(argument[0])
        if argumentName.cmpIgnoreCase("part") == 0:
          error(
            "`part = ...` foi removido. Declare a identidade após o elemento, " &
            "por exemplo: `button Ir(type = \"button\") \"Ir\"`.",
            argument
          )
        if normalizedUiEventName(argumentName).len > 0:
          error(
            "Handlers inline foram removidos. Use `when <Identidade> <evento>:` " &
            "no corpo do componente.",
            argument
          )

      if callNameAst(node) == "foreign" and positionalIdentityAst(node).len == 0:
        error(
          "`foreign` exige uma identidade posicional, por exemplo: " &
          "`portal = foreign Portal(url = ...)`.",
          node
        )

      let bodyNode = callBodyAst(node)
      if bodyNode.kind == nnkStmtList:
        for child in bodyNode:
          validateComponentSyntax(child)

    of nnkAsgn:
      if node.len == 2:
        validateComponentSyntax(node[1])

    of nnkStmtList, nnkIfStmt, nnkWhenStmt, nnkElifBranch, nnkElse:
      for child in node:
        validateComponentSyntax(child)

    else:
      discard

  proc collectRenderIdentities(
    node: NimNode;
    identities: var HashSet[string]
  ) =
    if node.kind in {nnkStmtList, nnkIfStmt, nnkWhenStmt, nnkElifBranch, nnkElse}:
      for child in node:
        collectRenderIdentities(child, identities)
      return

    if node.kind notin {nnkCall, nnkCommand}:
      return

    let identity = positionalIdentityAst(node)
    if identity.len > 0:
      identities.incl(identity)

    let bodyNode = callBodyAst(node)
    if bodyNode.kind == nnkStmtList:
      for child in bodyNode:
        collectRenderIdentities(child, identities)

  proc whenConditionAst(
    node: NimNode
  ): tuple[subject: string, eventName: string, body: NimNode] =
    if node.kind != nnkWhenStmt or node.len == 0:
      return
    let branch = node[0]
    if branch.kind != nnkElifBranch or branch.len < 2:
      return

    let condition = branch[0]
    result.body = branch[1]

    if condition.kind in {nnkCall, nnkCommand}:
      result.subject = callNameAst(condition)
      let arguments = callArgumentsAst(condition)
      if arguments.len > 0:
        result.eventName = literalNameAst(arguments[0])
      return

    let conditionPath = astPath(condition)
    if conditionPath.len > 0:
      result.subject = conditionPath.join(".")

  proc changesEffectAst(
    node: NimNode
  ): tuple[found: bool, valueNode, targetNode: NimNode] =
    ## Normaliza as formas AST possíveis para:
    ##
    ##   eventValue changes states.UrlDigitada
    ##   states.UrlDigitada changes states.Url
    ##
    ## Como `changes` é um identificador, o parser Nim pode representar a
    ## expressão como nnkCommand/nnkCall, e não como nnkInfix. O macro
    ## reconhece todas as formas sem converter código Nim em texto.
    if node.kind == nnkInfix and node.len == 3 and
        astDslName(node[0]) == "changes":
      return (true, node[1], node[2])

    if node.kind notin {nnkCall, nnkCommand}:
      return (false, newEmptyNode(), newEmptyNode())

    let directArguments = rawCallArgumentsAst(node)

    # Forma funcional ou operador escapado:
    #   changes(valor, states.Destino)
    if callNameAst(node) == "changes" and directArguments.len >= 2:
      return (true, directArguments[0], directArguments[1])

    let leftNode = callBaseAst(node)
    if leftNode.kind == nnkEmpty:
      return (false, newEmptyNode(), newEmptyNode())

    # Forma de comando plana produzida por algumas versões do parser:
    #   Command(eventValue, changes, states.UrlDigitada)
    if directArguments.len >= 2 and
        astDslName(directArguments[0]) == "changes":
      return (true, leftNode, directArguments[1])

    # Forma de comando aninhada:
    #   Command(eventValue, Command(changes, states.UrlDigitada))
    if directArguments.len >= 1 and
        directArguments[0].kind in {nnkCall, nnkCommand} and
        callNameAst(directArguments[0]) == "changes":
      let nestedArguments = rawCallArgumentsAst(directArguments[0])
      if nestedArguments.len >= 1:
        return (true, leftNode, nestedArguments[0])

    # Forma em que o parser mantém `changes` e o destino em wrappers
    # consecutivos no callee. `callArgumentsAst` achata essas camadas.
    let normalizedArguments = callArgumentsAst(node)
    if normalizedArguments.len >= 2 and
        astDslName(normalizedArguments[0]) == "changes":
      return (true, leftNode, normalizedArguments[1])

    (false, newEmptyNode(), newEmptyNode())

  proc containsEventPseudoValue(node: NimNode): bool =
    if node.kind in {nnkIdent, nnkSym} and
        node.strVal in ["eventValue", "eventChecked", "eventKey"]:
      return true
    for child in node:
      if containsEventPseudoValue(child):
        return true

  proc compileJsonValue(
    node: NimNode;
    eventSymbol: NimNode
  ): NimNode =
    if node.kind in {nnkCall, nnkCommand} and
        callNameAst(node) == "%":
      let arguments = rawCallArgumentsAst(node)
      if arguments.len == 0:
        error("Use `% valor` com um valor válido.", node)
      return compileJsonValue(arguments[0], eventSymbol)

    if node.kind == nnkPrefix and node.len == 2:
      let operatorName = node[0].repr
      if operatorName == "%":
        return compileJsonValue(node[1], eventSymbol)

    if node.kind in {nnkCall, nnkCommand} and
        callNameAst(node) == "buildYouTubeSearchUrl":
      let arguments = rawCallArgumentsAst(node)
      if arguments.len == 0:
        error("buildYouTubeSearchUrl exige um termo de busca.", node)
      let queryJson = compileJsonValue(arguments[0], eventSymbol)
      return quote do:
        plasticJson(buildYouTubeSearchUrl(jsonText(`queryJson`)))

    if node.kind in {nnkCall, nnkCommand} and
        callNameAst(node) in ["state", "states"]:
      let arguments = rawCallArgumentsAst(node)
      if arguments.len == 0:
        error("Use `state Nome` ou `state Nome.propriedade`.", node)
      if arguments.len >= 3 and
          astDslName(arguments[1]) in ["+", "-", "*", "/"]:
        let leftValue = buildStateAccessExpr(applicationVariable.copyNimTree, arguments[0])
        let rightValue = compileJsonValue(arguments[2], eventSymbol)
        let operatorName = astDslName(arguments[1])
        let operatorLiteral = newLit(operatorName)
        return quote do:
          case `operatorLiteral`
          of "+":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) +
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "-":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) -
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "*":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) *
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "/":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) div
              max(1, glaucoplasticJsonIntValue(`rightValue`))
            )
          else:
            newJNull()
      return buildStateAccessExpr(applicationVariable.copyNimTree, arguments[0])

    if node.kind == nnkInfix and node.len == 3:
      let operatorName = astDslName(node[0])
      if operatorName in ["+", "-", "*", "/"]:
        let leftValue = compileJsonValue(node[1], eventSymbol)
        let rightValue = compileJsonValue(node[2], eventSymbol)
        let operatorLiteral = newLit(operatorName)
        return quote do:
          case `operatorLiteral`
          of "+":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) +
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "-":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) -
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "*":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) *
              glaucoplasticJsonIntValue(`rightValue`)
            )
          of "/":
            plasticJson(
              glaucoplasticJsonIntValue(`leftValue`) div
              max(1, glaucoplasticJsonIntValue(`rightValue`))
            )
          else:
            newJNull()

    if node.kind in {nnkCall, nnkCommand} and node.len >= 3:
      let operatorName = astDslName(callBaseAst(node))
      if operatorName in ["+", "-", "*", "/"]:
        let arguments = rawCallArgumentsAst(node)
        if arguments.len >= 2:
          let leftValue = compileJsonValue(arguments[0], eventSymbol)
          let rightValue = compileJsonValue(arguments[1], eventSymbol)
          let operatorLiteral = newLit(operatorName)
          return quote do:
            case `operatorLiteral`
            of "+":
              plasticJson(
                glaucoplasticJsonIntValue(`leftValue`) +
                glaucoplasticJsonIntValue(`rightValue`)
              )
            of "-":
              plasticJson(
                glaucoplasticJsonIntValue(`leftValue`) -
                glaucoplasticJsonIntValue(`rightValue`)
              )
            of "*":
              plasticJson(
                glaucoplasticJsonIntValue(`leftValue`) *
                glaucoplasticJsonIntValue(`rightValue`)
              )
            of "/":
              plasticJson(
                glaucoplasticJsonIntValue(`leftValue`) div
                max(1, glaucoplasticJsonIntValue(`rightValue`))
              )
            else:
              newJNull()

    if node.kind in {nnkIdent, nnkSym} and node.strVal == "eventValue":
      if eventSymbol.kind == nnkEmpty:
        error("eventValue só pode ser usado dentro de um evento visual.", node)
      return quote do:
        `eventSymbol`.value.copy

    if node.kind in {nnkIdent, nnkSym} and node.strVal == "eventChecked":
      if eventSymbol.kind == nnkEmpty:
        error("eventChecked só pode ser usado dentro de um evento visual.", node)
      return quote do:
        plasticJson(`eventSymbol`.checked)

    let stateName = statePathAst(node)
    if stateName.len > 0:
      let stateLiteral = newLit(stateName)
      return quote do:
        glaucoplasticResolveStatePathText(
          `applicationVariable`.statesValue,
          `stateLiteral`
        )

    if node.kind in {nnkCall, nnkCommand, nnkDotExpr, nnkIdent, nnkSym, nnkAccQuoted}:
      let path = astPath(node)
      if path.len > 0 and path[0] in ["state", "states"] and path.len > 1:
        let stateLiteral = newLit(path[1 .. ^1].join("."))
        return quote do:
          glaucoplasticResolveStatePathText(
            `applicationVariable`.statesValue,
            `stateLiteral`
          )

    let valueNode = node.copyNimTree
    result = quote do:
      plasticJson(`valueNode`)

  proc compileTextValue(
    node: NimNode;
    eventSymbol: NimNode
  ): NimNode =
    let jsonValue = compileJsonValue(node, eventSymbol)
    result = quote do:
      jsonText(`jsonValue`)

  proc compileEffect(
    node: NimNode;
    aliases: Table[string, string];
    eventSymbol: NimNode
  ): NimNode =
    proc rewriteStateSyntax(node: NimNode): NimNode =
      if node.kind in {nnkCall, nnkCommand} and
          callNameAst(node) in ["state", "states"]:
        let arguments = rawCallArgumentsAst(node)
        if arguments.len == 1 and arguments[0].kind == nnkExprEqExpr:
          let target = arguments[0][0]
          let value = rewriteStateSyntax(arguments[0][1])
          return buildStateAssignmentExpr(
            applicationVariable.copyNimTree,
            target,
            value
          )

        if arguments.len == 1:
          return buildStateAccessExpr(applicationVariable.copyNimTree, arguments[0])

        if arguments.len == 2:
          return buildStateAssignmentExpr(
            applicationVariable.copyNimTree,
            arguments[0],
            rewriteStateSyntax(arguments[1])
          )

      result = node.copyNimTree
      for index in 0 ..< result.len:
        result[index] = rewriteStateSyntax(result[index])

    let rewrittenNode = rewriteStateSyntax(node)

    if rewrittenNode.kind in {
      nnkStmtList,
      nnkStmtListExpr,
      nnkIfStmt,
      nnkElifBranch,
      nnkElse,
      nnkCaseStmt,
      nnkOfBranch,
      nnkBlockStmt,
      nnkWhileStmt,
      nnkForStmt,
      nnkTryStmt,
      nnkFinally,
      nnkExceptBranch
    }:
      result = rewrittenNode.copyNimTree
      for index in 0 ..< result.len:
        result[index] = compileEffect(result[index], aliases, eventSymbol)
      return

    proc emitForeignOperation(
      foreignPath: string;
      operation: string;
      arguments: seq[NimNode];
      returnValue: bool = false
    ): NimNode =
      let foreignPathLiteral = newLit(foreignPath)
      case operation
      of "evalJs", "evalsJs", "javascript", "executeScript":
        if arguments.len == 0:
          error(operation & " exige um script.", node)
        let script = compileTextValue(arguments[0], eventSymbol)
        if returnValue:
          result = quote do:
            `applicationVariable`.foreignValue.evalJs(
              `foreignPathLiteral`,
              `script`
            )
        else:
          result = quote do:
            discard `applicationVariable`.foreignValue.evalJs(
              `foreignPathLiteral`,
              `script`
            )
      of "navigate", "open", "go":
        if arguments.len == 0:
          error(operation & " exige uma URL.", node)
        let target = compileTextValue(arguments[0], eventSymbol)
        result = quote do:
          `applicationVariable`.foreignValue.navigate(
            `foreignPathLiteral`,
            `target`
          )
      of "goBack", "back":
        result = quote do:
          `applicationVariable`.foreignValue.goBack(`foreignPathLiteral`)
      of "goForward", "forward":
        result = quote do:
          `applicationVariable`.foreignValue.goForward(`foreignPathLiteral`)
      of "reload", "refresh":
        result = quote do:
          `applicationVariable`.foreignValue.reload(`foreignPathLiteral`)
      else:
        result = newEmptyNode()

    proc foreignOperationFromNode(node: NimNode): tuple[found: bool, foreignPath: string, operation: string, arguments: seq[NimNode]] =
      if node.kind notin {nnkCall, nnkCommand} or node.len == 0:
        return

      proc operationName(node: NimNode): string =
        if node.kind in {nnkCall, nnkCommand}:
          result = astDslName(callBaseAst(node))
        else:
          result = astDslName(node)

      if node[0].kind == nnkInfix and node[0].len == 3 and
          astDslName(node[0][0]) == "in":
        let operation = astDslName(node[0][1])
        let foreignNode = node[0][2]
        let foreignPathText = astPath(foreignNode)
        if foreignPathText.len < 2:
          error(
            "O destino do `in` deve ser uma foreign declarada, como Home.Portal.",
            foreignNode
          )
        return (true, foreignPathText.join("."), operation, rawCallArgumentsAst(node))

      let foreignPathText = astPath(callBaseAst(node))
      if foreignPathText.len < 2:
        return

      let arguments = rawCallArgumentsAst(node)
      if arguments.len == 0:
        return

      let operation = operationName(arguments[0])
      if operation notin ["evalJs", "evalsJs", "javascript", "executeScript",
                          "navigate", "open", "go",
                          "goBack", "back", "goForward", "forward",
                          "reload", "refresh"]:
        return

      let trailingArguments =
        if arguments[0].kind in {nnkCall, nnkCommand}:
          rawCallArgumentsAst(arguments[0])
        elif arguments.len > 1:
          arguments[1 .. ^1]
        else:
          @[]

      return (true, foreignPathText.join("."), operation, trailingArguments)

    let changesEffect = changesEffectAst(rewrittenNode)
    if changesEffect.found:
      let targetState = stateAccessPathAst(changesEffect.targetNode)
      if targetState.len == 0:
        error(
          "O destino de `changes` deve ser um estado válido.",
          changesEffect.targetNode
        )
      let targetLiteral = buildStringSeqLiteral(targetState)
      let valueExpression = compileJsonValue(
        changesEffect.valueNode,
        eventSymbol
      )
      return newCall(
        ident("glaucoplasticStateSetPathInternal"),
        newDotExpr(applicationVariable.copyNimTree, ident("statesValue")),
        targetLiteral,
        valueExpression
      )

    if rewrittenNode.kind == nnkAsgn and rewrittenNode.len == 2:
      # Uma avaliação JavaScript pode retornar um JsonNode para uma variável
      # local já declarada dentro do listener:
      #
      #   var preview = newJNull()
      #   preview = Home.Portal evalJs script
      #
      # Declarações `let`/`var` já eram tratadas abaixo, mas reatribuições
      # passavam por compileJsonValue e deixavam `Home` escapar como símbolo
      # Nim comum. Normalize o RHS antes de tratar estados/propriedades.
      let assignedForeign = foreignOperationFromNode(rewrittenNode[1])
      if assignedForeign.found and
          assignedForeign.operation in [
            "evalJs", "evalsJs", "javascript", "executeScript"
          ]:
        let target = rewrittenNode[0].copyNimTree
        let evaluated = emitForeignOperation(
          assignedForeign.foreignPath,
          assignedForeign.operation,
          assignedForeign.arguments,
          true
        )
        return newTree(nnkAsgn, target, evaluated)

      let targetPath = astPath(rewrittenNode[0])
      let valueExpression = compileJsonValue(rewrittenNode[1], eventSymbol)

      if targetPath.len >= 2 and targetPath[0] in ["state", "states"]:
        let targetLiteral = newTree(nnkBracket)
        for part in targetPath[1 .. ^1]:
          targetLiteral.add newLit(part)
        return newCall(
          ident("glaucoplasticStateSetPathInternal"),
          newDotExpr(applicationVariable.copyNimTree, ident("statesValue")),
          targetLiteral,
          valueExpression
        )

      if targetPath.len >= 3:
        let visualPath = newLit(targetPath[0 .. ^2].join("."))
        let propertyName = newLit(targetPath[^1])
        return quote do:
          `applicationVariable`.updateUiProperty(
            `visualPath`,
            `propertyName`,
            `valueExpression`
          )

    if rewrittenNode.kind in {nnkLetSection, nnkVarSection}:
      result = rewrittenNode.copyNimTree
      for index in 0 ..< result.len:
        let declaration = result[index]
        if declaration.kind != nnkIdentDefs or declaration.len < 3:
          continue
        let initIndex = declaration.len - 1
        let initNode = declaration[initIndex]
        let foreignSpec = foreignOperationFromNode(initNode)
        if foreignSpec.found:
          if foreignSpec.operation in ["evalJs", "evalsJs", "javascript", "executeScript"]:
            declaration[initIndex] =
              emitForeignOperation(
                foreignSpec.foreignPath,
                foreignSpec.operation,
                foreignSpec.arguments,
                true
              )
      return result

    if rewrittenNode.kind in {nnkCall, nnkCommand}:
      let foreignSpec = foreignOperationFromNode(rewrittenNode)
      if foreignSpec.found:
        return emitForeignOperation(
          foreignSpec.foreignPath,
          foreignSpec.operation,
          foreignSpec.arguments
        )

      var operationPath = astPath(callBaseAst(rewrittenNode))
      if operationPath.len >= 3:
        let qualifiedHandle = operationPath[0] & "." & operationPath[1]
        if aliases.hasKey(qualifiedHandle):
          let expanded = aliases[qualifiedHandle].split(".")
          operationPath = expanded & operationPath[2 .. ^1]
      if operationPath.len >= 2 and aliases.hasKey(operationPath[0]):
        let expanded = aliases[operationPath[0]].split(".")
        operationPath = expanded & operationPath[1 .. ^1]

      if operationPath.len >= 3:
        let operation = operationPath[^1]
        let foreignPath = newLit(operationPath[0 .. ^2].join("."))
        let arguments = rawCallArgumentsAst(rewrittenNode)

        case operation
        of "goBack", "back":
          return quote do:
            `applicationVariable`.foreignValue.goBack(`foreignPath`)
        of "goForward", "forward":
          return quote do:
            `applicationVariable`.foreignValue.goForward(`foreignPath`)
        of "reload", "refresh":
          return quote do:
            `applicationVariable`.foreignValue.reload(`foreignPath`)
        of "navigate", "open", "go":
          if arguments.len == 0:
            error(operation & " exige uma URL.", rewrittenNode)
          let target = compileTextValue(arguments[0], eventSymbol)
          return quote do:
            `applicationVariable`.foreignValue.navigate(
              `foreignPath`,
              `target`
            )
        of "evalJs", "javascript", "executeScript":
          if arguments.len == 0:
            error(operation & " exige um script.", rewrittenNode)
          let script = compileTextValue(arguments[0], eventSymbol)
          return quote do:
            discard `applicationVariable`.foreignValue.evalJs(
              `foreignPath`,
              `script`
            )
        else:
          discard

    if eventSymbol.kind != nnkEmpty and containsEventPseudoValue(rewrittenNode):
      error(
        "O evento visual contém um valor especial que não foi normalizado " &
        "pelo macro. AST recebido: " & node.treeRepr,
        rewrittenNode
      )

    result = rewrittenNode.copyNimTree

  proc astLiteralOrNull(node: NimNode): JsonNode = astLiteral(node)

  proc stateDeclarationInfo(
    declaration: NimNode
  ): tuple[name: string, initial: JsonNode, descriptor: JsonNode] =
    result.descriptor = astToPlanJson(declaration)
    result.initial = newJNull()

    if declaration.kind == nnkInfix and declaration.len == 3 and
        astDslName(declaration[0]) == "isset":
      let leftPath = astPath(declaration[1])
      if leftPath.len > 0:
        result.name = leftPath[^1]
      result.initial = astLiteralOrNull(declaration[2])
      return

    let kind =
      if result.descriptor.kind == JObject and
          result.descriptor.hasKey("kind"):
        result.descriptor["kind"].getStr
      else:
        ""

    if kind == "assignment":
      if result.descriptor.hasKey("name"):
        result.name = result.descriptor["name"].getStr
      if result.descriptor.hasKey("value") and
          result.descriptor["value"].kind == JObject and
          result.descriptor["value"].hasKey("literal"):
        result.initial = result.descriptor["value"]["literal"].copy
      return

    if kind != "call" or not result.descriptor.hasKey("name"):
      return

    result.name = result.descriptor["name"].getStr

    if result.descriptor.hasKey("arguments") and
        result.descriptor["arguments"].kind == JArray:
      for argument in result.descriptor["arguments"].items:
        if argument.kind == JObject and
            argument.hasKey("kind") and
            argument["kind"].getStr == "namedArgument" and
            argument.hasKey("value") and
            argument["value"].kind == JObject and
            argument["value"].hasKey("literal"):
          result.initial = argument["value"]["literal"].copy
          break

  proc collectComponentBindings(
    componentsSection: NimNode
  ): NimNode =
    result = newStmtList()
    var handlerCounter = 0
    let componentsBody = callBodyAst(componentsSection)
    if componentsBody.kind != nnkStmtList:
      return

    validateComponentSyntax(componentsSection)

    # Primeira passagem: registra todos os handles qualificados. Assim um
    # componente pode chamar `PortalWeb.portal.goBack()` e o macro resolve o
    # handle para a identidade `PortalWeb.Portal` ainda em compile-time.
    var qualifiedAliases = initTable[string, string]()
    for component in componentsBody:
      if component.kind notin {nnkCall, nnkCommand}:
        continue
      let componentName = callNameAst(component)
      let componentBody = callBodyAst(component)
      if componentName.len == 0 or componentBody.kind != nnkStmtList:
        continue

      for declaration in componentBody:
        if declaration.kind != nnkAsgn or declaration.len != 2:
          continue
        if callNameAst(declaration[1]) != "foreign":
          continue

        let handleName = literalNameAst(declaration[0])
        let identityName = positionalIdentityAst(declaration[1])
        if handleName.len == 0 or identityName.len == 0:
          continue

        qualifiedAliases[componentName & "." & handleName] =
          componentName & "." & identityName

    # Segunda passagem: compila listeners e efeitos de cada componente.
    for component in componentsBody:
      if component.kind notin {nnkCall, nnkCommand}:
        continue
      let componentName = callNameAst(component)
      let componentBody = callBodyAst(component)
      if componentName.len == 0 or componentBody.kind != nnkStmtList:
        continue

      var aliases = initTable[string, string]()
      for qualifiedHandle, identityPath in qualifiedAliases:
        aliases[qualifiedHandle] = identityPath

      var foreignTargets = initTable[string, string]()
      var renderIdentities = initHashSet[string]()

      for declaration in componentBody:
        if declaration.kind != nnkAsgn or declaration.len != 2:
          continue
        if callNameAst(declaration[1]) != "foreign":
          continue

        let handleName = literalNameAst(declaration[0])
        let identityName = positionalIdentityAst(declaration[1])
        if handleName.len == 0 or identityName.len == 0:
          continue

        let foreignPath = componentName & "." & identityName
        aliases[handleName] = foreignPath
        aliases[componentName & "." & handleName] = foreignPath
        foreignTargets[identityName] = foreignPath

      for declaration in componentBody:
        if declaration.kind in {nnkCall, nnkCommand} and
            callNameAst(declaration) == "render":
          let renderBody = callBodyAst(declaration)
          if renderBody.kind == nnkStmtList:
            for renderNode in renderBody:
              collectRenderIdentities(renderNode, renderIdentities)

      when defined(glaucoplasticAstDebug):
        echo "[glaucoplastic] identidades renderizadas em ", componentName, ":"
        for identityName in renderIdentities:
          echo "  - ", identityName

      for identityName, _ in foreignTargets:
        renderIdentities.incl(identityName)

      for declaration in componentBody:
        if declaration.kind != nnkWhenStmt:
          continue

        let condition = whenConditionAst(declaration)
        if condition.subject.len == 0 or condition.eventName.len == 0:
          continue

        if aliases.hasKey(condition.subject):
          error(
            "Eventos de foreign devem usar a identidade declarativa, não o handle Nim. " &
            "Use `when " &
            aliases[condition.subject].split('.')[^1] &
            " " & condition.eventName & ":`.",
            declaration
          )

        let foreignSubject =
          if condition.subject.startsWith(componentName & "."):
            condition.subject.split('.')[^1]
          else:
            condition.subject

        if foreignTargets.hasKey(foreignSubject):
          let normalizedForeignEvent = condition.eventName.toLowerAscii
          if normalizedForeignEvent notin [
              "loading", "loaded", "ready", "failed", "urlchanged"
            ]:
            error(
              "Evento de foreign desconhecido para `" & condition.subject &
              "`: " & condition.eventName,
              declaration
            )

          let foreignPath = newLit(foreignTargets[foreignSubject])
          let eventName = newLit(normalizedForeignEvent)
          let eventPathParameter = genSym(nskParam, "path")
          let eventNameParameter = genSym(nskParam, "eventName")
          let effect = compileEffect(
            condition.body,
            aliases,
            newEmptyNode()
          )
          result.add quote do:
            `applicationVariable`.registerForeignEventHandler(
              `foreignPath`,
              `eventName`,
              proc(
                `eventPathParameter`, `eventNameParameter`: string
              ) =
                `effect`
            )
          continue

        let normalizedEvent = normalizedUiEventName(condition.eventName)
        if normalizedEvent.len == 0:
          error(
            "Evento desconhecido para a identidade `" & condition.subject &
            "`: " & condition.eventName,
            declaration
          )

        let localIdentity =
          if condition.subject.startsWith(componentName & "."):
            condition.subject.split('.')[^1]
          elif condition.subject.contains("."):
            condition.subject.split('.')[^1]
          else:
            condition.subject

        if localIdentity notin renderIdentities:
          error(
            "A identidade `" & condition.subject &
            "` não foi declarada no render do componente `" &
            componentName & "`.",
            declaration
          )

        let visualPathText =
          if condition.subject.startsWith(componentName & "."):
            condition.subject
          elif condition.subject.contains("."):
            condition.subject
          else:
            componentName & "." & condition.subject

        inc handlerCounter
        let handlerId = newLit(
          visualPathText & "." & normalizedEvent & "." &
          $handlerCounter
        )
        let visualPath = newLit(visualPathText)
        let eventName = newLit(normalizedEvent)
        let eventParameter = genSym(nskParam, "event")
        let effect = compileEffect(
          condition.body,
          aliases,
          eventParameter
        )

        result.add quote do:
          `applicationVariable`.registerUiHandler(
            `handlerId`,
            proc(`eventParameter`: PlasticUiEvent) =
              `effect`
          )
          `applicationVariable`.bindUiHandler(
            `visualPath`,
            `eventName`,
            `handlerId`
          )

  proc collectStateBindings(statesSection: NimNode): NimNode =
    result = newStmtList()
    let statesBody = callBodyAst(statesSection)
    if statesBody.kind != nnkStmtList:
      return

    let noAliases = initTable[string, string]()

    for declaration in statesBody:
      if declaration.kind == nnkWhenStmt:
        let condition = whenConditionAst(declaration)
        let conditionPath = condition.subject.split(".")
        if conditionPath.len > 0 and condition.eventName == "changed":
          let stateName =
            if conditionPath[0] == "states" and conditionPath.len > 1:
              newLit(conditionPath[1])
            else:
              newLit(conditionPath[0])
          let changeParameter = genSym(nskParam, "change")
          let effect = compileEffect(
            condition.body,
            noAliases,
            newEmptyNode()
          )
          result.add quote do:
            `applicationVariable`.statesValue.onChanged(
              `stateName`,
              proc(`changeParameter`: PlasticStateChange) =
                `effect`
            )
        continue

      let info = stateDeclarationInfo(declaration)
      if info.name.len == 0:
        continue
      let stateName = newLit(info.name)
      let initialJson = newLit($info.initial)
      let descriptorJson = newLit($info.descriptor)
      result.add quote do:
        `applicationVariable`.statesValue.define(
          `stateName`,
          parseJson(`initialJson`)
        )
        `applicationVariable`.statesValue.descriptors.add(
          parseJson(`descriptorJson`)
        )

  result = newStmtList()
  let applicationNameLiteral = newLit(applicationName.repr)

  # Símbolos higiênicos para helpers gerados. Os nomes simples jsonString e
  # jsonInt colidem com campos do enum JsonEventKind de std/parsejson.
  let jsonStringFieldSym =
    genSym(nskProc, "glaucoplasticJsonStringField")
  let jsonBoolFieldSym =
    genSym(nskProc, "glaucoplasticJsonBoolField")
  let jsonIntFieldSym =
    genSym(nskProc, "glaucoplasticJsonIntField")

  result.add quote do:
    # Os helpers e operadores dinâmicos de PyObject (`.`, `.()`, `[]`)
    # precisam existir também no módulo consumidor, onde este código gerado é
    # semanticamente analisado. Importar nimpy apenas no módulo do framework
    # não coloca esses templates no escopo da expansão da macro.
    import nimpy
    import std/[algorithm, httpclient, json, options, os, osproc, sequtils, sets, strformat, strtabs, strutils, tables, times]

  # Runtime mínimo usado por closures visuais, agentes e ponte desktop.
  # É emitido antes das seções para que eventos declarados em `components`
  # possam ler e alterar estados mesmo quando a seção `states` aparece depois.
  result.add quote do:
    proc glaucoplasticStateResolveKey(
      states: PlasticStateRuntime;
      name: string
    ): string =
      if states.values.hasKey(name):
        return name
      for key in states.values.keys:
        if key.cmpIgnoreCase(name) == 0:
          return key
      ""

    proc glaucoplasticJsonObjectResolveKey(
      node: JsonNode;
      name: string
    ): string =
      if node.kind != JObject:
        return ""
      if node.hasKey(name):
        return name
      for key in node.keys:
        if key.cmpIgnoreCase(name) == 0:
          return key
      ""

    proc glaucoplasticStateGetPathInternal(
      states: PlasticStateRuntime;
      path: openArray[string]
    ): JsonNode

    proc glaucoplasticResolveStatePathText(
      states: PlasticStateRuntime;
      pathText: string
    ): JsonNode =
      let parts = pathText.split('.')
      if parts.len == 0:
        return newJNull()

      let startIndex =
        if parts[0] in ["state", "states"]:
          1
        else:
          0

      if parts.len <= startIndex:
        return newJNull()

      glaucoplasticStateGetPathInternal(states, parts[startIndex .. ^1])

    proc `stateGetInternalSym`(
      states: PlasticStateRuntime;
      name: string
    ): JsonNode =
      let resolved = glaucoplasticResolveStatePathText(states, name)
      plasticDebugTrace(
        "state.get name=" & name &
        " kind=" & $resolved.kind &
        " value=" & $resolved
      )
      resolved

    proc glaucoplasticStateGetPathInternal(
      states: PlasticStateRuntime;
      path: openArray[string]
    ): JsonNode =
      if path.len == 0:
        return newJNull()

      let rootName = glaucoplasticStateResolveKey(states, path[0])
      if rootName.len == 0:
        return newJNull()

      result = states.values[rootName].copy
      if path.len == 1:
        return

      var current = result
      for index in 1 ..< path.len:
        if current.kind != JObject:
          return newJNull()
        let resolvedKey = glaucoplasticJsonObjectResolveKey(current, path[index])
        if resolvedKey.len == 0:
          return newJNull()
        current = current[resolvedKey]

      result = current.copy

    proc glaucoplasticStateSetPathInternal(
      states: PlasticStateRuntime;
      path: openArray[string];
      value: JsonNode
    ) =
      if path.len == 0:
        raise newException(PlasticRuntimeError, "Caminho de estado vazio")

      let rootName = glaucoplasticStateResolveKey(states, path[0])
      let targetRootName = if rootName.len > 0: rootName else: path[0]
      let previousRoot =
        if states.values.hasKey(targetRootName): states.values[targetRootName].copy
        else: newJNull()

      if path.len == 1:
        states.values[targetRootName] = value.copy
      else:
        if not states.values.hasKey(targetRootName) or
            states.values[targetRootName].kind != JObject:
          states.values[targetRootName] = newJObject()

        var current = states.values[targetRootName]
        for index in 1 ..< path.len - 1:
          let part = path[index]
          let resolvedKey = glaucoplasticJsonObjectResolveKey(current, part)
          let targetKey = if resolvedKey.len > 0: resolvedKey else: part
          if not current.hasKey(targetKey) or current[targetKey].kind != JObject:
            current[targetKey] = newJObject()
          current = current[targetKey]

        let resolvedLastKey = glaucoplasticJsonObjectResolveKey(current, path[^1])
        let lastKey = if resolvedLastKey.len > 0: resolvedLastKey else: path[^1]
        current[lastKey] = value.copy

      plasticDebugTrace(
        "state.set path=" & path.join(".") &
        " root=" & targetRootName &
        " value=" & $value
      )

      let currentRoot = states.values[targetRootName]
      if previousRoot == currentRoot:
        return

      let change = PlasticStateChange(
        name: targetRootName,
        path: path.join("."),
        previousValue: previousRoot,
        currentValue: currentRoot.copy,
        changedAt: now()
      )

      if states.listeners.hasKey(targetRootName):
        for listener in states.listeners[targetRootName]:
          listener(change)

    proc `stateSetInternalSym`(
      states: PlasticStateRuntime;
      name: string;
      value: JsonNode
    ) =
      glaucoplasticStateSetPathInternal(states, @[name], value)

    macro state*(stateParts: varargs[untyped]): untyped =
      if stateParts.len == 1 and stateParts[0].kind == nnkExprEqExpr:
        let targetPath = stateParts[0][0]
        let valueExpr = stateParts[0][1]
        result = buildStateAssignmentExpr(
          ident(`applicationNameLiteral`),
          targetPath,
          valueExpr
        )
        return

      if stateParts.len == 2:
        result = buildStateAssignmentExpr(
          ident(`applicationNameLiteral`),
          stateParts[0],
          stateParts[1]
        )
        return

      if stateParts.len == 1:
        result = buildStateAccessExpr(
          ident(`applicationNameLiteral`),
          stateParts[0]
        )
        return

      error(
        "Use `state Nome`, `state Nome = valor` ou `state Nome.propriedade`.",
        stateParts
      )

  # Núcleo obrigatório: utilidades, plano incremental e aplicação-base.
  result.add quote do:
    proc ensureParentDirectory(path: string) =
      let parent = path.parentDir
      if parent.len > 0 and not dirExists(parent):
        createDir(parent)

    proc writeJsonFile(path: string; node: JsonNode) =
      ensureParentDirectory(path)
      writeFile(path, pretty(node))

    proc readJsonFile(path: string; fallback: JsonNode): JsonNode =
      if not fileExists(path):
        return fallback

      try:
        result = parseJson(readFile(path))
      except CatchableError as error:
        raise newException(
          PlasticRuntimeError,
          "JSON inválido em " & path & ": " & error.msg
        )

    proc `jsonStringFieldSym`(node: JsonNode; key: string; fallback = ""): string =
      if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
        node[key].getStr
      else:
        fallback

    proc `jsonBoolFieldSym`(node: JsonNode; key: string; fallback = false): bool =
      if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
        node[key].getBool
      else:
        fallback

    proc `jsonIntFieldSym`(node: JsonNode; key: string; fallback = 0): int =
      if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
        node[key].getInt
      else:
        fallback

    proc quoteShellArgument(value: string): string =
      when defined(windows):
        result = "\"" & value.replace("\"", "\\\"") & "\""
      else:
        result = "'" & value.replace("'", "'\\''") & "'"

    proc commandResult(command: string): tuple[output: string, exitCode: int] =
      try:
        result = execCmdEx(command)
      except CatchableError as error:
        result = (error.msg, 127)


    proc parsePlasticPlan*(serialized: string): PlasticPlan =
      try:
        result = PlasticPlan(root: parseJson(serialized))
      except CatchableError as error:
        raise newException(
          PlasticRuntimeError,
          "Não foi possível ler o plano GlaucoPlastic: " & error.msg
        )

    proc planChildren(node: JsonNode): seq[JsonNode] =
      if node.kind == JObject and node.hasKey("children") and node["children"].kind == JArray:
        for child in node["children"].items:
          result.add child

    proc planArguments(node: JsonNode): seq[JsonNode] =
      if node.kind == JObject and node.hasKey("arguments") and node["arguments"].kind == JArray:
        for argument in node["arguments"].items:
          result.add argument

    proc planName(node: JsonNode): string =
      `jsonStringFieldSym`(node, "name")

    proc planKind(node: JsonNode): string =
      `jsonStringFieldSym`(node, "kind")

    proc planSource(node: JsonNode): string =
      `jsonStringFieldSym`(node, "source")

    proc findPlanSection(plan: PlasticPlan; sectionName: string): Option[JsonNode] =
      if plan.isNil or plan.root.isNil:
        return none(JsonNode)

      for child in planChildren(plan.root):
        if planKind(child) == "call" and planName(child) == sectionName:
          return some(child)

      none(JsonNode)

    proc findChildCall(node: JsonNode; callName: string): Option[JsonNode] =
      for child in planChildren(node):
        if planKind(child) == "call" and planName(child) == callName:
          return some(child)

      none(JsonNode)

    proc argumentLiteral(argument: JsonNode): JsonNode =
      if argument.kind == JObject and argument.hasKey("literal"):
        return argument["literal"]
      newJNull()

    proc firstLiteralString(node: JsonNode; fallback = ""): string =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return fallback

      let literal = argumentLiteral(arguments[0])
      if literal.kind == JString:
        literal.getStr
      else:
        fallback

    proc firstLiteralInt(node: JsonNode; fallback = 0): int =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return fallback

      let literal = argumentLiteral(arguments[0])
      if literal.kind == JInt:
        literal.getInt
      else:
        fallback

    proc firstLiteralBool(node: JsonNode; fallback = false): bool =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return fallback

      let literal = argumentLiteral(arguments[0])
      if literal.kind == JBool:
        literal.getBool
      else:
        fallback

    proc firstLiteralFloat(node: JsonNode; fallback = 0.0): float =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return fallback

      let literal = argumentLiteral(arguments[0])
      case literal.kind
      of JFloat:
        literal.getFloat
      of JInt:
        literal.getInt.float
      else:
        fallback

    proc callNamedArgument(node: JsonNode; argumentName: string): Option[JsonNode] =
      for argument in planArguments(node):
        if planKind(argument) == "namedArgument" and planName(argument) == argumentName:
          if argument.hasKey("value"):
            return some(argument["value"])
      none(JsonNode)

    proc positionalIdentityName(node: JsonNode): string =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return ""
      if planKind(arguments[0]) in ["identifier", "call", "path"]:
        let fullName = planName(arguments[0])
        if fullName.len == 0:
          return ""
        if "." in fullName:
          return fullName.split(".")[0]
        return fullName
      ""

    proc positionalIdentityPath(node: JsonNode): string =
      let arguments = planArguments(node)
      if arguments.len == 0:
        return ""
      if planKind(arguments[0]) in ["identifier", "call", "path"]:
        return planName(arguments[0])
      ""

    proc literalOrNull(node: JsonNode): JsonNode =
      if node.kind == JObject and node.hasKey("literal"):
        return node["literal"].copy
      newJNull()

    proc parseOkfNode(node: JsonNode): JsonNode =
      proc okfLiteralOrNull(item: JsonNode): JsonNode =
        if item.kind == JObject and item.hasKey("literal"):
          return item["literal"].copy
        newJNull()

      proc okfScalarValue(item: JsonNode): JsonNode =
        let literal = okfLiteralOrNull(item)
        if literal.kind != JNull:
          return literal
        if item.kind == JObject and planKind(item) in ["identifier", "path"]:
          let name = planName(item)
          if name.len > 0:
            return %name
        newJNull()

      proc okfFieldNode(item: JsonNode): JsonNode =
        let arguments = planArguments(item)
        let value =
          if arguments.len > 0:
            okfScalarValue(arguments[0])
          else:
            newJNull()
        result = %*{
          "kind": planKind(item),
          "name": planName(item),
          "source": planSource(item),
          "value": value,
          "arguments": arguments,
          "children": newJArray()
        }
        for child in planChildren(item):
          result["children"].add child.copy

      # Contrato canônico do OKF:
      # - o nome do nó é o título implícito;
      # - `purpose` é obrigatório;
      # - campos escalares extras são livres e ficam em `fields`;
      # - nós aninhados continuam em `children`.
      result = newJObject()
      result["kind"] = %planKind(node)
      result["name"] = %positionalIdentityName(node)
      result["title"] = result["name"].copy
      result["path"] = %positionalIdentityPath(node)
      result["source"] = %planSource(node)
      result["purpose"] = %""
      result["summary"] = %""
      result["elements"] = newJNull()
      result["properties"] = newJNull()
      result["relations"] = newJNull()
      result["functions"] = newJNull()
      result["sources"] = newJNull()
      result["metadata"] = newJNull()
      result["requiredFields"] = newJArray()
      result["fields"] = newJObject()
      result["children"] = newJArray()

      for child in planChildren(node):
        if planKind(child) == "call":
          case planName(child)
          of "purpose":
            let purpose = firstLiteralString(child)
            if purpose.len > 0:
              result["purpose"] = %purpose
              if result["summary"].kind == JString and result["summary"].getStr.len == 0:
                result["summary"] = %purpose
            continue
          of "summary":
            let summary = firstLiteralString(child)
            if summary.len > 0:
              result["summary"] = %summary
            continue
          of "title":
            let title = firstLiteralString(child)
            if title.len > 0:
              result["title"] = %title
            continue
          of "elements", "properties", "relations", "functions", "sources", "metadata":
            result[planName(child)] = okfFieldNode(child)
            continue
          else:
            discard

        if planKind(child) == "call" and planName(child) == "purpose":
          continue

        if planKind(child) in ["call", "command"] and planChildren(child).len == 0:
          let fieldName = planName(child)
          if fieldName.len == 0:
            continue

          let arguments = planArguments(child)
          let fieldValue =
            if arguments.len > 0:
              okfScalarValue(arguments[0])
            else:
              newJNull()

          result["fields"][fieldName] = %*{
            "kind": planKind(child),
            "name": fieldName,
            "source": planSource(child),
            "value": fieldValue,
            "arguments": arguments,
            "children": newJArray()
          }
        else:
          result["children"].add parseOkfNode(child)

    proc planValueOrName(node: JsonNode): JsonNode =
      ## Converte argumentos simples da DSL em valores de runtime. Literais são
      ## preservados; identificadores declarativos tornam-se strings.
      let literal = literalOrNull(node)
      if literal.kind != JNull:
        return literal

      if node.kind == JObject:
        case planKind(node)
        of "identifier", "path":
          let name = planName(node)
          if name.len > 0:
            return %name
        else:
          discard

      newJNull()

    proc planTextValue(node: JsonNode): string =
      if node.kind == JObject:
        let literal = literalOrNull(node)
        if literal.kind == JString:
          return literal.getStr
        if planKind(node) in ["identifier", "path", "call"]:
          return planSource(node)
      elif node.kind == JString:
        return node.getStr
      ""

    proc firstChildLiteralText(node: JsonNode): string =
      for child in planChildren(node):
        if child.kind == JObject and child.hasKey("literal"):
          let literal = child["literal"]
          if literal.kind == JString:
            return literal.getStr
        if planKind(child) == "call":
          let literal = firstLiteralString(child)
          if literal.len > 0:
            return literal
      ""

    proc sectionBody(node: JsonNode): JsonNode =
      if node.kind == JObject and node.hasKey("children") and node["children"].kind == JArray:
        return node["children"].copy
      newJArray()


    proc appendPlasticPlanSection(
      application: PlasticApplication;
      serializedSection: string
    ) =
      let section = parseJson(serializedSection)
      if application.planValue.isNil:
        application.planValue = PlasticPlan(
          root: %*{"kind": "root", "children": []}
        )
      if application.planValue.root.kind != JObject:
        application.planValue.root = %*{"kind": "root", "children": []}
      if not application.planValue.root.hasKey("children") or
          application.planValue.root["children"].kind != JArray:
        application.planValue.root["children"] = newJArray()
      application.planValue.root["children"].add section
      application.planJsonValue = $application.planValue.root

    proc plasticBaseDataRoot(applicationName: string): string =
      when defined(windows):
        getEnv("LOCALAPPDATA", getHomeDir()) / applicationName
      elif defined(macosx):
        getHomeDir() / "Library" / "Application Support" / applicationName
      else:
        getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / applicationName

    proc plasticWebViewProfileRoot(applicationDataRoot: string): string =
      ## Perfil persistente do navegador. O caminho pode ser alterado antes de
      ## run() por GLAUCOPLASTIC_WEBVIEW_USER_FOLDER, mas nunca cai no cwd.
      let configured =
        getEnv("GLAUCOPLASTIC_WEBVIEW_USER_FOLDER", "").strip
      if configured.len > 0:
        result = absolutePath(expandTilde(configured))
      else:
        result = absolutePath(applicationDataRoot / "webview" / "Default")

    proc newPlasticApplicationBase(applicationName: string): PlasticApplication =
      let dataRoot = plasticBaseDataRoot(applicationName)
      let webViewRoot = plasticWebViewProfileRoot(dataRoot)
      let llamaConfig = PlasticLlamaConfig(
        host: plasticDefaultLlamaHostCandidates()[0],
        port: plasticDefaultLlamaPortCandidates()[0],
        modelAlias: getEnv("GLAUCOPLASTIC_MODEL_ALIAS", "qwen3-4b"),
        contextSize: parseInt(getEnv("GLAUCOPLASTIC_CONTEXT_SIZE", "32768")),
        gpuLayers: parseInt(getEnv("GLAUCOPLASTIC_GPU_LAYERS", "0")),
        temperature: parseFloat(getEnv("GLAUCOPLASTIC_TEMPERATURE", "0.1")),
        maxTokens: parseInt(getEnv("GLAUCOPLASTIC_MAX_TOKENS", "2048")),
        logResponseBody: getEnv("GLAUCOPLASTIC_LLM_LOG_RESPONSE", "0").strip.toLowerAscii in ["1", "true", "yes", "on", "enabled"]
      )
      result = PlasticApplication(
        nameValue: applicationName,
        productValue: PlasticProductConfig(
          title: applicationName,
          description: "",
          version: "0.1.0"
        ),
        memoryValue: newJObject(),
        installationValue: PlasticInstallationRuntime(
          config: PlasticInstallationConfig(
            productName: applicationName,
            manufacturer: "GlaucoPlastic",
            version: "0.1.0",
            upgradeCode: "00000000-0000-0000-0000-000000000000",
            scope: pisPerUser,
            executableName: applicationName & (when defined(windows): ".exe" else: ""),
            iconPath: "",
            installRootName: "localAppDataPrograms",
            installRelativePath: applicationName,
            dataRootName: "localAppData",
            dataRelativePath: applicationName,
            dataDirectories: @[
              "data", "okf", ".glauco/metis", ".glauco/sessions",
              ".glauco/assistant", ".glauco/assistant/sessions",
              ".glauco/runtime/metis", ".glauco/models/metis",
              ".glauco/cache/huggingface",
              "webview/Default", "webview/Default/data", "webview/Default/cache"
            ],
            assets: @[],
            desktopShortcut: true,
            startMenuShortcut: true
          ),
          installRoot: getAppDir(),
          dataRoot: dataRoot,
          dataPath: dataRoot / "data",
          okfPath: dataRoot / "okf",
          metisMemoryPath: dataRoot / ".glauco" / "metis",
          sessionPath: dataRoot / ".glauco" / "sessions",
          ormPath: dataRoot / "data" / "orm.json"
        ),
        planValue: PlasticPlan(root: %*{"kind": "root", "children": []}),
        planJsonValue: "",
        statesValue: PlasticStateRuntime(
          values: initTable[string, JsonNode](),
          listeners: initTable[string, seq[PlasticStateListener]](),
          descriptors: newJArray()
        ),
        ormValue: PlasticOrmRuntime(
          path: dataRoot / "data" / "orm.json",
          data: readJsonFile(dataRoot / "data" / "orm.json", newJObject()),
          schema: newJObject()
        ),
        okfValue: PlasticOkfRuntime(
          rootPath: dataRoot / "okf",
          indexPath: dataRoot / "okf" / "index.json",
          index: readJsonFile(
            dataRoot / "okf" / "index.json",
            %*{"version": 1, "items": []}
          ),
          spaces: newJObject()
        ),
        metisMemoryValue: PlasticMetisMemory(
          config: PlasticMetisMemoryConfig(
            enabled: getEnv("GLAUCOPLASTIC_METIS_ENABLED", "1") != "0",
            startup: getEnv("GLAUCOPLASTIC_METIS_STARTUP", "1") != "0",
            prepareRuntime: getEnv("GLAUCOPLASTIC_METIS_PREPARE_RUNTIME", "1") != "0",
            autoInstallDependencies: getEnv("GLAUCOPLASTIC_METIS_AUTO_INSTALL", "1") != "0",
            autoDownloadModel: getEnv("GLAUCOPLASTIC_METIS_AUTO_DOWNLOAD", "0") != "0",
            pythonVersion: getEnv("GLAUCOPLASTIC_METIS_PYTHON_VERSION", "3.10"),
            pythonVenv: getEnv("GLAUCOPLASTIC_METIS_VENV", ""),
            modelId: getEnv("GLAUCOPLASTIC_METIS_MODEL", "IAAR-Shanghai/Metis-4B"),
            profile: getEnv("GLAUCOPLASTIC_METIS_PROFILE", applicationName.toLowerAscii),
            device: getEnv("GLAUCOPLASTIC_METIS_DEVICE", "cuda:0"),
            dtypeName: getEnv("GLAUCOPLASTIC_METIS_DTYPE", "bfloat16"),
            quantization: getEnv("GLAUCOPLASTIC_METIS_QUANTIZATION", "4bit"),
            layout: getEnv("GLAUCOPLASTIC_METIS_LAYOUT", "auto"),
            queryTokens: parseInt(getEnv("GLAUCOPLASTIC_METIS_QUERY_TOKENS", "96")),
            memoryMode: getEnv("GLAUCOPLASTIC_METIS_MEMORY_MODE", "deferred"),
            workerMaxTokens: parseInt(getEnv("GLAUCOPLASTIC_METIS_WORKER_MAX_TOKENS", "128")),
            workerDelay: parseFloat(getEnv("GLAUCOPLASTIC_METIS_WORKER_DELAY", "0.25")),
            recentMessages: parseInt(getEnv("GLAUCOPLASTIC_METIS_RECENT_MESSAGES", "12"))
          ),
          rootPath: dataRoot / ".glauco" / "metis",
          runtimeRoot: dataRoot / ".glauco" / "runtime" / "metis",
          modelCachePath: dataRoot / ".glauco" / "cache" / "huggingface",
          runtimePrepared: false,
          modelPrepared: false,
          initialized: false,
          lastError: ""
        ),
        assistantValue: newPlasticAssistantRuntime(
          applicationName,
          dataRoot,
          "http://" & llamaConfig.host & ":" & $llamaConfig.port & "/v1",
          llamaConfig.modelAlias
        ),
        safeStorageValue: PlasticSafeStorageRuntime(
          config: PlasticSafeStorageConfig(
            serviceName: applicationName & ".safe-storage",
            label: applicationName
          )
        ),
        foreignValue: PlasticForeignRuntime(
          backend: nil,
          elements: initTable[string, PlasticForeignElementRuntime](),
          onUrlChanged: nil,
          onEvent: nil
        ),
        llamaValue: PlasticLlamaRuntime(
          config: llamaConfig,
          executablePath: "",
          modelPath: "",
          runtimeRoot: getEnv(
            "GLAUCOPLASTIC_LLAMA_RUNTIME_ROOT",
            dataRoot / ".glauco" / "runtime" / "llama"
          ),
          releaseRepo: getEnv(
            "GLAUCOPLASTIC_LLAMA_RELEASE_REPO",
            "ggml-org/llama.cpp"
          ),
          releaseVersion: getEnv("GLAUCOPLASTIC_LLAMA_VERSION", ""),
          releaseBackend: getEnv("GLAUCOPLASTIC_LLAMA_BACKEND", "auto"),
          autoDownloadRuntime: getEnv(
            "GLAUCOPLASTIC_LLAMA_AUTO_DOWNLOAD_RUNTIME",
            "1"
          ) != "0",
          autoUpdateRuntime: getEnv(
            "GLAUCOPLASTIC_LLAMA_AUTO_UPDATE_RUNTIME",
            "1"
          ) != "0",
          updateIntervalHours: parseInt(getEnv(
            "GLAUCOPLASTIC_LLAMA_UPDATE_INTERVAL_HOURS",
            "24"
          )),
          managedRuntime: false,
          endpoint: "http://" & llamaConfig.host & ":" & $llamaConfig.port & "/v1"
        ),
        rlmValue: PlasticRlmRuntime(
          capabilities: initTable[string, PlasticCapability]()
        ),
        agentsValue: initTable[string, PlasticAgent](),
        componentsValue: newJArray(),
        renderTreeValue: newJArray(),
        desktopValue: PlasticDesktopRuntime(running: false),
        webViewValue: PlasticWebViewRuntime(
          userFolder: webViewRoot,
          dataFolder: webViewRoot / "data",
          cacheFolder: webViewRoot / "cache",
          cookiesPath: webViewRoot / "cookies.sqlite",
          persistent: true,
          persistentCookies: true,
          acceptThirdPartyCookies: true,
          safeGraphics: false,
          configured: false,
          storagePrepared: false,
          initialized: false
        ),
        uiHandlersValue: initTable[string, PlasticUiEventHandler](),
        uiHandlerIdsValue: initTable[string, string](),
        foreignEventHandlersValue:
          initTable[string, seq[PlasticForeignEventProc]](),
        uiPropertyWriterValue: nil,
        startupActionsValue: @[],
        startupExecutedValue: false,
        runningValue: false,
        agentPollStartedValue: false
      )

    proc safeStorageAvailable*(application: PlasticApplication): bool =
      findExe("secret-tool").len > 0

    proc safeStorageService*(application: PlasticApplication): string =
      application.safeStorageValue.config.serviceName

    proc safeStorageLabel*(application: PlasticApplication): string =
      application.safeStorageValue.config.label

    proc saveSafeStorageCredential*(
      application: PlasticApplication;
      account: string;
      username: string;
      secret: string
    ) =
      if username.len == 0 or secret.len == 0:
        raise newException(
          PlasticRuntimeError,
          "Informe usuario e segredo antes de salvar no SafeStorage."
        )

      if not application.safeStorageAvailable():
        raise newException(
          PlasticRuntimeError,
          "secret-tool nao esta disponivel neste sistema."
        )

      let payload = pretty(
        %*{
          "username": username,
          "secret": secret
        }
      )
      let encoded = encode(payload)
      let command =
        "printf %s " & quoteShellArgument(encoded) &
        " | base64 -d | secret-tool store --label " &
        quoteShellArgument(application.safeStorageLabel()) &
        " service " & quoteShellArgument(application.safeStorageService()) &
        " account " & quoteShellArgument(account)
      let (output, exitCode) = commandResult(command)
      if exitCode != 0:
        raise newException(
          PlasticRuntimeError,
          "Nao foi possivel salvar a credencial no SafeStorage do sistema: " &
          output.strip()
        )

    proc loadSafeStorageCredential*(
      application: PlasticApplication;
      account: string
    ): PlasticSafeStorageCredential =
      if not application.safeStorageAvailable():
        raise newException(
          PlasticRuntimeError,
          "secret-tool nao esta disponivel neste sistema."
        )

      let command =
        "secret-tool lookup service " &
        quoteShellArgument(application.safeStorageService()) &
        " account " & quoteShellArgument(account)
      let (output, exitCode) = commandResult(command)
      if exitCode != 0:
        raise newException(
          PlasticRuntimeError,
          "Nao foi possivel ler a credencial no SafeStorage do sistema."
        )

      let payload = output.strip()
      if payload.len == 0:
        raise newException(
          PlasticRuntimeError,
          "Nenhuma credencial foi encontrada no SafeStorage do sistema."
        )

      let parsed = parseJson(payload)
      result.username = parsed["username"].getStr()
      result.secret = parsed["secret"].getStr()

    proc name*(application: PlasticApplication): string = application.nameValue
    proc product*(application: PlasticApplication): PlasticProductConfig = application.productValue
    proc installation*(application: PlasticApplication): PlasticInstallationRuntime = application.installationValue
    proc states*(application: PlasticApplication): PlasticStateRuntime = application.statesValue
    proc orm*(application: PlasticApplication): PlasticOrmRuntime = application.ormValue
    proc okf*(application: PlasticApplication): PlasticOkfRuntime = application.okfValue
    proc foreign*(application: PlasticApplication): PlasticForeignRuntime = application.foreignValue
    proc llama*(application: PlasticApplication): PlasticLlamaRuntime = application.llamaValue
    proc rlm*(application: PlasticApplication): PlasticRlmRuntime = application.rlmValue
    proc metisMemory*(application: PlasticApplication): PlasticMetisMemory = application.metisMemoryValue
    proc safeStorage*(application: PlasticApplication): PlasticSafeStorageRuntime = application.safeStorageValue
    proc desktop*(application: PlasticApplication): PlasticDesktopRuntime = application.desktopValue
    proc webview*(application: PlasticApplication): PlasticWebViewRuntime = application.webViewValue
    proc agents*(application: PlasticApplication): Table[string, PlasticAgent] = application.agentsValue
    proc planJson*(application: PlasticApplication): string = application.planJsonValue
    proc components*(application: PlasticApplication): JsonNode = application.componentsValue.copy
    proc renderTree*(application: PlasticApplication): JsonNode = application.renderTreeValue.copy
    proc ormSchema*(application: PlasticApplication): JsonNode = application.ormValue.schema.copy

    proc plasticJson*(value: JsonNode): JsonNode =
      if value.isNil: newJNull() else: value.copy

    proc plasticJson*(value: string): JsonNode = %value
    proc plasticJson*(value: cstring): JsonNode = %($value)
    proc plasticJson*(value: bool): JsonNode = %value
    proc plasticJson*(value: SomeInteger): JsonNode = %value
    proc plasticJson*(value: SomeFloat): JsonNode = %value

    proc uiBindingKey(path, eventName: string): string =
      path & "\x1f" & eventName.toLowerAscii

    proc registerUiHandler*(
      application: PlasticApplication;
      handlerId: string;
      handler: PlasticUiEventHandler
    ) =
      if application.isNil or handlerId.len == 0 or handler.isNil:
        return
      application.uiHandlersValue[handlerId] = handler

    proc bindUiHandler*(
      application: PlasticApplication;
      path, eventName, handlerId: string
    ) =
      if application.isNil or path.len == 0 or
          eventName.len == 0 or handlerId.len == 0:
        return
      application.uiHandlerIdsValue[
        uiBindingKey(path, eventName)
      ] = handlerId

    proc uiHandlerId*(
      application: PlasticApplication;
      path, eventName: string
    ): string =
      if application.isNil:
        return ""
      application.uiHandlerIdsValue.getOrDefault(
        uiBindingKey(path, eventName),
        ""
      )

    proc dispatchUiEvent*(
      application: PlasticApplication;
      payload: JsonNode
    ) =
      if application.isNil or payload.kind != JObject:
        return

      let handlerId = `jsonStringFieldSym`(payload, "handlerId")
      plasticDebugTrace(
        "dispatchUiEvent handlerId=" & handlerId &
        " event=" & `jsonStringFieldSym`(payload, "event") &
        " identity=" & `jsonStringFieldSym`(payload, "identity") &
        " bindState=" & `jsonStringFieldSym`(payload, "bindState")
      )
      if handlerId.len == 0 or
          not application.uiHandlersValue.hasKey(handlerId):
        return

      var value = newJNull()
      if payload.hasKey("value"):
        value = payload["value"].copy

      let checked =
        payload.hasKey("checked") and
        payload["checked"].kind == JBool and
        payload["checked"].getBool

      application.uiHandlersValue[handlerId](
        PlasticUiEvent(
          handlerId: handlerId,
          eventName: `jsonStringFieldSym`(payload, "event"),
          identityPath: `jsonStringFieldSym`(payload, "identity"),
          value: value,
          checked: checked,
          key: `jsonStringFieldSym`(payload, "key")
        )
      )

    proc registerForeignEventHandler*(
      application: PlasticApplication;
      path, eventName: string;
      handler: PlasticForeignEventProc
    ) =
      if application.isNil or path.len == 0 or
          eventName.len == 0 or handler.isNil:
        return
      let key = uiBindingKey(path, eventName)
      application.foreignEventHandlersValue
        .mgetOrPut(key, @[])
        .add(handler)

    proc dispatchForeignEvent*(
      application: PlasticApplication;
      path, eventName: string
    ) =
      if application.isNil:
        return
      let key = uiBindingKey(path, eventName)
      if not application.foreignEventHandlersValue.hasKey(key):
        return
      for handler in application.foreignEventHandlersValue[key]:
        handler(path, eventName)

    proc updateUiProperty*(
      application: PlasticApplication;
      path, propertyName: string;
      value: JsonNode
    ) =
      if application.isNil or application.uiPropertyWriterValue.isNil:
        return
      application.uiPropertyWriterValue(
        path,
        propertyName,
        if value.isNil: newJNull() else: value.copy
      )

    proc registerProgram*(
      application: PlasticApplication;
      action: proc() {.closure.}
    ) =
      if application.isNil or action.isNil:
        return
      application.startupActionsValue.add action

    proc executeProgram*(application: PlasticApplication) =
      if application.isNil or application.startupExecutedValue:
        return
      application.startupExecutedValue = true
      try:
        let debugEnabled =
          getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.toLowerAscii in
          ["1", "true", "yes", "on", "enabled"]
        if debugEnabled:
          echo "[GlaucoPlastic] executeProgram: actions=",
            application.startupActionsValue.len
        for index, action in application.startupActionsValue:
          if debugEnabled:
            echo "[GlaucoPlastic] executeProgram: begin action=", index
          action()
          if debugEnabled:
            echo "[GlaucoPlastic] executeProgram: end action=", index
      except:
        application.startupExecutedValue = false
        raise

    proc programExecuted*(application: PlasticApplication): bool =
      not application.isNil and application.startupExecutedValue

    proc registerStartup*(
      application: PlasticApplication;
      action: proc() {.closure.}
    ) =
      application.registerProgram(action)

    proc initializeDeclaredApplication*(application: PlasticApplication) =
      application.executeProgram()

    proc startupExecuted*(application: PlasticApplication): bool =
      application.programExecuted()

  result.add newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      postfix(applicationName.copyNimTree, "*"),
      newEmptyNode(),
      ident("PlasticApplication")
    )
  )

  result.add newTree(
    nnkLetSection,
    newTree(
      nnkIdentDefs,
      postfix(applicationVariable.copyNimTree, "*"),
      applicationName.copyNimTree,
      newCall(ident("newPlasticApplicationBase"), newLit(applicationName.repr))
    )
  )

  var program = newStmtList()

  for section in body:
    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("product"):
      result.add quote do:
        proc defaultProductConfig(applicationName: string): PlasticProductConfig =
          PlasticProductConfig(
            title: applicationName,
            description: "",
            version: "0.1.0"
          )

        proc parseProductConfig(plan: PlasticPlan; applicationName: string): PlasticProductConfig =
          result = defaultProductConfig(applicationName)
          let section = findPlanSection(plan, "product")
          if section.isNone:
            return

          for child in planChildren(section.get):
            case planName(child)
            of "title": result.title = firstLiteralString(child, result.title)
            of "description": result.description = firstLiteralString(child, result.description)
            of "version": result.version = firstLiteralString(child, result.version)
            else: discard

        proc defaultSafeStorageConfig(applicationName: string): PlasticSafeStorageConfig =
          PlasticSafeStorageConfig(
            serviceName: applicationName & ".safe-storage",
            label: applicationName
          )

        proc parseSafeStorageConfig(
          plan: PlasticPlan;
          applicationName: string
        ): PlasticSafeStorageConfig =
          result = defaultSafeStorageConfig(applicationName)
          let productSection = findPlanSection(plan, "product")
          if productSection.isNone:
            return

          let safeStorageSection = findChildCall(productSection.get, "safeStorage")
          if safeStorageSection.isNone:
            return

          for child in planChildren(safeStorageSection.get):
            case planName(child)
            of "service": result.serviceName = firstLiteralString(child, result.serviceName)
            of "label": result.label = firstLiteralString(child, result.label)
            else: discard
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        `applicationVariable`.productValue = parseProductConfig(
          `applicationVariable`.planValue,
          `applicationNameLiteral`
        )
        `applicationVariable`.safeStorageValue = PlasticSafeStorageRuntime(
          config: parseSafeStorageConfig(
            `applicationVariable`.planValue,
            `applicationNameLiteral`
          )
        )
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("config"):
      result.add quote do:
        proc defaultRuntimeConfig(applicationName: string): tuple[
          okfPath: string,
          llamaModelPath: string,
          llamaModelDir: string,
          llamaModelRepo: string,
          llamaModelFile: string,
          llamaDownloadScript: string,
          llamaAutoDownload: bool,
          llamaContextSize: int,
          llamaMaxTokens: int,
          llamaLogResponseBody: bool,
          metisEnabled: bool,
          metisModelId: string,
          metisProfile: string,
          metisDevice: string,
          metisDtype: string,
          metisQuantization: string,
          metisLayout: string,
          metisQueryTokens: int,
          metisMemoryMode: string,
          metisWorkerMaxTokens: int,
          metisWorkerDelay: float,
          metisRecentMessages: int
        ] =
          let defaultOkfPath =
            when defined(windows):
              getEnv("LOCALAPPDATA", getHomeDir()) / applicationName / "okf"
            elif defined(macosx):
              getHomeDir() / "Library" / "Application Support" / applicationName / "okf"
            else:
              getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / applicationName / "okf"
          result.okfPath = defaultOkfPath
          result.llamaModelPath = plasticDefaultLlamaModelPath()
          result.llamaModelDir = plasticDefaultLlamaModelDir(result.llamaModelPath)
          result.llamaModelRepo = plasticDefaultLlamaModelRepo()
          result.llamaModelFile = plasticDefaultLlamaModelFile()
          result.llamaDownloadScript = plasticDefaultLlamaDownloadScript()
          result.llamaAutoDownload = plasticDefaultLlamaAutoDownload()
          result.llamaContextSize = parseInt(getEnv("GLAUCOPLASTIC_CONTEXT_SIZE", "32768"))
          result.llamaMaxTokens = parseInt(getEnv("GLAUCOPLASTIC_MAX_TOKENS", "2048"))
          result.llamaLogResponseBody = getEnv("GLAUCOPLASTIC_LLM_LOG_RESPONSE", "0").strip.toLowerAscii in ["1", "true", "yes", "on", "enabled"]
          result.metisEnabled = getEnv("GLAUCOPLASTIC_METIS_ENABLED", "1") != "0"
          result.metisModelId = getEnv("GLAUCOPLASTIC_METIS_MODEL", "IAAR-Shanghai/Metis-4B")
          result.metisProfile = getEnv("GLAUCOPLASTIC_METIS_PROFILE", applicationName.toLowerAscii)
          result.metisDevice = getEnv("GLAUCOPLASTIC_METIS_DEVICE", "cuda:0")
          result.metisDtype = getEnv("GLAUCOPLASTIC_METIS_DTYPE", "bfloat16")
          result.metisQuantization = getEnv("GLAUCOPLASTIC_METIS_QUANTIZATION", "4bit")
          result.metisLayout = getEnv("GLAUCOPLASTIC_METIS_LAYOUT", "auto")
          result.metisQueryTokens = parseInt(getEnv("GLAUCOPLASTIC_METIS_QUERY_TOKENS", "96"))
          result.metisMemoryMode = getEnv("GLAUCOPLASTIC_METIS_MEMORY_MODE", "deferred")
          result.metisWorkerMaxTokens = parseInt(getEnv("GLAUCOPLASTIC_METIS_WORKER_MAX_TOKENS", "128"))
          result.metisWorkerDelay = parseFloat(getEnv("GLAUCOPLASTIC_METIS_WORKER_DELAY", "0.25"))
          result.metisRecentMessages = parseInt(getEnv("GLAUCOPLASTIC_METIS_RECENT_MESSAGES", "12"))

        proc parseRuntimeConfig(
          plan: PlasticPlan;
          applicationName: string
        ): tuple[
          okfPath: string,
          llamaModelPath: string,
          llamaModelDir: string,
          llamaModelRepo: string,
          llamaModelFile: string,
          llamaDownloadScript: string,
          llamaAutoDownload: bool,
          llamaContextSize: int,
          llamaMaxTokens: int,
          llamaLogResponseBody: bool,
          metisEnabled: bool,
          metisModelId: string,
          metisProfile: string,
          metisDevice: string,
          metisDtype: string,
          metisQuantization: string,
          metisLayout: string,
          metisQueryTokens: int,
          metisMemoryMode: string,
          metisWorkerMaxTokens: int,
          metisWorkerDelay: float,
          metisRecentMessages: int
        ] =
          result = defaultRuntimeConfig(applicationName)
          let section = findPlanSection(plan, "config")
          if section.isNone:
            return

          for child in planChildren(section.get):
            case planName(child)
            of "okfPath":
              result.okfPath = firstLiteralString(child, result.okfPath)
            of "llama":
              for item in planChildren(child):
                case planName(item)
                of "modelPath":
                  result.llamaModelPath = firstLiteralString(item, result.llamaModelPath)
                of "modelDir":
                  result.llamaModelDir = firstLiteralString(item, result.llamaModelDir)
                of "modelRepo":
                  result.llamaModelRepo = firstLiteralString(item, result.llamaModelRepo)
                of "modelFile":
                  result.llamaModelFile = firstLiteralString(item, result.llamaModelFile)
                of "downloadScript":
                  result.llamaDownloadScript = firstLiteralString(item, result.llamaDownloadScript)
                of "autoDownload":
                  result.llamaAutoDownload = firstLiteralBool(item, result.llamaAutoDownload)
                of "contextSize":
                  result.llamaContextSize = firstLiteralInt(item, result.llamaContextSize)
                of "maxTokens":
                  result.llamaMaxTokens = firstLiteralInt(item, result.llamaMaxTokens)
                of "logResponseBody", "logResponse":
                  result.llamaLogResponseBody = firstLiteralBool(item, result.llamaLogResponseBody)
                else:
                  discard
            of "metis":
              for item in planChildren(child):
                case planName(item)
                of "enabled": result.metisEnabled = firstLiteralBool(item, result.metisEnabled)
                of "model", "modelId": result.metisModelId = firstLiteralString(item, result.metisModelId)
                of "profile": result.metisProfile = firstLiteralString(item, result.metisProfile)
                of "device": result.metisDevice = firstLiteralString(item, result.metisDevice)
                of "dtype": result.metisDtype = firstLiteralString(item, result.metisDtype)
                of "quantization": result.metisQuantization = firstLiteralString(item, result.metisQuantization)
                of "layout": result.metisLayout = firstLiteralString(item, result.metisLayout)
                of "queryTokens": result.metisQueryTokens = firstLiteralInt(item, result.metisQueryTokens)
                of "memoryMode": result.metisMemoryMode = firstLiteralString(item, result.metisMemoryMode)
                of "workerMaxTokens": result.metisWorkerMaxTokens = firstLiteralInt(item, result.metisWorkerMaxTokens)
                of "workerDelay": result.metisWorkerDelay = firstLiteralFloat(item, result.metisWorkerDelay)
                of "recentMessages": result.metisRecentMessages = firstLiteralInt(item, result.metisRecentMessages)
                else: discard
            else:
              discard

        proc resolveConfiguredPath(basePath, configuredPath: string): string =
          if configuredPath.len == 0:
            return basePath
          if configuredPath.startsWith("~"):
            return expandTilde(configuredPath)
          if configuredPath.isAbsolute:
            return configuredPath
          if configuredPath.startsWith("./") or configuredPath.startsWith("../"):
            return basePath.parentDir / configuredPath
          configuredPath
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        let runtimeConfig = parseRuntimeConfig(
          `applicationVariable`.planValue,
          `applicationNameLiteral`
        )
        let resolvedLlamaModelDir =
          if runtimeConfig.llamaModelDir.len > 0:
            resolveConfiguredPath(
              `applicationVariable`.installationValue.installRoot / "models",
              runtimeConfig.llamaModelDir
            )
          else:
            ""
        let resolvedLlamaModelPath =
          if runtimeConfig.llamaModelPath.len > 0:
            resolveConfiguredPath(
              `applicationVariable`.installationValue.installRoot / "models",
              runtimeConfig.llamaModelPath
            )
          elif resolvedLlamaModelDir.len > 0:
            resolvedLlamaModelDir / runtimeConfig.llamaModelFile
          else:
            plasticDefaultLlamaModelPath()
        `applicationVariable`.okfValue.rootPath =
          resolveConfiguredPath(
            `applicationVariable`.installationValue.dataRoot / "okf",
            runtimeConfig.okfPath
          )
        `applicationVariable`.okfValue.indexPath =
          `applicationVariable`.okfValue.rootPath / "index.json"
        `applicationVariable`.llamaValue.modelPath = resolvedLlamaModelPath
        `applicationVariable`.llamaValue.modelDir =
          if resolvedLlamaModelDir.len > 0:
            resolvedLlamaModelDir
          else:
            resolvedLlamaModelPath.parentDir
        `applicationVariable`.llamaValue.modelRepo = runtimeConfig.llamaModelRepo
        `applicationVariable`.llamaValue.modelFile = runtimeConfig.llamaModelFile
        `applicationVariable`.llamaValue.downloadScriptPath =
          resolveConfiguredPath(
            `applicationVariable`.installationValue.installRoot / "scripts",
            runtimeConfig.llamaDownloadScript
          )
        `applicationVariable`.llamaValue.autoDownloadModel =
          runtimeConfig.llamaAutoDownload
        `applicationVariable`.llamaValue.config.contextSize = runtimeConfig.llamaContextSize
        `applicationVariable`.llamaValue.config.maxTokens = runtimeConfig.llamaMaxTokens
        `applicationVariable`.llamaValue.config.logResponseBody = runtimeConfig.llamaLogResponseBody
        `applicationVariable`.metisMemoryValue.config = PlasticMetisMemoryConfig(
          enabled: runtimeConfig.metisEnabled,
          startup: getEnv("GLAUCOPLASTIC_METIS_STARTUP", "1") != "0",
          prepareRuntime: getEnv("GLAUCOPLASTIC_METIS_PREPARE_RUNTIME", "1") != "0",
          autoInstallDependencies: getEnv("GLAUCOPLASTIC_METIS_AUTO_INSTALL", "1") != "0",
          autoDownloadModel: getEnv("GLAUCOPLASTIC_METIS_AUTO_DOWNLOAD", "0") != "0",
          pythonVersion: getEnv("GLAUCOPLASTIC_METIS_PYTHON_VERSION", "3.10"),
          pythonVenv: getEnv("GLAUCOPLASTIC_METIS_VENV", ""),
          modelId: runtimeConfig.metisModelId,
          profile: runtimeConfig.metisProfile,
          device: runtimeConfig.metisDevice,
          dtypeName: runtimeConfig.metisDtype,
          quantization: runtimeConfig.metisQuantization,
          layout: runtimeConfig.metisLayout,
          queryTokens: runtimeConfig.metisQueryTokens,
          memoryMode: runtimeConfig.metisMemoryMode,
          workerMaxTokens: runtimeConfig.metisWorkerMaxTokens,
          workerDelay: runtimeConfig.metisWorkerDelay,
          recentMessages: runtimeConfig.metisRecentMessages
        )
        `applicationVariable`.metisMemoryValue.rootPath =
          `applicationVariable`.installationValue.metisMemoryPath
        if not `applicationVariable`.assistantValue.isNil:
          `applicationVariable`.assistantValue.endpoint =
            `applicationVariable`.llamaValue.endpoint
          `applicationVariable`.assistantValue.modelAlias =
            `applicationVariable`.llamaValue.config.modelAlias
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("installation"):
      result.add quote do:
        proc defaultInstallationConfig(applicationName: string): PlasticInstallationConfig =
          PlasticInstallationConfig(
            productName: applicationName,
            manufacturer: "GlaucoPlastic",
            version: "0.1.0",
            upgradeCode: "00000000-0000-0000-0000-000000000000",
            scope: pisPerUser,
            executableName: applicationName & (when defined(windows): ".exe" else: ""),
            iconPath: "",
            installRootName: "localAppDataPrograms",
            installRelativePath: applicationName,
            dataRootName: "localAppData",
            dataRelativePath: applicationName,
            dataDirectories: @[
              "data",
              "okf",
              ".glauco/memory",
              ".glauco/sessions",
              ".glauco/assistant",
              ".glauco/assistant/sessions",
              "webview/Default",
              "webview/Default/data",
              "webview/Default/cache"
            ],
            desktopShortcut: true,
            startMenuShortcut: true
          )

        proc parseInstallationConfig(plan: PlasticPlan; applicationName: string): PlasticInstallationConfig =
          result = defaultInstallationConfig(applicationName)
          let installation = findPlanSection(plan, "installation")
          if installation.isNone:
            return

          let windowsMsi = findChildCall(installation.get, "windowsMsi")
          if windowsMsi.isNone:
            return

          for child in planChildren(windowsMsi.get):
            case planName(child)
            of "productName": result.productName = firstLiteralString(child, result.productName)
            of "manufacturer": result.manufacturer = firstLiteralString(child, result.manufacturer)
            of "version": result.version = firstLiteralString(child, result.version)
            of "upgradeCode": result.upgradeCode = firstLiteralString(child, result.upgradeCode)
            of "executable": result.executableName = firstLiteralString(child, result.executableName)
            of "icon": result.iconPath = firstLiteralString(child, result.iconPath)
            of "scope":
              let source = planSource(child)
              if source.contains("perMachine"):
                result.scope = pisPerMachine
              else:
                result.scope = pisPerUser
            of "installDirectory":
              for item in planChildren(child):
                case planName(item)
                of "root":
                  let parts = planSource(item).splitWhitespace()
                  if parts.len > 0:
                    result.installRootName = parts[^1]
                of "path": result.installRelativePath = firstLiteralString(item, result.installRelativePath)
                else: discard
            of "applicationData":
              result.dataDirectories.setLen(0)
              for item in planChildren(child):
                case planName(item)
                of "root":
                  let parts = planSource(item).splitWhitespace()
                  if parts.len > 0:
                    result.dataRootName = parts[^1]
                of "path": result.dataRelativePath = firstLiteralString(item, result.dataRelativePath)
                of "createDirectory":
                  let directory = firstLiteralString(item)
                  if directory.len > 0:
                    result.dataDirectories.add directory
                else: discard
            of "package":
              for item in planChildren(child):
                if planName(item) in ["file", "glob", "include", "includeGlob"]:
                  result.assets.add item
            of "shortcut":
              for item in planChildren(child):
                case planName(item)
                of "desktop": result.desktopShortcut = firstLiteralBool(item, result.desktopShortcut)
                of "startMenu": result.startMenuShortcut = firstLiteralBool(item, result.startMenuShortcut)
                else: discard
            else:
              discard

        proc localApplicationDataRoot(applicationName: string): string =
          when defined(windows):
            let base = getEnv("LOCALAPPDATA", getHomeDir())
            base / applicationName
          elif defined(macosx):
            getHomeDir() / "Library" / "Application Support" / applicationName
          else:
            let base = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
            base / applicationName

        proc programDataRoot(applicationName: string): string =
          when defined(windows):
            getEnv("PROGRAMDATA", r"C:\ProgramData") / applicationName
          elif defined(macosx):
            "/Library/Application Support" / applicationName
          else:
            "/var/lib" / applicationName

        proc newInstallationRuntime(config: PlasticInstallationConfig): PlasticInstallationRuntime =
          let dataRoot =
            if config.scope == pisPerMachine:
              programDataRoot(config.dataRelativePath)
            else:
              localApplicationDataRoot(config.dataRelativePath)

          result = PlasticInstallationRuntime(
            config: config,
            installRoot: getAppDir(),
            dataRoot: dataRoot,
            dataPath: dataRoot / "data",
            okfPath: dataRoot / "okf",
            metisMemoryPath: dataRoot / ".glauco" / "metis",
            sessionPath: dataRoot / ".glauco" / "sessions",
            ormPath: dataRoot / "data" / "orm.json"
          )

        proc requiredDataPaths*(runtime: PlasticInstallationRuntime): seq[string] =
          for relativePath in runtime.config.dataDirectories:
            result.add runtime.dataRoot / relativePath

        proc validate*(runtime: PlasticInstallationRuntime) =
          var missing: seq[string]
          for path in runtime.requiredDataPaths:
            if not dirExists(path):
              missing.add path

          if missing.len > 0:
            raise newException(
              PlasticInstallationError,
              "Diretórios ausentes. Execute o instalador ou o script de preparação de desenvolvimento:\n- " &
              missing.join("\n- ")
            )

        proc prepareDevelopmentLayout*(runtime: PlasticInstallationRuntime) =
          ## Operação explícita de desenvolvimento. O início normal da aplicação não
          ## chama esta proc; em produção, o MSI cria os diretórios.
          for path in runtime.requiredDataPaths:
            createDir(path)
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        `applicationVariable`.installationValue = newInstallationRuntime(
          parseInstallationConfig(
            `applicationVariable`.planValue,
            `applicationNameLiteral`
          )
        )
        `applicationVariable`.ormValue.path =
          `applicationVariable`.installationValue.ormPath
        `applicationVariable`.okfValue.rootPath =
          `applicationVariable`.installationValue.okfPath
        `applicationVariable`.okfValue.indexPath =
          `applicationVariable`.installationValue.okfPath / "index.json"
        `applicationVariable`.metisMemoryValue.rootPath =
          `applicationVariable`.installationValue.metisMemoryPath
        if not `applicationVariable`.assistantValue.isNil:
          `applicationVariable`.assistantValue.rootPath =
            `applicationVariable`.installationValue.dataRoot / ".glauco" / "assistant"
          `applicationVariable`.assistantValue.sessionsPath =
            `applicationVariable`.assistantValue.rootPath / "sessions"
          `applicationVariable`.assistantValue.sessionsIndexPath =
            `applicationVariable`.assistantValue.rootPath / "sessions.json"
          `applicationVariable`.assistantValue.thingsPath =
            `applicationVariable`.assistantValue.rootPath / "things.json"
        `applicationVariable`.webViewValue.userFolder =
          plasticWebViewProfileRoot(
            `applicationVariable`.installationValue.dataRoot
          )
        `applicationVariable`.webViewValue.dataFolder =
          `applicationVariable`.webViewValue.userFolder / "data"
        `applicationVariable`.webViewValue.cacheFolder =
          `applicationVariable`.webViewValue.userFolder / "cache"
        `applicationVariable`.webViewValue.cookiesPath =
          `applicationVariable`.webViewValue.userFolder / "cookies.sqlite"
        `applicationVariable`.webViewValue.storagePrepared = false
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("states"):
      result.add quote do:
        proc newStateRuntime*(): PlasticStateRuntime =
          PlasticStateRuntime(
            values: initTable[string, JsonNode](),
            listeners: initTable[string, seq[PlasticStateListener]](),
            descriptors: newJArray()
          )

        proc define*(states: PlasticStateRuntime; name: string; initialValue: JsonNode) =
          states.values[name] = initialValue.copy

        proc exists*(states: PlasticStateRuntime; name: string): bool =
          states.values.hasKey(name)

        proc get*(states: PlasticStateRuntime; name: string): JsonNode =
          `stateGetInternalSym`(states, name)

        proc set*(states: PlasticStateRuntime; name: string; value: JsonNode) =
          `stateSetInternalSym`(states, name, value)

        proc onChanged*(states: PlasticStateRuntime; name: string; listener: PlasticStateListener) =
          states.listeners.mgetOrPut(name, @[]).add listener

        proc snapshot*(states: PlasticStateRuntime): JsonNode =
          result = newJObject()
          for key, value in states.values:
            result[key] = value.copy

        proc constructorValue(node: JsonNode): JsonNode =
          if node.kind != JObject:
            return node.copy

          case planKind(node)
          of "literal":
            if node.hasKey("literal"):
              result = node["literal"].copy
            else:
              result = newJNull()
          of "identifier", "path":
            if node.hasKey("literal") and node["literal"].kind != JNull:
              result = node["literal"].copy
            else:
              case planName(node)
              of "true":
                result = %true
              of "false":
                result = %false
              of "nil":
                result = newJNull()
              else:
                result = %planName(node)
          of "map":
            result = newJObject()
            for child in planChildren(node):
              if planKind(child) == "mapEntry" and child.hasKey("value"):
                let key = planName(child)
                if key.len > 0:
                  result[key] = constructorValue(child["value"])
          of "mapEntry":
            if node.hasKey("value"):
              result = constructorValue(node["value"])
            else:
              result = newJNull()
          of "assignment":
            if node.hasKey("value"):
              result = constructorValue(node["value"])
            else:
              result = newJNull()
          of "call":
            result = newJObject()
            for child in planChildren(node):
              case planKind(child)
              of "call":
                let arguments = planArguments(child)
                if arguments.len > 0:
                  result[planName(child)] = constructorValue(arguments[0])
              of "namedArgument":
                if child.hasKey("value"):
                  result[planName(child)] = constructorValue(child["value"])
              else:
                discard
          else:
            if node.hasKey("literal"):
              result = node["literal"].copy
            else:
              result = newJNull()

        proc initializeStatesFromPlan(states: PlasticStateRuntime; plan: PlasticPlan) =
          let section = findPlanSection(plan, "states")
          if section.isNone:
            return

          for declaration in planChildren(section.get):
            states.descriptors.add declaration.copy

            if planKind(declaration) == "when":
              continue

            if planKind(declaration) == "assignment":
              let left = declaration{"left"}
              let value = declaration{"value"}
              if left.kind == JObject:
                let stateName = planName(left)
                if stateName.len > 0:
                  states.define(stateName, constructorValue(value))
              continue

            if planKind(declaration) == "call":
              let stateName = planName(declaration)
              if stateName.len == 0:
                continue

              var initial = newJNull()

              # Na command syntax do Nim, `Contador integer = 1` chega como:
              #
              #   call Contador
              #     namedArgument integer = 1
              #
              # Portanto, o valor inicial simples pertence aos argumentos da chamada,
              # e não a um nó nnkAsgn separado.
              for argument in planArguments(declaration):
                if planKind(argument) == "namedArgument":
                  let valueNode = argument{"value"}
                  if valueNode.kind == JObject:
                    initial = literalOrNull(valueNode)
                  break

              let children = planChildren(declaration)
              if children.len > 0:
                if children.len == 1 and planName(children[0]) == "value":
                  let arguments = planArguments(children[0])
                  if arguments.len > 0:
                    initial = literalOrNull(arguments[0])
                else:
                  initial = constructorValue(declaration)

              if initial.kind == JNull:
                initial = constructorValue(declaration)

              states.define(stateName, initial)

        # -----------------------------------------------------------------------------
      result.add newCall(
        ident("appendPlasticPlanSection"),
        applicationVariable.copyNimTree,
        newLit($astToPlanJson(section))
      )
      result.add collectStateBindings(section)
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("orm"):
      result.add quote do:
        proc newOrmRuntime*(path: string): PlasticOrmRuntime =
          PlasticOrmRuntime(
            path: path,
            data: readJsonFile(path, newJObject()),
            schema: newJObject()
          )

        proc save*(orm: PlasticOrmRuntime) =
          writeJsonFile(orm.path, orm.data)

        proc ensureEntity(orm: PlasticOrmRuntime; entity: string): JsonNode =
          if orm.data.kind != JObject:
            orm.data = newJObject()
          if not orm.data.hasKey(entity) or orm.data[entity].kind != JArray:
            orm.data[entity] = newJArray()
          orm.data[entity]

        proc allRows*(orm: PlasticOrmRuntime; entity: string): JsonNode =
          ensureEntity(orm, entity).copy

        proc count*(orm: PlasticOrmRuntime; entity: string): int =
          ensureEntity(orm, entity).len

        proc nextId(rows: JsonNode): int =
          result = 1
          for row in rows.items:
            if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt:
              result = max(result, row["id"].getInt + 1)

        proc insertRow*(orm: PlasticOrmRuntime; entity: string; value: JsonNode): JsonNode =
          if value.kind != JObject:
            raise newException(PlasticRuntimeError, "ORM insert espera objeto JSON")

          let rows = ensureEntity(orm, entity)
          result = value.copy
          if not result.hasKey("id") or result["id"].kind == JNull:
            result["id"] = %nextId(rows)
          rows.add result.copy
          orm.save()

        proc findById*(orm: PlasticOrmRuntime; entity: string; id: int): JsonNode =
          for row in ensureEntity(orm, entity).items:
            if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
              return row.copy
          newJNull()

        proc whereEq*(orm: PlasticOrmRuntime; entity, field: string; expected: JsonNode): JsonNode =
          result = newJArray()
          for row in ensureEntity(orm, entity).items:
            if row.kind == JObject and row.hasKey(field) and row[field] == expected:
              result.add row.copy

        proc updateById*(orm: PlasticOrmRuntime; entity: string; id: int; patch: JsonNode): JsonNode =
          if patch.kind != JObject:
            raise newException(PlasticRuntimeError, "ORM update espera objeto JSON")

          let rows = ensureEntity(orm, entity)
          for index in 0 ..< rows.len:
            let row = rows[index]
            if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
              for key, value in patch.pairs:
                rows[index][key] = value.copy
              orm.save()
              return rows[index].copy
          newJNull()

        proc deleteById*(orm: PlasticOrmRuntime; entity: string; id: int): bool =
          let rows = ensureEntity(orm, entity)
          for index in 0 ..< rows.len:
            let row = rows[index]
            if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
              rows.elems.delete(index)
              orm.save()
              return true
          false

        # -----------------------------------------------------------------------------

        proc deriveOrmSchema(plan: PlasticPlan): JsonNode =
          result = newJObject()

          let section = findPlanSection(plan, "orm")
          if section.isNone:
            return

          for entityNode in planChildren(section.get):
            let entityName = planName(entityNode)
            if entityName.len == 0:
              continue

            var fields = newJObject()

            for fieldNode in planChildren(entityNode):
              if planKind(fieldNode) != "call":
                continue

              let fieldName = planName(fieldNode)
              if fieldName.len == 0:
                continue

              var fieldType = "json"
              let arguments = planArguments(fieldNode)

              if arguments.len > 0:
                let candidate = arguments[0]

                case planKind(candidate)
                of "identifier", "path":
                  let name = planName(candidate)
                  if name.len > 0:
                    fieldType = name

                of "namedArgument":
                  let name = planName(candidate)
                  if name.len > 0:
                    fieldType = name

                else:
                  discard

              fields[fieldName] = %*{
                "name": fieldName,
                "type": fieldType
              }

            result[entityName] = %*{
              "name": entityName,
              "fields": fields
            }

        proc initializeOrmFromPlan(
          orm: PlasticOrmRuntime;
          plan: PlasticPlan
        ) =
          orm.schema = deriveOrmSchema(plan)

          if orm.schema.kind != JObject:
            return

          for entityName, _ in orm.schema.pairs:
            discard orm.ensureEntity(entityName)
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        initializeOrmFromPlan(
          `applicationVariable`.ormValue,
          `applicationVariable`.planValue
        )
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("okfs"):
      result.add quote do:
        const
          PlasticOkfConsultationSkill* = """
        Consulte os OKFs existentes antes de responder sobre conhecimento persistido.
        Use okf.search para busca global, okf.<espaco>.search para busca restrita,
        okf.get para documentos completos e okf.tree para conhecer a organização.
        """

          PlasticOkfGenerationSkill* = """
        Quando o pedido exigir produzir ou estruturar conhecimento:
        1. consulte OKFs existentes;
        2. identifique relações;
        3. escolha o espaço adequado;
        4. produza título, resumo, elementos, propriedades, relações e funções;
        5. registre fontes e metadados;
        6. use okf.generate ou okf.update;
        7. devolva o identificador persistido.
        """


        proc newOkfRuntime*(rootPath: string): PlasticOkfRuntime =
          let indexPath = rootPath / "index.json"
          PlasticOkfRuntime(
            rootPath: rootPath,
            indexPath: indexPath,
            index: readJsonFile(indexPath, %*{"version": 1, "items": []}),
            spaces: newJObject()
          )

        proc validate*(okf: PlasticOkfRuntime) =
          if not dirExists(okf.rootPath):
            raise newException(
              PlasticInstallationError,
              "Pasta OKF ausente. Ela deve ser criada pelo MSI: " & okf.rootPath
            )

          if okf.spaces.kind == JObject:
            for spaceName, _ in okf.spaces.pairs:
              let spacePath = okf.rootPath / spaceName
              if not dirExists(spacePath):
                raise newException(
                  PlasticInstallationError,
                  "Espaço OKF ausente. Ele deve ser criado pelo MSI: " & spacePath
                )

        proc save(okf: PlasticOkfRuntime) =
          writeJsonFile(okf.indexPath, okf.index)

        proc saveSpaces(okf: PlasticOkfRuntime) =
          writeJsonFile(
            okf.rootPath / "spaces.json",
            %*{
              "version": 1,
              "spaces": okf.spaces
            }
          )

        proc list*(okf: PlasticOkfRuntime; space = ""): JsonNode =
          result = newJArray()
          if okf.index.kind != JObject or not okf.index.hasKey("items"):
            return

          for item in okf.index["items"].items:
            if space.len == 0 or `jsonStringFieldSym`(item, "space") == space:
              result.add item.copy

        proc get*(okf: PlasticOkfRuntime; id: string): JsonNode =
          for item in okf.list().items:
            if `jsonStringFieldSym`(item, "id") == id:
              return item.copy
          newJNull()

        proc search*(okf: PlasticOkfRuntime; query: string; space = ""): JsonNode =
          let normalized = query.toLowerAscii
          result = newJArray()
          for item in okf.list(space).items:
            let haystack = ($item).toLowerAscii
            if normalized.len == 0 or haystack.contains(normalized):
              result.add item.copy

        proc persist*(okf: PlasticOkfRuntime; document: JsonNode): JsonNode =
          if document.kind != JObject:
            raise newException(PlasticRuntimeError, "OKF persist espera objeto JSON")

          result = document.copy
          if not result.hasKey("id") or result["id"].kind != JString:
            result["id"] = %($epochTime().int64 & "-" & $okf.list().len)
          if not result.hasKey("createdAt"):
            result["createdAt"] = %now().format("yyyy-MM-dd'T'HH:mm:sszzz")
          result["updatedAt"] = %now().format("yyyy-MM-dd'T'HH:mm:sszzz")

          if not okf.index.hasKey("items") or okf.index["items"].kind != JArray:
            okf.index["items"] = newJArray()

          let items = okf.index["items"]

          var replaced = false
          for index in 0 ..< items.len:
            if `jsonStringFieldSym`(items[index], "id") == `jsonStringFieldSym`(result, "id"):
              items.elems[index] = result.copy
              replaced = true
              break

          if not replaced:
            items.add result.copy

          okf.save()

          let spaceName = `jsonStringFieldSym`(result, "space", "default")
          let spacePath = okf.rootPath / spaceName
          if not dirExists(spacePath):
            raise newException(
              PlasticInstallationError,
              "Espaço OKF ausente. Ele deve ser criado pelo MSI: " & spacePath
            )
          writeJsonFile(spacePath / (`jsonStringFieldSym`(result, "id") & ".json"), result)

        proc tree*(okf: PlasticOkfRuntime): JsonNode =
          result = newJObject()
          for item in okf.list().items:
            let space = `jsonStringFieldSym`(item, "space", "default")
            if not result.hasKey(space):
              result[space] = newJArray()
            result[space].add %*{
              "id": `jsonStringFieldSym`(item, "id"),
              "title": `jsonStringFieldSym`(item, "title")
            }

        proc deriveOkfSpaces(plan: PlasticPlan): JsonNode =
          result = newJObject()
          let section = findPlanSection(plan, "okfs")
          if section.isNone:
            return

          for spaceNode in planChildren(section.get):
            let spaceName = positionalIdentityName(spaceNode)
            if spaceName.len == 0:
              continue
            result[spaceName] = parseOkfNode(spaceNode)
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        `applicationVariable`.okfValue.spaces =
          deriveOkfSpaces(`applicationVariable`.planValue)
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("modules"):
      let modulesBody = callBodyAst(section)
      result.add quote do:
        proc appendPlasticModuleFragment(
          application: PlasticApplication;
          serializedFragment: string
        ) =
          let fragment = parseJson(serializedFragment)
          if fragment.kind != JObject or
              not fragment.hasKey("children") or
              fragment["children"].kind != JArray:
            return

          for child in fragment["children"].items:
            appendPlasticPlanSection(application, $child)
      if modulesBody.kind == nnkStmtList:
        for index in 0 ..< modulesBody.len:
          let fragmentNode = modulesBody[index]
          let fragmentName = callNameAst(fragmentNode)
          if fragmentName.len == 0:
            continue
          result.add newCall(
            ident("appendPlasticModuleFragment"),
            applicationVariable.copyNimTree,
            parseExpr(fragmentName)
          )
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("components"):
      result.add quote do:
        proc plasticComponentStateExists(
          states: PlasticStateRuntime;
          name: string
        ): bool =
          if states.values.hasKey(name):
            return true
          for key in states.values.keys:
            if key.cmpIgnoreCase(name) == 0:
              return true
          false

        proc plasticComponentStateKey(
          states: PlasticStateRuntime;
          name: string
        ): string =
          if states.values.hasKey(name):
            return name
          for key in states.values.keys:
            if key.cmpIgnoreCase(name) == 0:
              return key
          ""

        proc plasticComponentStateGet(
          states: PlasticStateRuntime;
          name: string
        ): JsonNode =
          let key = plasticComponentStateKey(states, name)
          if key.len > 0:
            states.values[key]
          else:
            newJNull()

        proc plasticComponentStateSet(
          states: PlasticStateRuntime;
          name: string;
          value: JsonNode
        ) =
          let key = plasticComponentStateKey(states, name)
          let targetName = if key.len > 0: key else: name
          let previous =
            if states.values.hasKey(targetName): states.values[targetName].copy
            else: newJNull()
          states.values[targetName] = value.copy
          if previous == value:
            return
          if states.listeners.hasKey(targetName):
            let change = PlasticStateChange(
              name: targetName,
              path: name,
              previousValue: previous,
              currentValue: value.copy,
              changedAt: now()
            )
            for listener in states.listeners[targetName]:
              listener(change)

        proc plasticComponentStateOnChanged(
          states: PlasticStateRuntime;
          name: string;
          listener: PlasticStateListener
        ) =
          let key = plasticComponentStateKey(states, name)
          let targetName = if key.len > 0: key else: name
          states.listeners.mgetOrPut(targetName, @[]).add listener


        proc newForeignRuntime*(): PlasticForeignRuntime =
          PlasticForeignRuntime(
            backend: nil,
            elements: initTable[string, PlasticForeignElementRuntime](),
            onUrlChanged: nil,
            onEvent: nil
          )

        proc registerBackend*(runtime: PlasticForeignRuntime; backend: PlasticForeignBackend) =
          if backend.isNil:
            raise newException(PlasticForeignBackendError, "Backend foreign inválido")
          runtime.backend = backend

        proc normalizedForeignUrl*(value: string): string

        proc requireBackend(runtime: PlasticForeignRuntime): PlasticForeignBackend =
          if runtime.backend.isNil:
            raise newException(
              PlasticForeignBackendError,
              "Nenhum backend nativo de WebContentsView foi registrado. " &
              "Registre WebView2, WebKitGTK ou WKWebView antes de abrir a aplicação."
            )
          runtime.backend

        proc define*(
          runtime: PlasticForeignRuntime;
          path: string;
          url = "about:blank"
        ): PlasticForeignElementRuntime =
          let initialUrl = normalizedForeignUrl(url)
          result = PlasticForeignElementRuntime(
            path: path,
            componentName: "",
            variableName: "",
            identityName: "",
            url: initialUrl,
            urlStateName: "",
            currentUrl: initialUrl,
            status: pfsIdle,
            statusCss: initTable[string, string](),
            documentStartScripts: @[],
            eventPlans: newJArray(),
            lastMessage: newJNull(),
            lastError: newJNull(),
            eventHandler: nil
          )

          let runtimeRef = runtime
          result.eventHandler = proc(eventPath, eventName: string) =
            if not runtimeRef.onEvent.isNil:
              runtimeRef.onEvent(eventPath, eventName)

          runtime.elements[path] = result

        proc describe*(runtime: PlasticForeignRuntime; path: string): JsonNode =
          if not runtime.elements.hasKey(path):
            return newJNull()
          let element = runtime.elements[path]
          result = %*{
            "path": element.path,
            "componentName": element.componentName,
            "variableName": element.variableName,
            "identityName": element.identityName,
            "url": element.url,
            "currentUrl": element.currentUrl,
            "urlStateName": element.urlStateName,
            "status": $element.status,
            "documentStartScripts": element.documentStartScripts,
            "events": element.eventPlans
          }
          result["statusCss"] = newJObject()
          for statusName, css in element.statusCss:
            result["statusCss"][statusName] = %css

        proc list*(runtime: PlasticForeignRuntime): JsonNode =
          result = newJArray()
          for path in runtime.elements.keys.toSeq.sorted:
            result.add runtime.describe(path)

        proc create*(runtime: PlasticForeignRuntime; path: string) =
          if not runtime.elements.hasKey(path):
            raise newException(PlasticForeignBackendError, "Elemento foreign inexistente: " & path)
          let element = runtime.elements[path]
          let backend = runtime.requireBackend()
          backend.create(element)
          for script in element.documentStartScripts:
            backend.injectDocumentStart(element, script)
          backend.navigate(element, normalizedForeignUrl(element.url))

        proc notifyUrlChanged*(
          runtime: PlasticForeignRuntime;
          path, url: string
        ) =
          if not runtime.elements.hasKey(path):
            return

          let normalized = normalizedForeignUrl(url)
          let element = runtime.elements[path]
          plasticDebugTrace(
            "foreign.notifyUrlChanged path=" & path &
            " url=" & normalized &
            " stateName=" & element.urlStateName
          )
          element.url = normalized
          element.currentUrl = normalized

          if not runtime.onUrlChanged.isNil:
            runtime.onUrlChanged(path, normalized)

        proc notifyEvent*(
          runtime: PlasticForeignRuntime;
          path, eventName: string
        ) =
          if not runtime.elements.hasKey(path):
            return

          let element = runtime.elements[path]
          if not element.eventHandler.isNil:
            element.eventHandler(path, eventName)

        proc navigate*(runtime: PlasticForeignRuntime; path, url: string) =
          if not runtime.elements.hasKey(path):
            raise newException(PlasticForeignBackendError, "Elemento foreign inexistente: " & path)

          let normalized = normalizedForeignUrl(url)
          let element = runtime.elements[path]
          plasticDebugTrace(
            "foreign.navigate path=" & path &
            " url=" & normalized &
            " current=" & element.currentUrl &
            " stateName=" & element.urlStateName
          )
          element.url = normalized

          if element.currentUrl == normalized and
              element.status in {pfsLoading, pfsReady, pfsNavigating}:
            return

          element.status = pfsNavigating
          element.currentUrl = normalized
          runtime.requireBackend.navigate(element, normalized)

        proc evalJs*(runtime: PlasticForeignRuntime; path, script: string; timeoutMs = 15_000): JsonNode =
          if not runtime.elements.hasKey(path):
            raise newException(PlasticForeignBackendError, "Elemento foreign inexistente: " & path)
          runtime.requireBackend.evalJs(runtime.elements[path], script, timeoutMs)

        proc injectDocumentStart*(runtime: PlasticForeignRuntime; path, script: string) =
          if not runtime.elements.hasKey(path):
            raise newException(PlasticForeignBackendError, "Elemento foreign inexistente: " & path)
          runtime.requireBackend.injectDocumentStart(runtime.elements[path], script)

        proc close*(runtime: PlasticForeignRuntime; path: string) =
          if runtime.elements.hasKey(path):
            runtime.requireBackend.close(runtime.elements[path])
            runtime.elements[path].status = pfsClosed

        proc normalizedForeignUrl*(value: string): string =
          let candidate = value.strip
          if candidate.len == 0:
            return "about:blank"

          let lower = candidate.toLowerAscii
          if lower.startsWith("about:") or
              lower.startsWith("file:") or
              lower.startsWith("data:") or
              lower.startsWith("http://") or
              lower.startsWith("https://"):
            return candidate

          result = "https://" & candidate

        proc goBack*(runtime: PlasticForeignRuntime; path: string) =
          discard runtime.evalJs(path, "history.back(); true")

        proc goForward*(runtime: PlasticForeignRuntime; path: string) =
          discard runtime.evalJs(path, "history.forward(); true")

        proc reload*(runtime: PlasticForeignRuntime; path: string) =
          discard runtime.evalJs(path, "location.reload(); true")

        proc newMockForeignBackend*(): PlasticForeignBackend =
          result = PlasticForeignBackend(name: "mock")
          result.create = proc(element: PlasticForeignElementRuntime) =
            element.status = pfsIdle
          result.navigate = proc(element: PlasticForeignElementRuntime; url: string) =
            element.currentUrl = url
            element.status = pfsReady
            if not element.eventHandler.isNil:
              element.eventHandler(element.path, "loaded")
          result.evalJs = proc(
            element: PlasticForeignElementRuntime;
            script: string;
            timeoutMs: int
          ): JsonNode =
            %*{
              "mock": true,
              "path": element.path,
              "script": script,
              "timeoutMs": timeoutMs
            }
          result.injectDocumentStart = proc(
            element: PlasticForeignElementRuntime;
            script: string
          ) =
            discard
          result.applyLayoutSnapshot = proc(
            element: PlasticForeignElementRuntime;
            payload: string
          ) =
            discard
          result.close = proc(element: PlasticForeignElementRuntime) =
            element.status = pfsClosed


        proc normalizedWebViewFolder(path: string): string =
          let candidate = path.strip
          if candidate.len == 0:
            raise newException(
              PlasticRuntimeError,
              "O user folder do WebView não pode ser vazio."
            )
          result = absolutePath(expandTilde(candidate))

        proc newWebViewRuntime*(
          applicationDataRoot: string
        ): PlasticWebViewRuntime =
          let userFolder =
            plasticWebViewProfileRoot(applicationDataRoot)

          PlasticWebViewRuntime(
            userFolder: userFolder,
            dataFolder: userFolder / "data",
            cacheFolder: userFolder / "cache",
            cookiesPath: userFolder / "cookies.sqlite",
            persistent: true,
            persistentCookies: true,
            acceptThirdPartyCookies: true,
            safeGraphics: false,
            configured: false,
            storagePrepared: false,
            initialized: false
          )

        proc configureUserFolder*(
          runtime: PlasticWebViewRuntime;
          userFolder: string;
          persistent = true;
          cacheFolder = ""
        ) =
          ## Configura o perfil antes da criação do primeiro WebView.
          ##
          ## Linux/WebKitGTK:
          ##   userFolder/data  -> base-data-directory
          ##   userFolder/cache -> base-cache-directory
          ##
          ## Windows/WebView2:
          ##   userFolder também é publicado em WEBVIEW2_USER_DATA_FOLDER para o
          ##   backend WebView2/SWT que será registrado na plataforma.
          if runtime.isNil:
            raise newException(
              PlasticRuntimeError,
              "Runtime WebView inexistente."
            )

          if runtime.initialized:
            raise newException(
              PlasticRuntimeError,
              "O user folder do WebView não pode ser alterado depois da criação dos WebViews."
            )

          let resolvedUserFolder =
            normalizedWebViewFolder(userFolder)

          runtime.userFolder =
            resolvedUserFolder

          runtime.dataFolder =
            resolvedUserFolder / "data"

          runtime.cacheFolder =
            if cacheFolder.strip.len > 0:
              normalizedWebViewFolder(cacheFolder)
            else:
              resolvedUserFolder / "cache"

          runtime.cookiesPath =
            resolvedUserFolder / "cookies.sqlite"

          runtime.persistent = persistent
          runtime.configured = true
          runtime.storagePrepared = false

        proc configureClientFolder*(
          runtime: PlasticWebViewRuntime;
          clientFolder: string;
          persistent = true;
          cacheFolder = ""
        ) =
          configureUserFolder(
            runtime,
            clientFolder,
            persistent,
            cacheFolder
          )

        proc configureCompatibility*(
          runtime: PlasticWebViewRuntime;
          persistentCookies = true;
          acceptThirdPartyCookies = true;
          safeGraphics = false
        ) =
          ## Configuração destinada a aplicações web completas, como mensageiros,
          ## dashboards e portais que usam cookies entre domínios.
          if runtime.isNil:
            raise newException(
              PlasticRuntimeError,
              "Runtime WebView inexistente."
            )

          if runtime.initialized:
            raise newException(
              PlasticRuntimeError,
              "A compatibilidade WebView deve ser configurada antes de run()."
            )

          runtime.persistentCookies = persistentCookies
          runtime.acceptThirdPartyCookies = acceptThirdPartyCookies
          runtime.safeGraphics = safeGraphics
          runtime.configured = true

        proc useEphemeralProfile*(
          runtime: PlasticWebViewRuntime
        ) =
          if runtime.isNil:
            return

          if runtime.initialized:
            raise newException(
              PlasticRuntimeError,
              "O perfil WebView não pode ser alterado depois da inicialização."
            )

          runtime.persistent = false
          runtime.configured = true
          runtime.storagePrepared = false

        proc prepareStorage*(
          runtime: PlasticWebViewRuntime
        ) =
          if runtime.isNil:
            raise newException(
              PlasticRuntimeError,
              "Runtime WebView inexistente durante a preparação do perfil."
            )

          if not runtime.persistent:
            runtime.storagePrepared = true
            return

          for path in [runtime.userFolder, runtime.dataFolder, runtime.cacheFolder]:
            if fileExists(path):
              raise newException(
                PlasticInstallationError,
                "O caminho reservado ao perfil WebView é um arquivo: " & path
              )

          try:
            createDir(runtime.userFolder)
            createDir(runtime.dataFolder)
            createDir(runtime.cacheFolder)
          except CatchableError as error:
            raise newException(
              PlasticInstallationError,
              "Não foi possível preparar o user folder do WebView em " &
              runtime.userFolder & ": " & error.msg
            )

          if not dirExists(runtime.userFolder) or
              not dirExists(runtime.dataFolder) or
              not dirExists(runtime.cacheFolder):
            raise newException(
              PlasticInstallationError,
              "User folder WebView incompleto: " &
              runtime.userFolder
            )

          # Marca o perfil para diagnóstico e confirma que a pasta é gravável.
          try:
            writeFile(
              runtime.userFolder / "glaucoplastic-profile.json",
              pretty(%*{
                "version": 1,
                "userFolder": runtime.userFolder,
                "dataFolder": runtime.dataFolder,
                "cacheFolder": runtime.cacheFolder,
                "cookiesPath": runtime.cookiesPath,
                "persistent": runtime.persistent
              })
            )
          except CatchableError as error:
            raise newException(
              PlasticInstallationError,
              "O perfil WebView não é gravável em " &
              runtime.userFolder & ": " & error.msg
            )

          when defined(windows):
            # Deve existir antes de qualquer Environment WebView2 ser criado.
            putEnv(
              "WEBVIEW2_USER_DATA_FOLDER",
              runtime.userFolder
            )

          runtime.storagePrepared = true

        proc describe*(
          runtime: PlasticWebViewRuntime
        ): JsonNode =
          if runtime.isNil:
            return newJNull()

          %*{
            "userFolder": runtime.userFolder,
            "dataFolder": runtime.dataFolder,
            "cacheFolder": runtime.cacheFolder,
            "cookiesPath": runtime.cookiesPath,
            "persistent": runtime.persistent,
            "persistentCookies": runtime.persistentCookies,
            "acceptThirdPartyCookies": runtime.acceptThirdPartyCookies,
            "safeGraphics": runtime.safeGraphics,
            "configured": runtime.configured,
            "storagePrepared": runtime.storagePrepared,
            "initialized": runtime.initialized
          }

        proc collectRenderNodes(node: JsonNode; output: var JsonNode; componentName = "") =
          if planKind(node) == "call" and planName(node) == "render":
            for child in planChildren(node):
              var copyNode = child.copy
              if componentName.len > 0:
                copyNode["component"] = %componentName
              output.add copyNode

          for child in planChildren(node):
            collectRenderNodes(child, output, componentName)

        proc deriveComponents(plan: PlasticPlan): JsonNode =
          result = newJArray()
          let section = findPlanSection(plan, "components")
          if section.isNone:
            return
          for component in planChildren(section.get):
            result.add component.copy

        proc deriveRenderTree(plan: PlasticPlan): JsonNode =
          result = newJArray()
          let components = findPlanSection(plan, "components")
          if components.isSome:
            for component in planChildren(components.get):
              collectRenderNodes(component, result, planName(component))

          let globalRender = findPlanSection(plan, "render")
          if globalRender.isSome:
            for child in planChildren(globalRender.get):
              result.add child.copy

        proc namedArgumentValue(node: JsonNode; name: string): JsonNode =
          let value = callNamedArgument(node, name)
          if value.isSome:
            return planValueOrName(value.get)
          newJNull()

        proc boundStateName(node: JsonNode): string =
          ## Reconhece exclusivamente a forma especial da DSL:
          ##
          ##   url = binds states.Nome
          ##
          ## Outras formas, como `binds(states.Nome)`, não recebem a semântica
          ## especial de binding e seguem como expressões comuns da DSL.
          if node.isNil:
            return ""

          if planKind(node) in ["identifier", "path"]:
            let path = planName(node).split('.')
            if path.len > 1 and path[0].toLowerAscii in ["state", "states"]:
              return path[1 .. ^1].join(".")
            return ""

          if planKind(node) != "call" or planName(node) != "binds":
            return ""

          let source = planSource(node).strip
          if not source.startsWith("binds "):
            return ""

          let arguments = planArguments(node)
          if arguments.len != 1:
            return ""

          if planKind(arguments[0]) == "call" and
              planName(arguments[0]) in ["state", "states"]:
            let stateArguments = planArguments(arguments[0])
            if stateArguments.len != 1:
              return ""
            let path = planName(stateArguments[0]).split('.')
            if path.len > 0 and path[0].len > 0:
              return path.join(".")

          let path = planName(arguments[0]).split('.')
          if path.len > 0 and path[0].len > 0 and path[0] notin ["state", "states"]:
            return path.join(".")

          result = ""

        proc resolveBoundStateValue(
          states: PlasticStateRuntime;
          pathText: string
        ): JsonNode =
          let path = pathText.split('.')
          if path.len == 0 or path[0].len == 0:
            return newJNull()

          if not plasticComponentStateExists(states, path[0]):
            return newJNull()

          result = plasticComponentStateGet(states, path[0])
          if path.len == 1:
            return

          var current = result
          for index in 1 ..< path.len:
            if current.kind != JObject or not current.hasKey(path[index]):
              return newJNull()
            current = current[path[index]]

          result = current.copy

        proc configureForeignElement(
          element: PlasticForeignElementRuntime;
          node: JsonNode
        )

        proc foreignEventName(
          listener: JsonNode;
          variableName = ""
        ): string =
          if listener.isNil or planKind(listener) != "when" or
              not listener.hasKey("condition"):
            return ""

          let condition = listener["condition"]

          if planKind(condition) == "identifier":
            return planName(condition)

          if planKind(condition) == "call":
            let conditionName = planName(condition)

            if variableName.len > 0 and conditionName == variableName:
              let arguments = planArguments(condition)
              if arguments.len > 0:
                return planName(arguments[0])

            if conditionName in ["loaded", "loading", "failed", "ready"]:
              return conditionName

          result = ""

        proc newForeignRenderReference(
          node: JsonNode;
          componentName, variableName: string
        ): JsonNode =
          result = newJObject()
          result["__glaucoElementReference"] = %"foreign"
          result["componentName"] = %componentName
          result["variableName"] = %variableName
          result["node"] = node.copy

        proc defineForeignFromPlan(
          application: PlasticApplication;
          node: JsonNode;
          componentName: string;
          variableName = ""
        ): PlasticForeignElementRuntime =
          let urlArgument = callNamedArgument(node, "url")
          let identityName = positionalIdentityName(node)

          if identityName.len == 0:
            raise newException(
              PlasticForeignBackendError,
              "Foreign sem identidade posicional no componente " & componentName
            )

          let path =
            if componentName.len > 0:
              componentName & "." & identityName
            else:
              identityName

          var url = "about:blank"
          var urlStateName = ""

          if urlArgument.isSome:
            urlStateName = boundStateName(urlArgument.get)
            if urlStateName.len > 0:
              let stateValue = resolveBoundStateValue(
                application.statesValue,
                urlStateName
              )
              case stateValue.kind
              of JString:
                url = stateValue.getStr
              of JNull:
                url = "about:blank"
              else:
                url = $stateValue
            else:
              let urlValue = planValueOrName(urlArgument.get)
              if urlValue.kind == JString:
                url = urlValue.getStr
              else:
                case urlValue.kind
                of JNull:
                  url = "about:blank"
                of JBool:
                  url = if urlValue.getBool: "true" else: "false"
                of JInt:
                  url = $urlValue.getInt
                of JFloat:
                  url = $urlValue.getFloat
                else:
                  url = $urlValue

          result = application.foreignValue.define(path, url)
          result.componentName = componentName
          result.variableName = variableName
          result.identityName = identityName
          result.urlStateName = urlStateName
          configureForeignElement(result, node)

        proc configureForeignElement(element: PlasticForeignElementRuntime; node: JsonNode) =
          for child in planChildren(node):
            if planKind(child) == "call" and planName(child) == "statusCss":
              for statusDeclaration in planChildren(child):
                let css = firstLiteralString(statusDeclaration)
                if css.len > 0:
                  element.statusCss[planName(statusDeclaration)] = css

            elif planKind(child) == "call" and planName(child) == "documentStart":
              for scriptDeclaration in planChildren(child):
                if planKind(scriptDeclaration) == "call" and planName(scriptDeclaration) == "evalJs":
                  let script = firstLiteralString(scriptDeclaration)
                  if script.len > 0:
                    element.documentStartScripts.add script

            elif planKind(child) == "when":
              element.eventPlans.add child.copy

        proc deriveForeignElements(application: PlasticApplication) =
          proc visitInlineForeign(node: JsonNode; componentName: string) =
            if planKind(node) == "call" and planName(node) == "foreign":
              discard application.defineForeignFromPlan(
                node,
                componentName
              )

            for child in planChildren(node):
              visitInlineForeign(child, componentName)

          let components = findPlanSection(application.planValue, "components")
          if components.isNone:
            return

          for component in planChildren(components.get):
            let componentName = planName(component)
            var variables = initTable[
              string,
              PlasticForeignElementRuntime
            ]()

            # Elementos podem ser guardados em variáveis do componente:
            #
            #   portal = foreign Portal(...)
            #
            # `Portal` é a identidade declarativa; `portal` é apenas o handle Nim.
            for declaration in planChildren(component):
              if planKind(declaration) != "assignment" or
                  not declaration.hasKey("value"):
                continue

              let value = declaration["value"]
              if planKind(value) != "call" or planName(value) != "foreign":
                continue

              let variableName = planName(declaration)
              if variableName.len == 0:
                continue

              variables[variableName] = application.defineForeignFromPlan(
                value,
                componentName,
                variableName
              )

            # Listeners do componente podem observar eventos dos elementos guardados:
            #
            #   when Portal loaded:
            #     portal.evalJs "..."
            for declaration in planChildren(component):
              if planKind(declaration) != "when":
                continue

              for _, element in variables:
                if foreignEventName(declaration, element.identityName).len > 0:
                  element.eventPlans.add declaration.copy

            # Foreign inline no render também exige identidade posicional.
            for declaration in planChildren(component):
              if planKind(declaration) == "assignment" and
                  declaration.hasKey("value") and
                  planKind(declaration["value"]) == "call" and
                  planName(declaration["value"]) == "foreign":
                continue
              visitInlineForeign(declaration, componentName)


        proc htmlEscape(value: string): string =
          result = value
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#39;")

        proc htmlAttribute(value: string): string = htmlEscape(value)

        proc jsonText(value: JsonNode): string =
          case value.kind
          of JString:
            result = value.getStr
          of JNull:
            result = ""
          of JBool:
            result = if value.getBool: "true" else: "false"
          of JInt:
            result = $value.getInt
          of JFloat:
            result = $value.getFloat
          else:
            result = $value

        proc glaucoplasticJsonIntValue(value: JsonNode): int =
          case value.kind
          of JInt:
            result = value.getInt
          of JFloat:
            result = value.getFloat.int
          of JString:
            try:
              result = parseInt(value.getStr)
            except ValueError:
              result = 0
          of JBool:
            result = if value.getBool: 1 else: 0
          else:
            result = 0

        proc installForeignUrlBindings(application: PlasticApplication) =
          ## Liga `url = binds states.X` nas duas direções.
          ## estado -> WebView: navega quando o estado muda;
          ## WebView -> estado: o backend chama notifyUrlChanged.
          let applicationRef = application

          application.foreignValue.onUrlChanged = proc(path, url: string) =
            if not applicationRef.foreignValue.elements.hasKey(path):
              return

            let element = applicationRef.foreignValue.elements[path]
            if element.urlStateName.len == 0 or
                not plasticComponentStateExists(applicationRef.statesValue, element.urlStateName):
              return

            let current = jsonText(
              resolveBoundStateValue(
                applicationRef.statesValue,
                element.urlStateName
              )
            )
            if current != url:
              plasticComponentStateSet(applicationRef.statesValue, element.urlStateName, %url)

          for path, element in application.foreignValue.elements:
            if element.urlStateName.len == 0:
              continue

            let boundStatePath = element.urlStateName.split('.')
            if boundStatePath.len == 0 or boundStatePath[0].len == 0 or
                not plasticComponentStateExists(application.statesValue, boundStatePath[0]):
              continue

            let boundPath = path
            let boundState = boundStatePath[0]
            let boundStateName = element.urlStateName
            plasticComponentStateOnChanged(application.statesValue,
              boundState,
              proc(change: PlasticStateChange) =
                let targetValue = resolveBoundStateValue(
                  applicationRef.statesValue,
                  boundStateName
                )
                let targetUrl = normalizedForeignUrl(jsonText(targetValue))
                let boundElement = applicationRef.foreignValue.elements[boundPath]
                boundElement.url = targetUrl

                if boundElement.currentUrl == targetUrl:
                  return

                if applicationRef.foreignValue.backend.isNil:
                  boundElement.currentUrl = targetUrl
                  return

                applicationRef.foreignValue.navigate(boundPath, targetUrl)
            )

        proc jsonPathValue(value: JsonNode; path: seq[string]): JsonNode =
          var current = value
          for segment in path:
            case current.kind
            of JObject:
              if not current.hasKey(segment):
                return newJNull()
              current = current[segment]
            of JArray:
              try:
                let index = parseInt(segment)
                if index < 0 or index >= current.len:
                  return newJNull()
                current = current[index]
              except ValueError:
                return newJNull()
            else:
              return newJNull()
          result = current.copy

        proc resolveRenderValue(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment
        ): JsonNode

        proc renderTruthiness(value: JsonNode): bool =
          case value.kind
          of JNull:
            false
          of JBool:
            value.getBool
          of JInt:
            value.getInt != 0
          of JFloat:
            value.getFloat != 0
          of JString:
            value.getStr.len > 0
          of JArray, JObject:
            value.len > 0
          else:
            true

        proc renderNumericValue(value: JsonNode; available: var bool): float =
          available = true
          case value.kind
          of JInt:
            value.getInt.float
          of JFloat:
            value.getFloat
          of JString:
            try:
              parseFloat(value.getStr.strip)
            except CatchableError:
              available = false
              0.0
          of JBool:
            if value.getBool: 1.0 else: 0.0
          else:
            available = false
            0.0

        proc resolveRenderCondition(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment
        ): bool =
          if node.isNil:
            return false

          let value = application.resolveRenderValue(node, environment)
          if renderTruthiness(value):
            return true

          if planKind(node) != "expression":
            return false

          let children = planChildren(node)
          if children.len == 0:
            return false

          if children.len == 2 and planKind(children[0]) == "identifier" and
              planName(children[0]) == "not":
            return not application.resolveRenderCondition(children[1], environment)

          if children.len == 3 and planKind(children[0]) == "identifier":
            let operator = planName(children[0])
            let leftValue = application.resolveRenderValue(children[1], environment)
            let rightValue = application.resolveRenderValue(children[2], environment)

            case operator
            of "==":
              return leftValue == rightValue or
                jsonText(leftValue) == jsonText(rightValue)
            of "!=":
              return not (leftValue == rightValue or
                jsonText(leftValue) == jsonText(rightValue))
            of "and":
              return application.resolveRenderCondition(children[1], environment) and
                application.resolveRenderCondition(children[2], environment)
            of "or":
              return application.resolveRenderCondition(children[1], environment) or
                application.resolveRenderCondition(children[2], environment)
            of "<", ">", "<=", ">=":
              var leftOk = false
              var rightOk = false
              let leftNumeric = renderNumericValue(leftValue, leftOk)
              let rightNumeric = renderNumericValue(rightValue, rightOk)

              if leftOk and rightOk:
                case operator
                of "<":
                  return leftNumeric < rightNumeric
                of ">":
                  return leftNumeric > rightNumeric
                of "<=":
                  return leftNumeric <= rightNumeric
                of ">=":
                  return leftNumeric >= rightNumeric
                else:
                  discard

              let leftText = jsonText(leftValue)
              let rightText = jsonText(rightValue)
              case operator
              of "<":
                return leftText < rightText
              of ">":
                return leftText > rightText
              of "<=":
                return leftText <= rightText
              of ">=":
                return leftText >= rightText
              else:
                discard
            else:
              discard

          renderTruthiness(value)

        proc resolveRenderMap(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment
        ): JsonNode =
          result = newJObject()
          for entry in planChildren(node):
            if planKind(entry) == "mapEntry" and entry.hasKey("value"):
              result[planName(entry)] = application.resolveRenderValue(
                entry["value"],
                environment
              )

        proc resolveRenderValue(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment
        ): JsonNode =
          if node.isNil:
            return newJNull()

          if planKind(node) == "literal" and node.hasKey("literal"):
            return node["literal"].copy

          case planKind(node)
          of "identifier":
            let identifier = planName(node)
            let lowered = identifier.toLowerAscii
            if lowered.startsWith("state.") or lowered.startsWith("states.") or
                lowered == "state" or lowered == "states":
              return glaucoplasticResolveStatePathText(
                application.statesValue,
                identifier
              )
            if environment.hasKey(identifier):
              return environment[identifier].copy
            return %identifier

          of "path":
            let pathText = planName(node)
            let lowered = pathText.toLowerAscii
            if lowered.startsWith("state.") or lowered.startsWith("states.") or
                lowered == "state" or lowered == "states":
              return glaucoplasticResolveStatePathText(
                application.statesValue,
                pathText
              )

            let parts = pathText.split('.')
            if parts.len > 0 and environment.hasKey(parts[0]):
              let root = environment[parts[0]]
              if parts.len == 1:
                return root.copy
              return jsonPathValue(root, parts[1 .. ^1])

            return newJNull()

          of "call":
            # Somente a forma de comando `binds state X` recebe significado na DSL.
            # `binds(state X)` permanece uma chamada comum e não cria binding.
            if planName(node) == "binds" and planSource(node).strip.startsWith("binds "):
              let arguments = planArguments(node)
              if arguments.len == 1:
                let argument = arguments[0]
                if planKind(argument) == "call" and
                    planName(argument) in ["state", "states"]:
                  let stateArguments = planArguments(argument)
                  if stateArguments.len == 1:
                    return application.resolveRenderValue(stateArguments[0], environment)
                return application.resolveRenderValue(argument, environment)
            if planName(node) in ["state", "states"]:
              let arguments = planArguments(node)
              if arguments.len == 1:
                let parts = planName(arguments[0]).split('.')
                if parts.len == 0:
                  return newJNull()
                if not plasticComponentStateExists(application.statesValue, parts[0]):
                  return newJNull()
                let root = plasticComponentStateGet(application.statesValue, parts[0])
                if parts.len == 1:
                  return root.copy
                return jsonPathValue(root, parts[1 .. ^1])
            return newJNull()

          of "map":
            return application.resolveRenderMap(node, environment)

          of "expression":
            # Expressões de programa não são interpretadas pelo runtime visual.
            # Valores dinâmicos devem chegar por parâmetro ou por states.<Nome>.
            return newJNull()

          of "namedArgument":
            if node.hasKey("value"):
              return application.resolveRenderValue(node["value"], environment)
            return newJNull()

          of "assignment":
            if node.hasKey("value"):
              return application.resolveRenderValue(node["value"], environment)
            return newJNull()

          else:
            let literal = literalOrNull(node)
            if literal.kind != JNull:
              return literal
            return newJNull()

        proc componentDefinition(
          application: PlasticApplication;
          componentName: string
        ): Option[JsonNode] =
          if application.componentsValue.kind != JArray:
            return none(JsonNode)
          for component in application.componentsValue.items:
            if planName(component) == componentName:
              return some(component)
          result = none(JsonNode)

        proc sanitizeTagName(value: string): string =
          for character in value:
            if character.isAlphaNumeric or character in {'-', '_'}:
              result.add character
          if result.len == 0:
            result = "div"

        proc sanitizeCustomElementName(value: string): string =
          var lastWasDash = false
          for character in value:
            if character.isAlphaNumeric:
              if character.isUpperAscii:
                let lowered = character.toLowerAscii()
                if result.len > 0 and not lastWasDash:
                  result.add '-'
                result.add lowered
                lastWasDash = false
              else:
                result.add character.toLowerAscii()
                lastWasDash = false
            else:
              if result.len > 0 and not lastWasDash:
                result.add '-'
                lastWasDash = true
          if result.len == 0:
            result = "node"
          if '-' notin result:
            result = "glauco-" & result

        proc customElementNameFor(
          name: string;
          identityPath: string
        ): string =
          let baseName =
            if identityPath.len > 0:
              identityPath.replace(".", "-")
            else:
              name
          result = sanitizeCustomElementName(baseName)

        proc renderPlanNodeHtml(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment;
          componentName = ""
        ): string

        proc renderComponentHtml(
          application: PlasticApplication;
          definition, invocation: JsonNode;
          parentEnvironment: PlasticRenderEnvironment
        ): string =
          var environment = parentEnvironment
          let parameters = planArguments(definition)
          let values = planArguments(invocation)

          var positionalIndex = 0
          for parameter in parameters:
            if planKind(parameter) != "identifier":
              continue
            var value = newJNull()
            while positionalIndex < values.len:
              let argument = values[positionalIndex]
              inc positionalIndex
              if planKind(argument) != "namedArgument":
                value = application.resolveRenderValue(argument, parentEnvironment)
                break
            environment[planName(parameter)] = value

          for child in planChildren(definition):
            if planKind(child) == "assignment" and child.hasKey("value"):
              let localName = planName(child)
              if localName.len == 0:
                continue

              let value = child["value"]
              if planKind(value) == "call" and planName(value) == "foreign":
                environment[localName] = newForeignRenderReference(
                  value,
                  planName(definition),
                  localName
                )
              else:
                environment[localName] = application.resolveRenderValue(
                  value,
                  environment
                )

          for child in planChildren(definition):
            if planKind(child) == "call" and planName(child) == "render":
              for renderNode in planChildren(child):
                result.add application.renderPlanNodeHtml(
                  renderNode,
                  environment,
                  planName(definition)
                )

        proc renderForeignPlaceholder(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment;
          componentName: string;
          variableName = ""
        ): string =
          let urlNode = callNamedArgument(node, "url")
          let classNode = callNamedArgument(node, "class")
          let styleNode = callNamedArgument(node, "style")
          let titleNode = callNamedArgument(node, "title")

          let identityName = positionalIdentityName(node)
          if identityName.len == 0:
            raise newException(
              PlasticForeignBackendError,
              "Foreign sem identidade posicional no componente " & componentName
            )

          let path =
            if componentName.len > 0:
              componentName & "." & identityName
            else:
              identityName

          let urlStateName =
            if urlNode.isSome:
              boundStateName(urlNode.get)
            else:
              ""

          if urlNode.isSome:
            plasticDebugTrace(
              "renderForeignPlaceholder urlNode kind=" & planKind(urlNode.get) &
              " name=" & planName(urlNode.get) &
              " source=" & planSource(urlNode.get)
            )

          let url = normalizedForeignUrl(
            if urlNode.isSome:
              jsonText(application.resolveRenderValue(urlNode.get, environment))
            else:
              "about:blank"
          )

          if application.foreignValue.elements.hasKey(path):
            let element = application.foreignValue.elements[path]
            element.componentName = componentName
            element.variableName = variableName
            element.identityName = identityName
            element.url = url
            element.urlStateName = urlStateName
            if element.status == pfsIdle:
              element.currentUrl = url

          let className =
            if classNode.isSome:
              jsonText(application.resolveRenderValue(classNode.get, environment))
            else:
              ""

          let styleValue =
            if styleNode.isSome:
              jsonText(application.resolveRenderValue(styleNode.get, environment))
            else:
              ""

          let titleValue =
            if titleNode.isSome:
              jsonText(application.resolveRenderValue(titleNode.get, environment))
            else:
              ""

          result = "<div class=\"glauco-foreign " & htmlAttribute(className) &
            "\" data-glauco-foreign=\"" & htmlAttribute(path) &
            "\" data-glauco-url=\"" & htmlAttribute(url) & "\""

          if urlStateName.len > 0:
            result.add " data-glauco-url-bind-state=\"" &
              htmlAttribute(urlStateName) & "\""

          if styleValue.len > 0:
            result.add " style=\"" & htmlAttribute(styleValue) & "\""
          if titleValue.len > 0:
            result.add " title=\"" & htmlAttribute(titleValue) & "\""

          result.add " data-status=\"loading\"></div>"

        proc renderPlanNodeHtml(
          application: PlasticApplication;
          node: JsonNode;
          environment: PlasticRenderEnvironment;
          componentName = ""
        ): string =
          if planKind(node) == "identifier":
            let localName = planName(node)
            if environment.hasKey(localName):
              let reference = environment[localName]
              if reference.kind == JObject and
                  `jsonStringFieldSym`(reference, "__glaucoElementReference") == "foreign" and
                  reference.hasKey("node"):
                return application.renderForeignPlaceholder(
                  reference["node"],
                  environment,
                  `jsonStringFieldSym`(reference, "componentName", componentName),
                  `jsonStringFieldSym`(reference, "variableName", localName)
                )
            return ""

          if planKind(node) in ["when", "if"]:
            for branch in planChildren(node):
              if planKind(branch) in ["whenBranch", "ifBranch"]:
                if not branch.hasKey("condition"):
                  continue
                if application.resolveRenderCondition(branch["condition"], environment):
                  for child in planChildren(branch):
                    result.add application.renderPlanNodeHtml(
                      child,
                      environment,
                      componentName
                    )
                  return
              elif planKind(branch) in ["whenElse", "ifElse"]:
                for child in planChildren(branch):
                  result.add application.renderPlanNodeHtml(
                    child,
                    environment,
                    componentName
                  )
                return
            return

          if planKind(node) in ["whenBranch", "whenElse", "ifBranch", "ifElse"]:
            for child in planChildren(node):
              result.add application.renderPlanNodeHtml(
                child,
                environment,
                componentName
              )
            return

          if planKind(node) != "call":
            return ""

          let name = planName(node)
          let component = application.componentDefinition(name)
          if component.isSome:
            return application.renderComponentHtml(
              component.get,
              node,
              environment
            )

          if name == "render":
            for child in planChildren(node):
              result.add application.renderPlanNodeHtml(
                child,
                environment,
                componentName
              )
            return

          if name == "foreign":
            return application.renderForeignPlaceholder(
              node,
              environment,
              componentName
            )

          let baseTagName = sanitizeTagName(name)
          var attributes = ""
          var content = ""
          let arguments = planArguments(node)
          let identityName = positionalIdentityName(node)
          let positionalIdentityIndex = if identityName.len > 0: 0 else: -1
          var eventNames: seq[string] = @[]
          var hostAttributes = ""
          var hostEventNames: seq[string] = @[]
          var identityPath = ""
          var boundStateName = ""

          for argumentIndex, argument in arguments:
            if planKind(argument) == "namedArgument":
              let attributeName = planName(argument)
              let value = application.resolveRenderValue(argument, environment)
              let text = jsonText(value)

              case attributeName
              of "bind":
                let statePath = planName(argument{"value"}).split('.')
                if statePath.len >= 2 and statePath[0] == "states":
                  boundStateName = statePath[1]
                  attributes.add " data-glauco-bind-state=\"" &
                    htmlAttribute(statePath[1]) & "\""
              of "class", "id", "style", "title", "role", "name", "value", "type",
                 "placeholder", "autocomplete", "spellcheck", "aria-label",
                 "href", "src", "rel", "media", "target", "download", "defer",
                 "async", "crossorigin", "integrity", "referrerpolicy":
                if baseTagName == "style" and attributeName == "src":
                  discard
                else:
                  attributes.add " " & attributeName & "=\"" & htmlAttribute(text) & "\""
              else:
                if attributeName.startsWith("data"):
                  attributes.add " " & attributeName & "=\"" & htmlAttribute(text) & "\""
            elif argumentIndex != positionalIdentityIndex:
              content.add htmlEscape(jsonText(
                application.resolveRenderValue(argument, environment)
              ))

          if identityName.len > 0:
            identityPath =
              if componentName.len > 0:
                componentName & "." & identityName
              else:
                identityName
            hostAttributes.add " data-glauco-identity=\"" &
              htmlAttribute(identityPath) & "\""
            hostAttributes.add " data-glauco-base-tag=\"" &
              htmlAttribute(baseTagName) & "\""
            hostAttributes.add " style=\"display: contents\""
            if boundStateName.len > 0:
              hostAttributes.add " data-glauco-bind-state=\"" &
                htmlAttribute(boundStateName) & "\""

            # Eventos declarados por `when Ir clicks:` são materializados
            # no HTML por meio do ID opaco da closure Nim registrada.
            for candidate in ["click", "change", "input", "blur", "enter", "connected"]:
              if application.uiHandlerId(identityPath, candidate).len > 0 and
                  candidate notin eventNames:
                if candidate == "connected":
                  hostEventNames.add candidate
                else:
                  hostAttributes.add " data-glauco-handler-" & candidate &
                    "=\"" & htmlAttribute(application.uiHandlerId(identityPath, candidate)) & "\""
                  eventNames.add candidate

            # Os atributos carregam somente IDs opacos de closures Nim. Nenhum
            # corpo Nim, AST serializado ou efeito JSON é enviado ao JavaScript.
            for eventName in hostEventNames:
              let handlerId = application.uiHandlerId(identityPath, eventName)
              if handlerId.len > 0:
                hostAttributes.add " data-glauco-handler-" & eventName &
                  "=\"" & htmlAttribute(handlerId) & "\""
            for eventName in eventNames:
              let handlerId = application.uiHandlerId(identityPath, eventName)
              if handlerId.len > 0:
                attributes.add " data-glauco-handler-" & eventName &
                  "=\"" & htmlAttribute(handlerId) & "\""

          for child in planChildren(node):
            content.add application.renderPlanNodeHtml(
              child,
              environment,
              componentName
            )

          if baseTagName == "style":
            let srcNode = callNamedArgument(node, "src")
            if srcNode.isSome:
              let hrefValue = jsonText(application.resolveRenderValue(srcNode.get, environment))
              result = "<link rel=\"stylesheet\"" & attributes &
                " href=\"" & htmlAttribute(hrefValue) & "\">"
              return

          const voidTags = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr"
          ]

          if identityName.len > 0:
            let innerTagName = baseTagName
            var innerHtml = ""
            if innerTagName in voidTags:
              innerHtml = "<" & innerTagName & attributes & ">"
            else:
              innerHtml = "<" & innerTagName & attributes & ">" & content &
                "</" & innerTagName & ">"
            let hostTagName = customElementNameFor(name, identityPath)
            result = "<" & hostTagName & hostAttributes & ">" & innerHtml &
              "</" & hostTagName & ">"
          elif baseTagName in voidTags:
            result = "<" & baseTagName & attributes & ">"
          else:
            result = "<" & baseTagName & attributes & ">" & content &
              "</" & baseTagName & ">"

        proc foreignStatusStyles(application: PlasticApplication): string =
          for path, element in application.foreignValue.elements:
            let selector = "[data-glauco-foreign=\"" & path.replace("\"", "\\\"") & "\"]"
            for statusName, css in element.statusCss:
              result.add css.replace(
                ":host",
                selector & "[data-status=\"" & statusName & "\"]"
              )
              result.add "\n"

        proc renderApplicationHtml*(application: PlasticApplication): string =
          var body = ""
          let rootRender = findPlanSection(application.planValue, "render")
          let environment = initTable[string, JsonNode]()

          if not application.assistantValue.isNil and
              application.assistantValue.config.enabled:
            body = plasticAssistantBodyHtml(application.assistantValue)
          elif rootRender.isSome:
            for node in planChildren(rootRender.get):
              body.add application.renderPlanNodeHtml(node, environment)
          elif application.componentsValue.kind == JArray and application.componentsValue.len > 0:
            let component = application.componentsValue[0]
            var invocation = component.copy
            invocation["arguments"] = newJArray()
            body.add application.renderComponentHtml(component, invocation, environment)

          if body.strip.len == 0:
            body = """
              <main style="min-height:100vh;background:#f8fafc;color:#0f172a;padding:24px">
                <h1>GlaucoPlastic</h1>
                <p>O plano da aplicação foi carregado, porém o render principal ficou vazio.</p>
              </main>
            """

          let title = htmlEscape(application.productValue.title)
          let statusStyles = application.foreignStatusStyles()
          let assistantStyles =
            if not application.assistantValue.isNil and
                application.assistantValue.config.enabled:
              plasticAssistantCss()
            else:
              ""
          let assistantScript =
            if not application.assistantValue.isNil and
                application.assistantValue.config.enabled:
              plasticAssistantScript(application.assistantValue)
            else:
              ""

          result = """<!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>""" & title & """</title>
          <style>
            :root { color-scheme: light dark; }
            * { box-sizing: border-box; }
            html, body {
              margin: 0;
              width: 100%;
              min-height: 100%;
              background: #f8fafc;
              color: #0f172a;
            }
            body {
              font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #f8fafc;
              color: #0f172a;
            }
            main { min-height: 100vh; padding: 24px; }
            h1 { margin: 0 0 18px; font-size: 28px; }
            .glauco-foreign {
              display: block;
              position: relative;
              z-index: 0;
              isolation: isolate;
              width: 100%;
              min-height: 460px;
              margin-top: 16px;
              overflow: visible;
              border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
              border-radius: 12px;
              background: color-mix(in srgb, Canvas 92%, CanvasText 8%);
            }
            .glauco-foreign::before {
              content: "Carregando conteúdo externo…";
              position: absolute;
              inset: 0;
              z-index: 1;
              display: grid;
              place-items: center;
              opacity: .65;
              pointer-events: none;
            }
            .glauco-foreign[data-status="ready"]::before {
              display: none;
            }
        """ & statusStyles & assistantStyles & """
          </style>
        </head>
        <body>
          <div id="glaucoplastic-application">""" & body & """</div>
          <script>
            (() => {
              window.__glaucoplasticEvents =
                window.__glaucoplasticEvents || [];
              window.__glaucoplasticEventDedupe =
                window.__glaucoplasticEventDedupe || new Map();
              window.__glaucoplasticDefinedElements =
                window.__glaucoplasticDefinedElements || new Set();
              window.__glaucoplasticForeignLayoutSnapshot =
                window.__glaucoplasticForeignLayoutSnapshot || [];
              window.__glaucoplasticForeignLayoutScheduled =
                window.__glaucoplasticForeignLayoutScheduled || false;
              window.__glaucoplasticForeignLayoutObserverInstalled =
                window.__glaucoplasticForeignLayoutObserverInstalled || false;

              function eventQueue() {
                return window.__glaucoplasticEvents ||
                  (window.__glaucoplasticEvents = []);
              }

              function handlerId(element, eventName) {
                if (!element || !element.dataset) return "";
                const suffix = eventName.charAt(0).toUpperCase() +
                  eventName.slice(1);
                return element.dataset["glaucoHandler" + suffix] || "";
              }

              function resolveValueElement(element) {
                if (!element) return element;
                if (element.tagName && element.tagName.includes("-")) {
                  const baseTag = (element.dataset &&
                    element.dataset.glaucoBaseTag) || "";
                  if (baseTag) {
                    const nested = element.querySelector(baseTag);
                    if (nested) return nested;
                  }
                  const fallback = element.querySelector(
                    '[data-glauco-bind-state],[data-glauco-handler-input],[data-glauco-handler-change]'
                  );
                  if (fallback) return fallback;
                }
                return element;
              }

              function resolveEventElement(event, selector) {
                if (!event) return null;
                if (event.target && event.target.closest) {
                  const closest = event.target.closest(selector);
                  if (closest) return closest;
                }
                if (event.composedPath) {
                  const path = event.composedPath();
                  for (const item of path) {
                    if (item && item.matches && item.matches(selector)) {
                      return item;
                    }
                  }
                }
                return null;
              }

              function emit(eventName, element, event) {
                const valueElement = resolveValueElement(element);
                const resolvedHandlerId = handlerId(element, eventName);
                const bindState = element && element.dataset
                  ? (element.dataset.glaucoBindState || "")
                  : "";

                if (!resolvedHandlerId && !bindState) return;

                const identity = element && element.dataset
                  ? (element.dataset.glaucoIdentity || "")
                  : "";
                const dedupeKey = [
                  resolvedHandlerId,
                  eventName,
                  identity,
                  bindState
                ].join("|");
                const lastSeen = window.__glaucoplasticEventDedupe.get(
                  dedupeKey
                ) || 0;
                const now = Date.now();
                if (now - lastSeen < 50) return;
                window.__glaucoplasticEventDedupe.set(dedupeKey, now);

                eventQueue().push({
                  handlerId: resolvedHandlerId,
                  event: eventName,
                  identity,
                  bindState,
                  value: valueElement && "value" in valueElement ? valueElement.value : null,
                  checked: valueElement && "checked" in valueElement
                    ? !!valueElement.checked
                    : null,
                  key: event && event.key ? event.key : ""
                });
              }

              function ensureGlaucoplasticCustomElements() {
                if (!window.customElements || !document.querySelectorAll) return;
                const items = Array.from(
                  document.querySelectorAll('[data-glauco-identity]')
                );
                for (const item of items) {
                  const tagName = (item.tagName || "").toLowerCase();
                  if (!tagName.includes("-")) continue;
                  if (customElements.get(tagName)) continue;
                  if (window.__glaucoplasticDefinedElements.has(tagName)) continue;
                  window.__glaucoplasticDefinedElements.add(tagName);
                  const GlaucoElement = class extends HTMLElement {
                    connectedCallback() {
                      emit("connected", this, null);
                    }
                  };
                  try {
                    customElements.define(tagName, GlaucoElement);
                  } catch (error) {
                    window.__glaucoplasticDefinedElements.delete(tagName);
                  }
                }
              }

              function collectGlaucoplasticForeignLayouts() {
                return Array.from(
                  document.querySelectorAll('[data-glauco-foreign]')
                ).map(element => {
                  const rectangle = element.getBoundingClientRect();
                  const style = getComputedStyle(element);
                  return {
                    path: element.dataset.glaucoForeign,
                    x: rectangle.left,
                    y: rectangle.top,
                    width: rectangle.width,
                    height: rectangle.height,
                    visible: style.display !== 'none' &&
                      style.visibility !== 'hidden' &&
                      rectangle.width > 0 &&
                      rectangle.height > 0
                  };
                });
              }

              function publishGlaucoplasticForeignLayouts() {
                const snapshot = (
                  collectGlaucoplasticForeignLayouts()
                );
                window.__glaucoplasticForeignLayoutSnapshot = snapshot;
                if (window.webkit &&
                    window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.glaucoplasticLayout) {
                  window.webkit.messageHandlers.glaucoplasticLayout.postMessage(
                    JSON.stringify(snapshot)
                  );
                }
                if (window.chrome &&
                    window.chrome.webview &&
                    window.chrome.webview.postMessage) {
                  window.chrome.webview.postMessage({
                    type: "glaucoplasticLayout",
                    payload: JSON.stringify(snapshot)
                  });
                }
              }

              function scheduleGlaucoplasticForeignLayouts() {
                if (window.__glaucoplasticForeignLayoutScheduled) return;
                window.__glaucoplasticForeignLayoutScheduled = true;
                const schedule = window.requestAnimationFrame ||
                  (callback => window.setTimeout(callback, 16));
                schedule(() => {
                  window.__glaucoplasticForeignLayoutScheduled = false;
                  publishGlaucoplasticForeignLayouts();
                });
              }

              function ensureGlaucoplasticForeignLayoutObservers() {
                if (window.__glaucoplasticForeignLayoutObserverInstalled) return;
                window.__glaucoplasticForeignLayoutObserverInstalled = true;
                if (window.MutationObserver && document.body) {
                  const observer = new MutationObserver(() => {
                    scheduleGlaucoplasticForeignLayouts();
                  });
                  observer.observe(document.body, {
                    subtree: true,
                    childList: true,
                    attributes: true,
                    attributeFilter: [
                      'class',
                      'style',
                      'hidden',
                      'data-status'
                    ]
                  });
                }
                if (window.ResizeObserver) {
                  const resizeObserver = new ResizeObserver(() => {
                    scheduleGlaucoplasticForeignLayouts();
                  });
                  for (const element of document.querySelectorAll(
                    '[data-glauco-foreign]'
                  )) {
                    try {
                      resizeObserver.observe(element);
                    } catch (error) {
                      /* ignore */
                    }
                  }
                }
                window.addEventListener('scroll', () => {
                  scheduleGlaucoplasticForeignLayouts();
                }, true);
                window.addEventListener('resize', () => {
                  scheduleGlaucoplasticForeignLayouts();
                }, true);
                scheduleGlaucoplasticForeignLayouts();
              }

              ensureGlaucoplasticCustomElements();
              ensureGlaucoplasticForeignLayoutObservers();

              document.addEventListener("click", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-handler-click]"
                );
                if (!element) return;
                emit("click", element, event);
              }, true);

              document.addEventListener("pointerup", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-handler-click]"
                );
                if (!element) return;
                emit("click", element, event);
              }, true);

              document.addEventListener("mouseup", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-handler-click]"
                );
                if (!element) return;
                emit("click", element, event);
              }, true);

              document.addEventListener("change", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-bind-state],[data-glauco-handler-change]"
                );
                if (!element) return;
                emit("change", element, event);
              }, true);

              document.addEventListener("input", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-bind-state],[data-glauco-handler-input]"
                );
                if (!element) return;
                emit("input", element, event);
              }, true);

              document.addEventListener("focusin", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-bind-state],[data-glauco-handler-focus]"
                );
                if (!element) return;
                emit("focus", element, event);
              }, true);

              document.addEventListener("blur", event => {
                const element = resolveEventElement(
                  event,
                  "[data-glauco-handler-blur]"
                );
                if (!element) return;
                emit("blur", element, event);
              }, true);

              document.addEventListener("keydown", event => {
                if (event.key !== "Enter") return;
                const element = resolveEventElement(
                  event,
                  "[data-glauco-handler-enter]"
                );
                if (!element) return;
                event.preventDefault();
                emit("enter", element, event);
              }, true);
            })();
          </script>
          """ & assistantScript & """
        </body>
        </html>"""
      result.add newCall(
        ident("appendPlasticPlanSection"),
        applicationVariable.copyNimTree,
        newLit($astToPlanJson(section))
      )
      result.add quote do:
        `applicationVariable`.componentsValue =
          deriveComponents(`applicationVariable`.planValue)
        `applicationVariable`.renderTreeValue =
          deriveRenderTree(`applicationVariable`.planValue)
        deriveForeignElements(`applicationVariable`)
        let applicationForForeignEvents = `applicationVariable`
        `applicationVariable`.foreignValue.onEvent =
          proc(path, eventName: string) =
            applicationForForeignEvents.dispatchForeignEvent(
              path,
              eventName
            )
        installForeignUrlBindings(`applicationVariable`)
      result.add collectComponentBindings(section)
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("agents"):
      result.add quote do:
        proc plasticMetisSafeName(value: string): string =
          let cleanedInput = value.strip
          if cleanedInput.len == 0:
            raise newException(PlasticRuntimeError, "Nome de sessão Metis vazio.")
          for ch in cleanedInput:
            if ch.isAlphaNumeric or ch in {'.', '_', '-'}:
              result.add ch
            else:
              result.add '_'
          if result in [".", ".."]:
            raise newException(PlasticRuntimeError, "Nome de sessão Metis inválido: " & value)

        proc plasticMetisUtcNow(): string =
          getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

        proc plasticMetisAppendJsonl(path: string; payload: JsonNode) =
          ensureParentDirectory(path)
          var handle: File
          if not open(handle, path, fmAppend):
            raise newException(
              PlasticRuntimeError,
              "Não foi possível abrir JSONL Metis: " & path
            )
          try:
            handle.writeLine($payload)
            handle.flushFile()
          finally:
            handle.close()

        proc plasticMetisAtomicJsonWrite(path: string; payload: JsonNode) =
          ensureParentDirectory(path)
          let temporary = path & "." & $getTime().toUnix & ".tmp"
          writeFile(temporary, pretty(payload))
          moveFile(temporary, path)

        proc plasticMetisJsonText(node: JsonNode): string =
          if node.isNil:
            return ""
          if node.kind == JString:
            node.getStr
          else:
            $node

        proc plasticMetisVenvPython(venvPath: string): string =
          when defined(windows):
            venvPath / "Scripts" / "python.exe"
          else:
            venvPath / "bin" / "python"

        proc plasticMetisExec(
          executable: string;
          arguments: openArray[string];
          operation: string
        ): string =
          var commandParts = @[quoteShell(executable)]
          for argument in arguments:
            commandParts.add quoteShell(argument)
          let execution = execCmdEx(
            commandParts.join(" "),
            options = {poUsePath, poStdErrToStdOut}
          )
          if execution.exitCode != 0:
            raise newException(
              PlasticInstallationError,
              operation & " falhou (código " & $execution.exitCode & "):\n" &
              execution.output
            )
          execution.output

        proc plasticMetisPythonMatches(
          executable, requiredVersion: string
        ): bool =
          if executable.len == 0 or not fileExists(executable):
            return false
          try:
            let output = plasticMetisExec(
              executable,
              ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
              "Validação do Python Metis"
            ).strip
            output == requiredVersion
          except CatchableError:
            false

        proc plasticMetisRuntimeImportsReady(executable: string): bool =
          try:
            discard plasticMetisExec(
              executable,
              [
                "-c",
                "import torch, transformers, bitsandbytes, accelerate, huggingface_hub; " &
                "print(torch.__version__)"
              ],
              "Validação das dependências Metis"
            )
            true
          except CatchableError:
            false

        proc plasticMetisFindUv(): string =
          result = findExe("uv")
          if result.len == 0:
            let localUv = getHomeDir() / ".local" / "bin" /
              (when defined(windows): "uv.exe" else: "uv")
            if fileExists(localUv):
              result = localUv

        proc plasticMetisInstallUv(): string =
          result = plasticMetisFindUv()
          if result.len > 0:
            return
          var bootstrap = findExe("python3")
          if bootstrap.len == 0:
            bootstrap = findExe("python")
          if bootstrap.len == 0:
            raise newException(
              PlasticInstallationError,
              "Não foi encontrado Python nem uv para instalar o runtime Metis."
            )
          discard plasticMetisExec(
            bootstrap,
            ["-m", "pip", "install", "--user", "--upgrade", "uv"],
            "Instalação local do uv"
          )
          result = plasticMetisFindUv()
          if result.len == 0:
            raise newException(
              PlasticInstallationError,
              "O uv foi instalado, mas seu executável não foi localizado."
            )

        proc plasticMetisProbePython(executable: string): JsonNode =
          let script = """
import encodings
import json
import os
import site
import sys
import sysconfig

stdlib = os.path.realpath(sysconfig.get_path('stdlib') or '')
platstdlib = os.path.realpath(
    sysconfig.get_path('platstdlib') or stdlib
)
base_prefix = os.path.realpath(sys.base_prefix)

encodings_file = os.path.realpath(encodings.__file__)
if (
    not os.path.isfile(
        os.path.join(
            base_prefix,
            'lib',
            'python%d.%d' % (
                sys.version_info.major,
                sys.version_info.minor
            ),
            'encodings',
            '__init__.py'
        )
    )
    and stdlib
):
    derived_prefix = os.path.dirname(os.path.dirname(stdlib))
    if os.path.isdir(derived_prefix):
        base_prefix = derived_prefix

libdir = sysconfig.get_config_var('LIBDIR') or ''
library = ''
for library_name in (
    sysconfig.get_config_var('INSTSONAME'),
    sysconfig.get_config_var('LDLIBRARY'),
):
    if not library_name:
        continue
    candidate = os.path.realpath(
        os.path.join(libdir, library_name)
    )
    if os.path.isfile(candidate):
        library = candidate
        break

if not library:
    try:
        import find_libpython
        candidate = find_libpython.find_libpython()
        if candidate and os.path.isfile(candidate):
            library = os.path.realpath(candidate)
    except Exception:
        pass

paths = []
dynload = os.path.join(platstdlib or stdlib, 'lib-dynload')
for value in [
    stdlib,
    platstdlib,
    dynload,
] + list(sys.path) + list(site.getsitepackages()):
    if not value:
        continue
    value = os.path.realpath(value)
    if value not in paths:
        paths.append(value)

print(json.dumps({
    'version': [
        sys.version_info.major,
        sys.version_info.minor,
        sys.version_info.micro
    ],
    'executable': os.path.realpath(sys.executable),
    'base_executable': os.path.realpath(
        getattr(sys, '_base_executable', sys.executable)
    ),
    'prefix': os.path.realpath(sys.prefix),
    'exec_prefix': os.path.realpath(sys.exec_prefix),
    'base_prefix': base_prefix,
    'base_exec_prefix': os.path.realpath(sys.base_exec_prefix),
    'stdlib': stdlib,
    'platstdlib': platstdlib,
    'encodings': encodings_file,
    'library': library,
    'paths': paths
}))
"""
          let text = plasticMetisExec(
            executable,
            ["-c", script],
            "Inspeção do runtime Python Metis"
          ).strip
          try:
            result = parseJson(text)
          except CatchableError as error:
            raise newException(
              PlasticInstallationError,
              "O runtime Python Metis retornou metadados inválidos: " &
              error.msg
            )

        proc ensureMetisPaths*(memory: PlasticMetisMemory) =
          if memory.rootPath.len == 0:
            raise newException(
              PlasticInstallationError,
              "Caminho da memória Metis não configurado."
            )

          let glaucoRoot = memory.rootPath.parentDir
          if memory.runtimeRoot.len == 0:
            memory.runtimeRoot = glaucoRoot / "runtime" / "metis"

          memory.pythonVenvPath =
            if memory.config.pythonVenv.strip.len > 0:
              expandTilde(memory.config.pythonVenv)
            else:
              memory.runtimeRoot / "python"

          if memory.modelCachePath.len == 0:
            memory.modelCachePath = glaucoRoot / "cache" / "huggingface"

          let modelSlug =
            plasticMetisSafeName(memory.config.modelId)

          if memory.modelPath.len == 0:
            let configuredModelPath =
              expandTilde(
                getEnv("GLAUCOPLASTIC_METIS_MODEL_PATH")
              )

            var modelCandidates: seq[string] = @[]
            if configuredModelPath.len > 0:
              modelCandidates.add configuredModelPath

            modelCandidates.add(
              getAppDir() / "models" / "metis" / modelSlug
            )
            modelCandidates.add(
              getCurrentDir() / "models" / "metis" / modelSlug
            )
            modelCandidates.add(
              getHomeDir() / ".local" / "share" /
                "glaucoplastic" / "models" / "metis" / modelSlug
            )
            modelCandidates.add(
              glaucoRoot / "models" / "metis" / modelSlug
            )

            for candidate in modelCandidates:
              if fileExists(candidate / "config.json") and
                  fileExists(
                    candidate / "model.safetensors.index.json"
                  ):
                memory.modelPath = candidate
                break

            if memory.modelPath.len == 0:
              memory.modelPath =
                if configuredModelPath.len > 0:
                  configuredModelPath
                else:
                  getAppDir() / "models" / "metis" / modelSlug

          let profile =
            plasticMetisSafeName(memory.config.profile)

          memory.profileDir =
            memory.rootPath / "profiles" / profile
          memory.snapshotPath =
            memory.profileDir / "runtime.metis.pt"
          memory.exchangesPath =
            memory.profileDir / "exchanges.jsonl"
          memory.eventsPath =
            memory.profileDir / "memory-events.jsonl"

          createDir(memory.rootPath)
          createDir(memory.runtimeRoot)
          createDir(memory.modelCachePath)
          createDir(memory.rootPath / "profiles")
          createDir(memory.profileDir)
          createDir(memory.profileDir / "sessions")

        proc plasticPyRuntimeString(value: string): PyObject =
          ## Conversão disponível antes de prepareRuntime. plasticPyBox é
          ## declarado mais adiante no bloco gerado e não pode ser usado aqui.
          let py = pyBuiltinsModule()
          nimpy.callMethod(py, "str", value)

        proc prepareRuntime*(memory: PlasticMetisMemory) =
          if memory.isNil or not memory.config.enabled or memory.runtimePrepared:
            return
          memory.ensureMetisPaths()

          var candidates: seq[string] = @[]
          let explicitPython = expandTilde(getEnv("GLAUCOPLASTIC_METIS_PYTHON"))
          if explicitPython.len > 0:
            candidates.add explicitPython
          if memory.config.pythonVenv.strip.len > 0:
            candidates.add plasticMetisVenvPython(
              expandTilde(memory.config.pythonVenv)
            )
          candidates.add plasticMetisVenvPython(
            getHomeDir() / ".venvs" / "metis-gemma"
          )
          candidates.add plasticMetisVenvPython(memory.pythonVenvPath)
          let system310 = findExe("python3.10")
          if system310.len > 0:
            candidates.add system310

          for candidate in candidates:
            if plasticMetisPythonMatches(candidate, memory.config.pythonVersion):
              memory.pythonExecutable = candidate
              break

          if memory.pythonExecutable.len == 0:
            if not memory.config.prepareRuntime:
              raise newException(
                PlasticInstallationError,
                "Runtime Python " & memory.config.pythonVersion &
                " do Metis não encontrado e a preparação automática está desativada."
              )
            let uv = plasticMetisInstallUv()
            discard plasticMetisExec(
              uv,
              ["python", "install", memory.config.pythonVersion],
              "Instalação do Python " & memory.config.pythonVersion
            )
            discard plasticMetisExec(
              uv,
              [
                "venv", "--seed", "--python", memory.config.pythonVersion,
                memory.pythonVenvPath
              ],
              "Criação do ambiente Python local do Metis"
            )
            memory.pythonExecutable =
              plasticMetisVenvPython(memory.pythonVenvPath)

          if not plasticMetisPythonMatches(
              memory.pythonExecutable,
              memory.config.pythonVersion
            ):
            raise newException(
              PlasticInstallationError,
              "O Python selecionado para o Metis não é da série " &
              memory.config.pythonVersion & ": " & memory.pythonExecutable
            )

          if not plasticMetisRuntimeImportsReady(memory.pythonExecutable):
            if not memory.config.autoInstallDependencies:
              raise newException(
                PlasticInstallationError,
                "As dependências Python do Metis não estão instaladas em " &
                memory.pythonExecutable
              )
            discard plasticMetisExec(
              memory.pythonExecutable,
              ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
              "Atualização do instalador Python do Metis"
            )
            discard plasticMetisExec(
              memory.pythonExecutable,
              [
                "-m", "pip", "install", "--upgrade",
                "--extra-index-url", "https://download.pytorch.org/whl/cu118",
                "torch==2.5.1+cu118"
              ],
              "Instalação do PyTorch CUDA para o Metis"
            )
            discard plasticMetisExec(
              memory.pythonExecutable,
              [
                "-m", "pip", "install", "--upgrade",
                "transformers==5.4.0",
                "accelerate==1.14.0",
                "bitsandbytes==0.50.0",
                "flash-linear-attention==0.2.2",
                "huggingface-hub==1.19.0",
                "safetensors==0.8.0",
                "find-libpython"
              ],
              "Instalação das dependências do runtime Metis"
            )

          if not plasticMetisRuntimeImportsReady(memory.pythonExecutable):
            raise newException(
              PlasticInstallationError,
              "O runtime local do Metis foi preparado, mas os imports de " &
              "torch/transformers/bitsandbytes ainda falham."
            )

          var probe = plasticMetisProbePython(memory.pythonExecutable)
          if probe["library"].getStr.len == 0 or
              not fileExists(probe["library"].getStr):
            discard plasticMetisExec(
              memory.pythonExecutable,
              ["-m", "pip", "install", "--upgrade", "find-libpython"],
              "Instalação do localizador de libpython"
            )
            probe = plasticMetisProbePython(memory.pythonExecutable)
          let version = probe["version"]
          if version.kind != JArray or version.len < 2 or
              version[0].getInt != 3 or version[1].getInt != 10:
            raise newException(
              PlasticInstallationError,
              "O runtime Metis carregado não é Python 3.10."
            )
          let configuredPythonLibrary =
            expandTilde(
              getEnv("GLAUCOPLASTIC_METIS_LIBPYTHON")
            ).strip

          memory.pythonLibrary =
            if configuredPythonLibrary.len > 0:
              configuredPythonLibrary
            else:
              probe["library"].getStr

          if memory.pythonLibrary.len == 0 or
              not fileExists(memory.pythonLibrary):
            raise newException(
              PlasticInstallationError,
              "A libpython do runtime Metis não foi localizada."
            )

          memory.pythonPaths = @[]
          for item in probe["paths"]:
            if item.kind == JString and item.getStr.len > 0:
              memory.pythonPaths.add item.getStr

          let pythonHome =
            if probe.hasKey("base_prefix"):
              probe["base_prefix"].getStr.strip
            else:
              ""

          let encodingsPath =
            if probe.hasKey("encodings"):
              probe["encodings"].getStr.strip
            else:
              ""

          if pythonHome.len == 0 or
              not dirExists(pythonHome) or
              encodingsPath.len == 0 or
              not fileExists(encodingsPath):
            raise newException(
              PlasticInstallationError,
              "O Python Metis foi localizado, porém sua biblioteca " &
              "padrão/encodings não pôde ser resolvida."
            )

          let pythonPathSeparator =
            when defined(windows):
              ";"
            else:
              ":"

          # pyInitLibPath inicializa o CPython imediatamente. Estes valores
          # precisam existir antes da chamada, não depois do primeiro pyImport.
          putEnv("PYTHONHOME", pythonHome)
          putEnv(
            "PYTHONPATH",
            memory.pythonPaths.join(pythonPathSeparator)
          )
          putEnv("PYTHONNOUSERSITE", "1")

          # NimPy precisa ser ligado à libpython 3.10 antes do primeiro pyImport.
          pyInitLibPath(memory.pythonLibrary)
          let sysModule = pyImport("sys")

          # Py_Initialize dentro de um executável Nim tende a preencher
          # sys.executable com /usr/bin/python3. O torch._inductor reutiliza
          # esse valor para criar compile workers. Misturar esse executável
          # com a stdlib 3.10 do venv produz `SRE module mismatch`.
          if probe.hasKey("executable"):
            nimpy.setAttr(
              sysModule,
              "executable",
              plasticPyRuntimeString(probe["executable"].getStr)
            )
          if probe.hasKey("base_executable"):
            nimpy.setAttr(
              sysModule,
              "_base_executable",
              plasticPyRuntimeString(probe["base_executable"].getStr)
            )
          if probe.hasKey("prefix"):
            nimpy.setAttr(
              sysModule,
              "prefix",
              plasticPyRuntimeString(probe["prefix"].getStr)
            )
          if probe.hasKey("exec_prefix"):
            nimpy.setAttr(
              sysModule,
              "exec_prefix",
              plasticPyRuntimeString(probe["exec_prefix"].getStr)
            )
          if probe.hasKey("base_prefix"):
            nimpy.setAttr(
              sysModule,
              "base_prefix",
              plasticPyRuntimeString(probe["base_prefix"].getStr)
            )
          if probe.hasKey("base_exec_prefix"):
            nimpy.setAttr(
              sysModule,
              "base_exec_prefix",
              plasticPyRuntimeString(probe["base_exec_prefix"].getStr)
            )

          plasticDebugTrace(
            "metis.python executable=" &
            nimpy.getAttr(sysModule, "executable").to(string) &
            " baseExecutable=" &
            nimpy.getAttr(sysModule, "_base_executable").to(string)
          )

          let sysPath = nimpy.getAttr(sysModule, "path")
          for pythonPath in memory.pythonPaths:
            discard nimpy.callMethod(sysPath, "insert", 0, pythonPath)

          # O interpretador incorporado já foi inicializado. PYTHONHOME e
          # PYTHONPATH não podem ser herdados pelos subprocessos do
          # torch._inductor, pois o executável do venv deve resolver sua
          # própria stdlib e seus próprios módulos binários.
          delEnv("PYTHONHOME")
          delEnv("PYTHONPATH")
          putEnv("PYTHONNOUSERSITE", "1")
          putEnv(
            "PYTORCH_CUDA_ALLOC_CONF",
            getEnv(
              "PYTORCH_CUDA_ALLOC_CONF",
              "expandable_segments:True"
            )
          )
          putEnv(
            "TORCHINDUCTOR_COMPILE_THREADS",
            getEnv("TORCHINDUCTOR_COMPILE_THREADS", "1")
          )
          putEnv("TOKENIZERS_PARALLELISM", "false")

          plasticInitializePythonThreading(memory.pythonLibrary)
          memory.runtimePrepared = true

        proc plasticMetisFindModelRoot(path: string): string =
          ## Localiza o diretório real do checkpoint. Pacotes hospedados pelo
          ## aplicativo podem conter uma pasta superior, enquanto
          ## snapshot_download normalmente materializa os arquivos na raiz.
          if path.len == 0 or not dirExists(path):
            return ""
          if fileExists(path / "config.json"):
            return path
          for filePath in walkDirRec(path):
            if extractFilename(filePath) == "config.json":
              return filePath.parentDir

        proc plasticMetisModelReady(path: string): bool =
          ## Um único shard não confirma um modelo completo. Quando existe o
          ## índice safetensors, todos os arquivos apontados por weight_map
          ## precisam existir e possuir conteúdo.
          let modelRoot = plasticMetisFindModelRoot(path)
          if modelRoot.len == 0:
            return false

          let safetensorsIndex =
            modelRoot / "model.safetensors.index.json"
          if fileExists(safetensorsIndex):
            try:
              let index = parseJson(readFile(safetensorsIndex))
              if index.kind != JObject or not index.hasKey("weight_map") or
                  index["weight_map"].kind != JObject:
                return false
              var weightFiles = initHashSet[string]()
              for _, weightNode in index["weight_map"].pairs:
                if weightNode.kind == JString and weightNode.getStr.len > 0:
                  weightFiles.incl weightNode.getStr
              if weightFiles.len == 0:
                return false
              for relativePath in weightFiles.items:
                let weightPath = modelRoot / relativePath
                if not fileExists(weightPath):
                  return false
                try:
                  if getFileSize(weightPath) <= 0:
                    return false
                except CatchableError:
                  return false
              return true
            except CatchableError:
              return false

          for pattern in ["*.safetensors", "*.bin", "*.pt"]:
            for weightPath in walkFiles(modelRoot / pattern):
              try:
                if getFileSize(weightPath) > 0:
                  return true
              except CatchableError:
                discard
          false

        proc setLlamaBootState(
          state: PlasticLlamaBootState;
          phase, connection, model, detail: string;
          progress: int
        ) {.gcsafe.}

        proc plasticMetisDirectoryByteCount(
          path: string
        ): BiggestInt

        proc plasticMetisReadyMarkerPath(path: string): string =
          path / ".glaucoplastic-model-ready.json"

        proc plasticMetisWriteReadyMarker(
          memory: PlasticMetisMemory
        ) =
          let modelRoot = plasticMetisFindModelRoot(memory.modelPath)
          if modelRoot.len == 0 or not plasticMetisModelReady(modelRoot):
            return
          let markerPath = plasticMetisReadyMarkerPath(modelRoot)
          if fileExists(markerPath):
            return
          writeJsonFile(
            markerPath,
            %*{
              "modelId": memory.config.modelId,
              "modelPath": modelRoot,
              "completedAt": plasticMetisUtcNow(),
              "bytes": plasticMetisDirectoryByteCount(modelRoot)
            }
          )

        proc plasticMetisDownloadLockPath(path: string): string =
          path / ".glaucoplastic-download.lock"

        proc plasticMetisTouchDownloadLock(
          lockPath, modelId: string
        ) =
          writeJsonFile(
            lockPath,
            %*{
              "modelId": modelId,
              "heartbeat": epochTime()
            }
          )

        proc plasticMetisDownloadHeartbeat(lockPath: string): float =
          if not fileExists(lockPath):
            return 0.0
          try:
            let lockInfo = parseJson(readFile(lockPath))
            if lockInfo.kind == JObject and lockInfo.hasKey("heartbeat"):
              return lockInfo["heartbeat"].getFloat
          except CatchableError:
            discard
          0.0

        proc plasticMetisAwaitConcurrentDownload(
          memory: PlasticMetisMemory;
          state: PlasticLlamaBootState
        ): bool =
          ## Evita que duas instâncias façam a mesma transferência. A primeira
          ## atualiza o heartbeat; a segunda aguarda enquanto ele estiver vivo.
          let lockPath = plasticMetisDownloadLockPath(memory.modelPath)
          if not fileExists(lockPath):
            return false

          while fileExists(lockPath):
            let cachedRoot = plasticMetisFindModelRoot(memory.modelPath)
            if cachedRoot.len > 0 and plasticMetisModelReady(cachedRoot):
              memory.modelPath = cachedRoot
              return true

            let heartbeat = plasticMetisDownloadHeartbeat(lockPath)
            if heartbeat <= 0.0 or epochTime() - heartbeat > 20.0:
              try:
                removeFile(lockPath)
              except CatchableError:
                discard
              return false

            if not state.isNil:
              state.setLlamaBootState(
                "Aguardando modelo Metis",
                "Download em outra instância",
                memory.config.modelId,
                "Outra instância está baixando o mesmo checkpoint; aguardando o cache compartilhado...",
                0
              )
            sleep(500)
          false

        proc plasticMetisHumanByteCount(bytes: BiggestInt): string =
          let units = ["B", "KB", "MB", "GB", "TB"]
          var size = max(bytes, BiggestInt(0)).float
          var unitIndex = 0
          while size >= 1024.0 and unitIndex < units.high:
            size = size / 1024.0
            inc unitIndex
          if unitIndex == 0:
            result = $max(bytes, BiggestInt(0)) & " " & units[unitIndex]
          else:
            result = formatFloat(size, ffDecimal, 1) & " " & units[unitIndex]

        proc plasticMetisDirectoryByteCount(path: string): BiggestInt =
          if path.len == 0 or not dirExists(path):
            return 0
          for filePath in walkDirRec(path):
            if not fileExists(filePath):
              continue
            try:
              result += getFileSize(filePath)
            except CatchableError:
              discard

        proc plasticMetisRemoteModelSize(
          memory: PlasticMetisMemory
        ): BiggestInt =
          let metadataScript = """
import json, sys
from huggingface_hub import HfApi
info = HfApi().model_info(repo_id=sys.argv[1], files_metadata=True)
total = 0
files = 0
for sibling in info.siblings:
    size = getattr(sibling, "size", None)
    if size is None:
        lfs = getattr(sibling, "lfs", None)
        size = getattr(lfs, "size", 0) if lfs is not None else 0
    if size:
        total += int(size)
    files += 1
print(json.dumps({"total": total, "files": files}))
"""
          try:
            let metadataText = plasticMetisExec(
              memory.pythonExecutable,
              ["-c", metadataScript, memory.config.modelId],
              "Leitura do tamanho remoto do modelo Metis"
            ).strip
            let metadata = parseJson(metadataText)
            if metadata.kind == JObject and metadata.hasKey("total"):
              result = BiggestInt(metadata["total"].getInt)
          except CatchableError as error:
            plasticDebugTrace(
              "metis model size unavailable: " & error.msg
            )
            result = 0

        proc prepareModel*(
          memory: PlasticMetisMemory;
          state: PlasticLlamaBootState = nil
        ) =
          if memory.isNil or
              not memory.config.enabled or
              memory.modelPrepared:
            return

          memory.ensureMetisPaths()

          let modelRoot =
            plasticMetisFindModelRoot(memory.modelPath)

          if modelRoot.len == 0 or
              not plasticMetisModelReady(modelRoot):
            raise newException(
              PlasticInstallationError,
              "Modelo Metis incluído não encontrado ou incompleto em " &
              memory.modelPath & ". Execute `nimble build` para " &
              "preparar o cliente com IAAR-Shanghai/Metis-4B."
            )

          memory.modelPath = modelRoot
          memory.plasticMetisWriteReadyMarker()
          memory.modelPrepared = true

          if not state.isNil:
            state.setLlamaBootState(
              "Modelo Metis incluído",
              "Checkpoint local confirmado",
              memory.config.modelId,
              "Checkpoint completo carregado de " &
                memory.modelPath & ". Nenhum download foi executado.",
              96
            )
            sleep(250)

        proc sessionPath*(memory: PlasticMetisMemory; session: string): string =
          memory.ensureMetisPaths()
          memory.profileDir / "sessions" /
            (plasticMetisSafeName(session) & ".json")

        proc loadSessionMessages*(
          memory: PlasticMetisMemory;
          session: string
        ): JsonNode =
          let path = memory.sessionPath(session)
          if not fileExists(path):
            return newJArray()
          let payload = readJsonFile(
            path,
            %*{"created_at": plasticMetisUtcNow(), "messages": []}
          )
          if payload.kind == JObject and payload.hasKey("messages") and
              payload["messages"].kind == JArray:
            return payload["messages"].copy
          newJArray()

        proc saveSessionExchange*(
          memory: PlasticMetisMemory;
          session, userText, assistantText: string
        ) =
          let path = memory.sessionPath(session)
          var payload =
            if fileExists(path):
              readJsonFile(
                path,
                %*{"created_at": plasticMetisUtcNow(), "messages": []}
              )
            else:
              %*{"created_at": plasticMetisUtcNow(), "messages": []}
          if payload.kind != JObject:
            payload = %*{"created_at": plasticMetisUtcNow(), "messages": []}
          if not payload.hasKey("messages") or payload["messages"].kind != JArray:
            payload["messages"] = newJArray()
          payload["messages"].add %*{"role": "user", "content": userText}
          payload["messages"].add %*{"role": "assistant", "content": assistantText}
          let keep = max(memory.config.recentMessages * 4, 40)
          if payload["messages"].len > keep:
            var trimmed = newJArray()
            let startIndex = payload["messages"].len - keep
            for index in startIndex ..< payload["messages"].len:
              trimmed.add payload["messages"][index].copy
            payload["messages"] = trimmed
          payload["updated_at"] = %plasticMetisUtcNow()
          plasticMetisAtomicJsonWrite(path, payload)

        proc plasticMetisDtype(memory: PlasticMetisMemory): PyObject =
          ## Use explicit NimPy attribute lookup here. Names such as `float32`
          ## are also Nim type identifiers, so the dot template can be resolved
          ## by the compiler as ordinary Nim field/type syntax instead of a
          ## Python attribute access inside the generated consumer module.
          case memory.config.dtypeName.toLowerAscii
          of "bfloat16", "bf16":
            nimpy.getAttr(memory.torchModule, "bfloat16")
          of "float32", "fp32":
            nimpy.getAttr(memory.torchModule, "float32")
          else:
            nimpy.getAttr(memory.torchModule, "float16")

        type
          PlasticPyKeyword = tuple[name: string, value: PyObject]

        var plasticPythonInvokeFunction: PyObject

        proc plasticPyBox(value: PyObject): PyObject =
          value

        proc plasticPyBox[T](value: T): PyObject =
          ## Converte qualquer valor Nim aceito pelo NimPy para PyObject sem
          ## depender dos templates privados de chamada com argumentos nomeados.
          let py = pyBuiltinsModule()
          let container = nimpy.callMethod(py, "list")
          discard nimpy.callMethod(container, "append", value)
          container[0]

        proc plasticPyKeyword(
          name: string;
          value: PyObject
        ): PlasticPyKeyword =
          (name: name, value: value)

        proc plasticPyInvoker(): PyObject =
          if plasticPythonInvokeFunction.isNil:
            let py = pyBuiltinsModule()
            let scope = nimpy.callMethod(py, "dict")
            discard nimpy.callMethod(
              py,
              "exec",
              "def _glaucoplastic_invoke(callable_object, positional, keyword):\n" &
                "    return callable_object(*positional, **keyword)\n",
              scope,
              scope
            )
            plasticPythonInvokeFunction = scope["_glaucoplastic_invoke"]
          plasticPythonInvokeFunction

        proc plasticPyCallKw(
          callableObject: PyObject;
          positional: openArray[PyObject];
          keywords: openArray[PlasticPyKeyword]
        ): PyObject =
          let py = pyBuiltinsModule()
          let positionalList = nimpy.callMethod(py, "list")
          for value in positional:
            discard nimpy.callMethod(positionalList, "append", value)
          let keywordDict = nimpy.callMethod(py, "dict")
          for keyword in keywords:
            keywordDict[keyword.name] = keyword.value
          nimpy.callObject(
            plasticPyInvoker(),
            callableObject,
            positionalList,
            keywordDict
          )

        proc plasticPyCallMethodKw(
          objectValue: PyObject;
          methodName: string;
          positional: openArray[PyObject];
          keywords: openArray[PlasticPyKeyword]
        ): PyObject =
          plasticPyCallKw(
            nimpy.getAttr(objectValue, methodName.cstring),
            positional,
            keywords
          )

        proc plasticPyNone(): PyObject =
          nimpy.callMethod(pyBuiltinsModule(), "eval", "None")

        proc plasticMetisMessages(
          pairs: openArray[tuple[role, content: string]]
        ): PyObject =
          let py = pyBuiltinsModule()
          result = nimpy.callMethod(py, "list")
          for pair in pairs:
            let item = nimpy.callMethod(py, "dict")
            item["role"] = pair.role
            item["content"] = pair.content
            discard nimpy.callMethod(result, "append", item)

        proc plasticMetisRender(
          memory: PlasticMetisMemory;
          pairs: openArray[tuple[role, content: string]];
          addGenerationPrompt: bool
        ): tuple[inputIds, attentionMask: PyObject] =
          let pyMessages = plasticMetisMessages(pairs)
          var text: PyObject
          try:
            text = plasticPyCallMethodKw(
              memory.tokenizerObject,
              "apply_chat_template",
              @[pyMessages],
              @[
                plasticPyKeyword("tokenize", plasticPyBox(false)),
                plasticPyKeyword(
                  "add_generation_prompt",
                  plasticPyBox(addGenerationPrompt)
                ),
                plasticPyKeyword("enable_thinking", plasticPyBox(false))
              ]
            )
          except CatchableError:
            text = plasticPyCallMethodKw(
              memory.tokenizerObject,
              "apply_chat_template",
              @[pyMessages],
              @[
                plasticPyKeyword("tokenize", plasticPyBox(false)),
                plasticPyKeyword(
                  "add_generation_prompt",
                  plasticPyBox(addGenerationPrompt)
                )
              ]
            )
          let encoded = plasticPyCallKw(
            memory.tokenizerObject,
            @[text],
            @[
              plasticPyKeyword("add_special_tokens", plasticPyBox(false)),
              plasticPyKeyword("return_tensors", plasticPyBox("pt"))
            ]
          )
          result.inputIds = nimpy.callMethod(
            encoded["input_ids"],
            "to",
            memory.inputDeviceObject
          )
          result.attentionMask = nimpy.callMethod(
            encoded["attention_mask"],
            "to",
            memory.inputDeviceObject
          )

        proc plasticMetisCaptureState(memory: PlasticMetisMemory): PyObject =
          let py = pyBuiltinsModule()
          result = nimpy.callMethod(py, "dict")
          result["format"] = "metis-runtime-memory-v1"
          result["model_id"] = memory.config.modelId
          result["saved_at"] = plasticMetisUtcNow()
          let layers = nimpy.callMethod(py, "dict")
          let modelBody = nimpy.getAttr(memory.modelObject, "model")
          let blocks = nimpy.getAttr(modelBody, "metis_blocks")
          let count = nimpy.callMethod(py, "len", blocks).to(int)
          for index in 0 ..< count:
            let metisBlock = blocks[index]
            if not nimpy.callMethod(
              py,
              "hasattr",
              metisBlock,
              "local_memory"
            ).to(bool):
              continue
            let localMemory = nimpy.getAttr(metisBlock, "local_memory")
            let layer = nimpy.callMethod(py, "dict")
            var hasState = false
            for attribute in ["_state", "_key_state", "memory_state"]:
              if not nimpy.callMethod(
                py,
                "hasattr",
                localMemory,
                attribute
              ).to(bool):
                continue
              let value = nimpy.callMethod(
                py,
                "getattr",
                localMemory,
                attribute
              )
              if nimpy.callMethod(
                memory.torchModule,
                "is_tensor",
                value
              ).to(bool):
                let detached = nimpy.callMethod(value, "detach")
                let cpuValue = nimpy.callMethod(detached, "to", "cpu")
                layer[attribute] = nimpy.callMethod(cpuValue, "contiguous")
                hasState = true
            if hasState:
              layers[$index] = layer
          result["layers"] = layers

        proc plasticMetisSaveDirect(memory: PlasticMetisMemory) =
          memory.ensureMetisPaths()
          let temporary = memory.snapshotPath & "." & $getTime().toUnix & ".tmp"
          discard nimpy.callMethod(
            memory.torchModule,
            "save",
            memory.plasticMetisCaptureState(),
            temporary
          )
          moveFile(temporary, memory.snapshotPath)

        proc plasticMetisRestoreDirect(memory: PlasticMetisMemory): int =
          if not fileExists(memory.snapshotPath):
            return 0
          var payload: PyObject
          try:
            payload = plasticPyCallMethodKw(
              memory.torchModule,
              "load",
              @[plasticPyBox(memory.snapshotPath)],
              @[
                plasticPyKeyword("map_location", plasticPyBox("cpu")),
                plasticPyKeyword("weights_only", plasticPyBox(true))
              ]
            )
          except CatchableError:
            payload = plasticPyCallMethodKw(
              memory.torchModule,
              "load",
              @[plasticPyBox(memory.snapshotPath)],
              @[plasticPyKeyword("map_location", plasticPyBox("cpu"))]
            )
          if payload["format"].to(string) != "metis-runtime-memory-v1":
            raise newException(
              PlasticRuntimeError,
              "Formato de memória Metis desconhecido em " & memory.snapshotPath
            )
          if payload["model_id"].to(string) != memory.config.modelId:
            raise newException(
              PlasticRuntimeError,
              "O snapshot Metis pertence a outro modelo."
            )
          discard nimpy.callMethod(memory.modelObject, "reset")
          let py = pyBuiltinsModule()
          let modelBody = nimpy.getAttr(memory.modelObject, "model")
          let blocks = nimpy.getAttr(modelBody, "metis_blocks")
          let blockCount = nimpy.callMethod(py, "len", blocks).to(int)
          let layers = payload["layers"]
          let dtype = memory.plasticMetisDtype()
          let targetDevice = nimpy.callMethod(
            memory.torchModule,
            "device",
            memory.config.device
          )
          let layerItems = nimpy.callMethod(layers, "items")
          for pair in layerItems:
            let indexText = pair[0].to(string)
            let index = parseInt(indexText)
            if index < 0 or index >= blockCount:
              raise newException(
                PlasticRuntimeError,
                "Camada Metis inexistente no snapshot: " & indexText
              )
            let metisBlock = blocks[index]
            if not nimpy.callMethod(
              py,
              "hasattr",
              metisBlock,
              "local_memory"
            ).to(bool):
              continue
            let localMemory = nimpy.getAttr(metisBlock, "local_memory")
            let attributes = pair[1]
            let attributeItems = nimpy.callMethod(attributes, "items")
            for attributePair in attributeItems:
              let attribute = attributePair[0].to(string)
              let tensor = attributePair[1]
              let restoredTensor = plasticPyCallMethodKw(
                tensor,
                "to",
                newSeq[PyObject](),
                @[
                  plasticPyKeyword("device", targetDevice),
                  plasticPyKeyword("dtype", dtype)
                ]
              )
              discard nimpy.callMethod(
                py,
                "setattr",
                localMemory,
                attribute,
                restoredTensor
              )
            inc result

        proc plasticMetisCommitDirect(
          memory: PlasticMetisMemory;
          userText, assistantText: string
        ) =
          let rendered = memory.plasticMetisRender(
            [
              (role: "user", content: userText),
              (role: "assistant", content: assistantText)
            ],
            false
          )
          discard plasticPyCallKw(
            memory.modelObject,
            newSeq[PyObject](),
            @[
              plasticPyKeyword("input_ids", rendered.inputIds),
              plasticPyKeyword("attention_mask", rendered.attentionMask),
              plasticPyKeyword("commit_memory", plasticPyBox(true)),
              plasticPyKeyword("use_cache", plasticPyBox(false)),
              plasticPyKeyword("logits_to_keep", plasticPyBox(1))
            ]
          )

        proc plasticMetisQueryDirect(
          memory: PlasticMetisMemory;
          text: string
        ): string =
          let rendered = memory.plasticMetisRender(
            [
              (
                role: "system",
                content:
                  "Você lê a sua memória nativa persistente para auxiliar outro " &
                  "modelo. Recupere somente informações anteriormente fornecidas " &
                  "pelo usuário que sejam relevantes à consulta atual. Não use " &
                  "conhecimento geral, não invente e não explique o mecanismo. " &
                  "Responda em português, em itens curtos. Se não houver memória " &
                  "relevante, responda exatamente: SEM_MEMORIA_RELEVANTE"
              ),
              (role: "user", content: "Consulta atual:\n" & text)
            ],
            true
          )
          let output = plasticPyCallMethodKw(
            memory.modelObject,
            "generate",
            newSeq[PyObject](),
            @[
              plasticPyKeyword("input_ids", rendered.inputIds),
              plasticPyKeyword("attention_mask", rendered.attentionMask),
              plasticPyKeyword(
                "max_new_tokens",
                plasticPyBox(memory.config.queryTokens)
              ),
              plasticPyKeyword("do_sample", plasticPyBox(false)),
              plasticPyKeyword("use_cache", plasticPyBox(true)),
              plasticPyKeyword(
                "eos_token_id",
                nimpy.getAttr(memory.tokenizerObject, "eos_token_id")
              ),
              plasticPyKeyword(
                "pad_token_id",
                nimpy.getAttr(memory.tokenizerObject, "pad_token_id")
              )
            ]
          )
          let allIds = nimpy.callMethod(output[0], "tolist").to(seq[int])
          let shape = nimpy.getAttr(rendered.inputIds, "shape")
          let inputLength = shape[1].to(int)
          let generated =
            if inputLength < allIds.len:
              allIds[inputLength .. ^1]
            else:
              @[]
          result = plasticPyCallMethodKw(
            memory.tokenizerObject,
            "decode",
            @[plasticPyBox(generated)],
            @[
              plasticPyKeyword("skip_special_tokens", plasticPyBox(true))
            ]
          ).to(string).strip
          if result.len == 0:
            result = "SEM_MEMORIA_RELEVANTE"

        proc plasticMetisLlamaChat(
          endpoint, model: string;
          messages: JsonNode;
          maxTokens: int;
          temperature: float
        ): string =
          let client = newHttpClient(timeout = 3_600_000)
          client.headers = newHttpHeaders({
            "Content-Type": "application/json",
            "Accept": "application/json"
          })
          let payload = %*{
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
          }
          let response = client.request(
            endpoint.strip(chars = {'/'}) & "/chat/completions",
            httpMethod = HttpPost,
            body = $payload
          )
          let body = response.body
          if int(response.code) < 200 or int(response.code) >= 300:
            raise newException(
              PlasticRuntimeError,
              "HTTP " & $response.code & " ao consolidar memória Metis: " &
              body[0 ..< min(body.len, 1000)]
            )
          let parsed = parseJson(body)
          if parsed.kind != JObject or not parsed.hasKey("choices") or
              parsed["choices"].kind != JArray or parsed["choices"].len == 0:
            raise newException(
              PlasticRuntimeError,
              "Resposta inesperada do llama-server durante consolidação Metis."
            )
          result = parsed["choices"][0]["message"]["content"].getStr.strip

        proc plasticMetisExtractDurable(
          state: PlasticMetisWorkerState;
          job: PlasticMetisMemoryJob
        ): string =
          let messages = %*[
            {
              "role": "system",
              "content":
                "Você é um consolidador de memória de longo prazo. Analise uma " &
                "troca já concluída e extraia somente fatos duráveis explicitamente " &
                "fornecidos pelo usuário: identidade, preferências, projetos, " &
                "decisões, restrições, relações e objetivos persistentes. Não " &
                "memorize saudações, perguntas momentâneas, hipóteses, conhecimento " &
                "geral ou afirmações inventadas pelo assistente. A resposta do " &
                "assistente serve apenas para contexto. Escreva frases declarativas " &
                "curtas em português. Se não houver fato durável, responda " &
                "exatamente SEM_MEMORIA_DURAVEL."
            },
            {
              "role": "user",
              "content":
                "Mensagem do usuário:\n" & job.userText &
                "\n\nResposta produzida:\n" & job.assistantText
            }
          ]
          plasticMetisLlamaChat(
            state.llamaEndpoint,
            state.llamaModel,
            messages,
            state.memory.config.workerMaxTokens,
            0.0
          )

        proc runPlasticMetisWorker(state: PlasticMetisWorkerState) {.thread.} =
          if state.isNil:
            return
          state.running = true
          while true:
            var hasJob = false
            var job: PlasticMetisMemoryJob
            acquire(state.queueLock)
            if state.jobs.len > 0:
              job = state.jobs[0]
              state.jobs.delete(0)
              state.active = true
              hasJob = true
            elif state.stopping:
              state.running = false
              release(state.queueLock)
              break
            release(state.queueLock)

            if not hasJob:
              sleep(25)
              continue

            try:
              if state.memory.config.workerDelay > 0:
                sleep(int(state.memory.config.workerDelay * 1000.0))
              let memoryText =
                if job.extractWithLlama:
                  state.plasticMetisExtractDurable(job)
                else:
                  "Mensagem do usuário:\n" & job.userText &
                  "\n\nResposta associada:\n" & job.assistantText
              let normalized = memoryText.strip.toUpperAscii.replace(" ", "_")
              if memoryText.strip.len == 0 or normalized == "SEM_MEMORIA_DURAVEL":
                plasticMetisAppendJsonl(
                  state.memory.eventsPath,
                  %*{
                    "kind": "memory_skip",
                    "timestamp": plasticMetisUtcNow(),
                    "source_timestamp": job.timestamp,
                    "profile": state.memory.config.profile,
                    "session": job.session,
                    "reason": "SEM_MEMORIA_DURAVEL"
                  }
                )
                acquire(state.queueLock)
                inc state.skipped
                release(state.queueLock)
              else:
                acquire(state.modelLock)
                let gil = plasticAcquirePythonGIL()
                try:
                  state.memory.plasticMetisCommitDirect(
                    "Informações duráveis fornecidas pelo usuário e destinadas " &
                    "à memória de longo prazo:\n" & memoryText,
                    "Memória consolidada e registrada."
                  )
                  state.memory.plasticMetisSaveDirect()
                finally:
                  plasticReleasePythonGIL(gil)
                  release(state.modelLock)
                plasticMetisAppendJsonl(
                  state.memory.eventsPath,
                  %*{
                    "kind": "memory_commit",
                    "timestamp": plasticMetisUtcNow(),
                    "source_timestamp": job.timestamp,
                    "profile": state.memory.config.profile,
                    "session": job.session,
                    "memory": memoryText
                  }
                )
                acquire(state.queueLock)
                inc state.processed
                release(state.queueLock)
            except CatchableError as error:
              plasticMetisAppendJsonl(
                state.memory.eventsPath,
                %*{
                  "kind": "memory_error",
                  "timestamp": plasticMetisUtcNow(),
                  "source_timestamp": job.timestamp,
                  "session": job.session,
                  "error": error.msg
                }
              )
              acquire(state.queueLock)
              inc state.failed
              state.lastError = error.msg
              release(state.queueLock)
            finally:
              acquire(state.queueLock)
              state.active = false
              release(state.queueLock)

        proc ensureInitialized*(memory: PlasticMetisMemory; llama: PlasticLlamaRuntime) =
          if memory.isNil or not memory.config.enabled or memory.initialized:
            return
          memory.ensureMetisPaths()
          try:
            memory.prepareRuntime()
            memory.prepareModel()
            let gil = plasticAcquirePythonGIL()
            try:
              memory.torchModule = pyImport("torch")
              memory.transformersModule = pyImport("transformers")
              let cudaModule = nimpy.getAttr(memory.torchModule, "cuda")
              if not nimpy.callMethod(
                cudaModule,
                "is_available"
              ).to(bool):
                raise newException(
                  PlasticRuntimeError,
                  "O checkpoint Metis oficial requer CUDA."
                )
              discard nimpy.callMethod(cudaModule, "empty_cache")

              let autoTokenizer = nimpy.getAttr(
                memory.transformersModule,
                "AutoTokenizer"
              )
              memory.tokenizerObject = plasticPyCallMethodKw(
                autoTokenizer,
                "from_pretrained",
                @[plasticPyBox(memory.modelPath)],
                @[
                  plasticPyKeyword("trust_remote_code", plasticPyBox(true)),
                  plasticPyKeyword("local_files_only", plasticPyBox(true)),
                  plasticPyKeyword(
                    "cache_dir",
                    plasticPyBox(memory.modelCachePath)
                  )
                ]
              )
              if nimpy.getAttr(
                memory.tokenizerObject,
                "pad_token_id"
              ) == plasticPyNone():
                nimpy.setAttr(
                  memory.tokenizerObject,
                  "pad_token",
                  nimpy.getAttr(memory.tokenizerObject, "eos_token")
                )

              let py = pyBuiltinsModule()
              var deviceMap: PyObject
              var maxMemory: PyObject

              if memory.config.layout == "auto":
                deviceMap = plasticPyBox("auto")
                maxMemory = nimpy.callMethod(py, "dict")

                let memoryInfo =
                  nimpy.callMethod(cudaModule, "mem_get_info")
                let freeGpuBytes = memoryInfo[0].to(int64)
                let totalGpuBytes = memoryInfo[1].to(int64)
                let freeGpuMiB =
                  max(0'i64, freeGpuBytes div (1024'i64 * 1024'i64))
                let totalGpuMiB =
                  max(0'i64, totalGpuBytes div (1024'i64 * 1024'i64))
                let reserveMiB =
                  parseInt(
                    getEnv(
                      "GLAUCOPLASTIC_METIS_GPU_RESERVE_MIB",
                      "768"
                    )
                  ).int64
                let usableGpuMiB =
                  max(512'i64, freeGpuMiB - reserveMiB)
                let minimumGpuMiB =
                  parseInt(
                    getEnv(
                      "GLAUCOPLASTIC_METIS_MIN_FREE_GPU_MIB",
                      "2048"
                    )
                  ).int64

                if freeGpuMiB < minimumGpuMiB:
                  raise newException(
                    PlasticRuntimeError,
                    "Memória CUDA insuficiente para iniciar o Metis: " &
                    $freeGpuMiB & " MiB livres de " &
                    $totalGpuMiB & " MiB. O llama-server deve usar " &
                    "--n-gpu-layers 0 e outros processos CUDA devem ser " &
                    "encerrados antes do carregamento."
                  )

                maxMemory[0] = $usableGpuMiB & "MiB"
                maxMemory["cpu"] =
                  getEnv("GLAUCOPLASTIC_METIS_CPU_MEMORY", "48GiB")
              elif memory.config.layout == "hybrid":
                deviceMap = nimpy.callMethod(py, "dict")
                deviceMap[""] = memory.config.device
                deviceMap[
                  "model.metis_backbone.model.embed_tokens"
                ] = "cpu"
                deviceMap["model.metis_backbone.lm_head"] = "cpu"
              elif memory.config.layout == "gpu":
                deviceMap = nimpy.callMethod(py, "dict")
                deviceMap[""] = memory.config.device
              else:
                raise newException(
                  PlasticRuntimeError,
                  "Layout Metis inválido: " & memory.config.layout
                )

              let dtype = memory.plasticMetisDtype()
              let bitsAndBytesConfig = nimpy.getAttr(
                memory.transformersModule,
                "BitsAndBytesConfig"
              )
              let autoModel = nimpy.getAttr(
                memory.transformersModule,
                "AutoModelForCausalLM"
              )

              let offloadPath =
                memory.runtimeRoot / "offload"
              createDir(offloadPath)

              var modelKeywords: seq[PlasticPyKeyword] = @[
                plasticPyKeyword("trust_remote_code", plasticPyBox(true)),
                plasticPyKeyword("local_files_only", plasticPyBox(true)),
                plasticPyKeyword(
                  "cache_dir",
                  plasticPyBox(memory.modelCachePath)
                ),
                plasticPyKeyword("dtype", dtype),
                plasticPyKeyword("device_map", deviceMap),
                plasticPyKeyword("low_cpu_mem_usage", plasticPyBox(true)),
                plasticPyKeyword("offload_buffers", plasticPyBox(true)),
                plasticPyKeyword(
                  "offload_folder",
                  plasticPyBox(offloadPath)
                ),
                plasticPyKeyword(
                  "offload_state_dict",
                  plasticPyBox(true)
                )
              ]

              if memory.config.layout == "auto":
                modelKeywords.add plasticPyKeyword(
                  "max_memory",
                  maxMemory
                )

              if memory.config.quantization == "4bit":
                let quantization = plasticPyCallKw(
                  bitsAndBytesConfig,
                  newSeq[PyObject](),
                  @[
                    plasticPyKeyword("load_in_4bit", plasticPyBox(true)),
                    plasticPyKeyword(
                      "bnb_4bit_quant_type",
                      plasticPyBox("nf4")
                    ),
                    plasticPyKeyword(
                      "bnb_4bit_use_double_quant",
                      plasticPyBox(true)
                    ),
                    plasticPyKeyword("bnb_4bit_compute_dtype", dtype),
                    plasticPyKeyword(
                      "llm_int8_enable_fp32_cpu_offload",
                      plasticPyBox(true)
                    )
                  ]
                )
                modelKeywords.add plasticPyKeyword(
                  "quantization_config",
                  quantization
                )
              elif memory.config.quantization == "8bit":
                let quantization = plasticPyCallKw(
                  bitsAndBytesConfig,
                  newSeq[PyObject](),
                  @[
                    plasticPyKeyword("load_in_8bit", plasticPyBox(true)),
                    plasticPyKeyword(
                      "llm_int8_enable_fp32_cpu_offload",
                      plasticPyBox(true)
                    )
                  ]
                )
                modelKeywords.add plasticPyKeyword(
                  "quantization_config",
                  quantization
                )
              elif memory.config.quantization != "none":
                raise newException(
                  PlasticRuntimeError,
                  "Quantização Metis inválida: " & memory.config.quantization
                )

              memory.modelObject = plasticPyCallMethodKw(
                autoModel,
                "from_pretrained",
                @[plasticPyBox(memory.modelPath)],
                modelKeywords
              )
              plasticDebugTrace(
                "metis.init model.from_pretrained concluído"
              )

              discard nimpy.callMethod(memory.modelObject, "eval")
              plasticDebugTrace("metis.init model.eval concluído")

              memory.inputDeviceObject = nimpy.callMethod(
                memory.torchModule,
                "device",
                if memory.config.layout == "hybrid": "cpu"
                else: memory.config.device
              )

              if fileExists(memory.snapshotPath):
                discard memory.plasticMetisRestoreDirect()
                plasticDebugTrace(
                  "metis.init snapshot restaurado"
                )
            finally:
              plasticDebugTrace(
                "metis.init liberando GIL após carregamento"
              )
              plasticReleasePythonGIL(gil)

            plasticDebugTrace(
              "metis.init preparando worker de memória"
            )
            memory.workerState = PlasticMetisWorkerState(
              memory: memory,
              llamaEndpoint: llama.endpoint,
              llamaModel: llama.config.modelAlias,
              jobs: @[],
              running: false,
              stopping: false,
              active: false,
              processed: 0,
              skipped: 0,
              failed: 0,
              lastError: ""
            )
            initLock(memory.workerState.queueLock)
            initLock(memory.workerState.modelLock)
            if memory.config.memoryMode in ["deferred", "raw-deferred"]:
              createThread(
                memory.workerThread,
                runPlasticMetisWorker,
                memory.workerState
              )
              plasticDebugTrace(
                "metis.init worker de memória iniciado"
              )
            memory.initialized = true
            memory.lastError = ""
          except CatchableError as error:
            memory.lastError = error.msg
            raise newException(
              PlasticRuntimeError,
              "Falha ao iniciar memória Metis: " & error.msg
            )

        proc query*(
          memory: PlasticMetisMemory;
          llama: PlasticLlamaRuntime;
          session, text: string
        ): string =
          if memory.isNil or not memory.config.enabled:
            return "SEM_MEMORIA_RELEVANTE"
          memory.ensureInitialized(llama)
          acquire(memory.workerState.modelLock)
          let gil = plasticAcquirePythonGIL()
          try:
            result = memory.plasticMetisQueryDirect(text)
          finally:
            plasticReleasePythonGIL(gil)
            release(memory.workerState.modelLock)

        proc recordExchange*(
          memory: PlasticMetisMemory;
          llama: PlasticLlamaRuntime;
          session, userText, assistantText: string
        ) =
          if memory.isNil or not memory.config.enabled:
            return
          memory.ensureInitialized(llama)
          let safeSession = plasticMetisSafeName(session)
          let timestamp = plasticMetisUtcNow()
          memory.saveSessionExchange(safeSession, userText, assistantText)
          plasticMetisAppendJsonl(
            memory.exchangesPath,
            %*{
              "timestamp": timestamp,
              "profile": memory.config.profile,
              "session": safeSession,
              "user": userText,
              "assistant": assistantText,
              "memory_mode": memory.config.memoryMode,
              "memory_state":
                if memory.config.memoryMode in ["deferred", "raw-deferred"]:
                  "queued"
                else:
                  "committed"
            }
          )

          if memory.config.memoryMode == "immediate":
            acquire(memory.workerState.modelLock)
            let gil = plasticAcquirePythonGIL()
            try:
              memory.plasticMetisCommitDirect(userText, assistantText)
              memory.plasticMetisSaveDirect()
            finally:
              plasticReleasePythonGIL(gil)
              release(memory.workerState.modelLock)
          elif memory.config.memoryMode in ["deferred", "raw-deferred"]:
            let job = PlasticMetisMemoryJob(
              timestamp: timestamp,
              session: safeSession,
              userText:
                if memory.config.memoryMode == "raw-deferred":
                  "Memorize integralmente a seguinte mensagem do usuário:\n" &
                  userText
                else:
                  userText,
              assistantText: assistantText,
              extractWithLlama: memory.config.memoryMode != "raw-deferred"
            )
            acquire(memory.workerState.queueLock)
            memory.workerState.jobs.add job
            release(memory.workerState.queueLock)
          else:
            raise newException(
              PlasticRuntimeError,
              "Modo de memória Metis inválido: " & memory.config.memoryMode
            )

        proc clearSession*(memory: PlasticMetisMemory; session: string) =
          let path = memory.sessionPath(session)
          if fileExists(path):
            removeFile(path)

        # Declaracao antecipada: rebuild/reset usam flush antes da implementacao.
        proc flush*(memory: PlasticMetisMemory)

        proc rebuild*(
          memory: PlasticMetisMemory;
          llama: PlasticLlamaRuntime
        ): int =
          if memory.isNil or not memory.config.enabled:
            return 0
          memory.ensureInitialized(llama)
          memory.flush()
          acquire(memory.workerState.modelLock)
          let gil = plasticAcquirePythonGIL()
          try:
            discard nimpy.callMethod(memory.modelObject, "reset")
            if fileExists(memory.exchangesPath):
              for line in lines(memory.exchangesPath):
                let text = line.strip
                if text.len == 0:
                  continue
                let event = parseJson(text)
                if event.kind == JObject and event.hasKey("user") and
                    event.hasKey("assistant") and
                    event["user"].kind == JString and
                    event["assistant"].kind == JString:
                  memory.plasticMetisCommitDirect(
                    event["user"].getStr,
                    event["assistant"].getStr
                  )
                  inc result
            memory.plasticMetisSaveDirect()
          finally:
            plasticReleasePythonGIL(gil)
            release(memory.workerState.modelLock)

        proc reset*(
          memory: PlasticMetisMemory;
          llama: PlasticLlamaRuntime
        ) =
          if memory.isNil or not memory.config.enabled:
            return
          memory.ensureInitialized(llama)
          memory.flush()
          acquire(memory.workerState.modelLock)
          let gil = plasticAcquirePythonGIL()
          try:
            discard nimpy.callMethod(memory.modelObject, "reset")
          finally:
            plasticReleasePythonGIL(gil)
            release(memory.workerState.modelLock)
          if fileExists(memory.snapshotPath):
            removeFile(memory.snapshotPath)
          if fileExists(memory.exchangesPath):
            removeFile(memory.exchangesPath)

        proc statusJson*(memory: PlasticMetisMemory): JsonNode =
          result = %*{
            "enabled": memory.config.enabled,
            "startup": memory.config.startup,
            "runtimePrepared": memory.runtimePrepared,
            "modelPrepared": memory.modelPrepared,
            "initialized": memory.initialized,
            "python": memory.pythonExecutable,
            "model": memory.config.modelId,
            "modelPath": memory.modelPath,
            "profile": memory.config.profile,
            "mode": memory.config.memoryMode,
            "snapshotPath": memory.snapshotPath,
            "lastError": memory.lastError
          }
          if memory.initialized and not memory.workerState.isNil:
            acquire(memory.workerState.queueLock)
            result["worker"] = %*{
              "active": memory.workerState.active,
              "queued": memory.workerState.jobs.len,
              "processed": memory.workerState.processed,
              "skipped": memory.workerState.skipped,
              "failed": memory.workerState.failed,
              "lastError": memory.workerState.lastError
            }
            release(memory.workerState.queueLock)

        proc flush*(memory: PlasticMetisMemory) =
          if memory.isNil or not memory.initialized:
            return
          if memory.config.memoryMode in ["deferred", "raw-deferred"]:
            while true:
              acquire(memory.workerState.queueLock)
              let pending = memory.workerState.jobs.len
              let active = memory.workerState.active
              release(memory.workerState.queueLock)
              if pending == 0 and not active:
                break
              sleep(25)
          acquire(memory.workerState.modelLock)
          let gil = plasticAcquirePythonGIL()
          try:
            memory.plasticMetisSaveDirect()
          finally:
            plasticReleasePythonGIL(gil)
            release(memory.workerState.modelLock)

        proc stop*(memory: PlasticMetisMemory) =
          if memory.isNil or not memory.initialized:
            return
          memory.flush()
          if memory.config.memoryMode in ["deferred", "raw-deferred"]:
            acquire(memory.workerState.queueLock)
            memory.workerState.stopping = true
            release(memory.workerState.queueLock)
            joinThread(memory.workerThread)
          deinitLock(memory.workerState.queueLock)
          deinitLock(memory.workerState.modelLock)
          memory.initialized = false


        proc defaultLlamaConfig*(): PlasticLlamaConfig =
          PlasticLlamaConfig(
            host: plasticDefaultLlamaHostCandidates()[0],
            port: plasticDefaultLlamaPortCandidates()[0],
            modelAlias: getEnv("GLAUCOPLASTIC_MODEL_ALIAS", "qwen3-4b"),
            contextSize: parseInt(getEnv("GLAUCOPLASTIC_CONTEXT_SIZE", "32768")),
            gpuLayers: parseInt(getEnv("GLAUCOPLASTIC_GPU_LAYERS", "0")),
            temperature: parseFloat(getEnv("GLAUCOPLASTIC_TEMPERATURE", "0.1")),
            maxTokens: parseInt(getEnv("GLAUCOPLASTIC_MAX_TOKENS", "2048")),
            logResponseBody: getEnv("GLAUCOPLASTIC_LLM_LOG_RESPONSE", "0").strip.toLowerAscii in ["1", "true", "yes", "on", "enabled"]
          )

        proc defaultLlamaModelRepo*(): string =
          getEnv("GLAUCOPLASTIC_MODEL_REPO", "unsloth/gemma-4-E4B-it-GGUF")

        proc defaultLlamaModelFile*(): string =
          getEnv("GLAUCOPLASTIC_MODEL_FILE", "gemma-4-E4B-it-Q4_K_M.gguf")

        proc defaultLlamaModelPath*(): string =
          let configured = getEnv("GLAUCOPLASTIC_MODEL_PATH")
          if configured.len > 0:
            return expandTilde(configured)

          let modelFile = defaultLlamaModelFile()
          for candidate in [
            getHomeDir() / "models" / modelFile,
            getAppDir() / "models" / modelFile,
            getCurrentDir() / "models" / modelFile
          ]:
            if fileExists(candidate):
              return candidate

          result = getAppDir() / "models" / modelFile

        proc defaultLlamaModelDir*(modelPath = defaultLlamaModelPath()): string =
          if modelPath.len > 0:
            result = modelPath.parentDir
          else:
            result = getAppDir() / "models"

        proc defaultLlamaDownloadScript*(): string =
          for candidate in [
            getAppDir() / "scripts" / "download-gemma4.sh",
            getCurrentDir() / "scripts" / "download-gemma4.sh",
            getAppDir() / "scripts" / "configure-qwen3-model.sh",
            getCurrentDir() / "scripts" / "configure-qwen3-model.sh"
          ]:
            if fileExists(candidate):
              return candidate
          result = ""

        proc defaultLlamaAutoDownload*(): bool =
          getEnv("GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL", "0") != "0"

        proc defaultHfToken*(): string =
          result = getEnv("HF_TOKEN")
          if result.len == 0:
            result = getEnv("HUGGING_FACE_HUB_TOKEN")

        proc llamaModelDownloadUrl*(llama: PlasticLlamaRuntime): string =
          let encodedFile =
            llama.modelFile
              .split('/')
              .mapIt(encodeUrl(it, false))
              .join("/")
          result =
            "https://huggingface.co/" &
            llama.modelRepo &
            "/resolve/main/" &
            encodedFile

        proc humanByteCount*(bytes: BiggestInt): string =
          let units = ["B", "KB", "MB", "GB", "TB"]
          var size = bytes.float
          var unitIndex = 0
          while size >= 1024.0 and unitIndex < units.high:
            size = size / 1024.0
            inc unitIndex

          if unitIndex == 0:
            result = $bytes & " " & units[unitIndex]
          else:
            result = formatFloat(size, ffDecimal, 1) & " " & units[unitIndex]

        proc isValidGgufModelFile*(path: string): bool =
          if path.len == 0 or not fileExists(path):
            return false

          let size =
            try:
              getFileSize(path)
            except CatchableError:
              return false

          if size < 4:
            return false

          var f: File
          if not open(f, path, fmRead):
            return false

          try:
            var magic: array[4, char]
            if readBuffer(f, addr magic[0], 4) != 4:
              return false
            result =
              magic[0] == 'G' and
              magic[1] == 'G' and
              magic[2] == 'U' and
              magic[3] == 'F'
          except CatchableError:
            result = false
          finally:
            close(f)

        proc bootDownloadProgress(
          state: PlasticLlamaBootState;
          modelName: string;
          total, progress, speed: BiggestInt
        ) {.gcsafe.} =
          if state.isNil:
            return

          let totalBytes = if total > 0: total else: 0
          let downloadedBytes = if progress > 0: progress else: 0
          let speedText =
            if speed > 0:
              humanByteCount(speed) & "/s"
            else:
              "aguardando dados"
          let detailText =
            if totalBytes > 0:
              humanByteCount(downloadedBytes) & " de " &
              humanByteCount(totalBytes) & " recebidos"
            else:
              humanByteCount(downloadedBytes) & " recebidos"
          let transferPercent =
            if totalBytes > 0:
              clamp(int((downloadedBytes * 100) div totalBytes), 0, 100)
            else:
              0

          state.setLlamaBootState(
            "Baixando modelo GGUF",
            "Baixando " & modelName & " do Hugging Face",
            modelName,
            (if totalBytes > 0: $transferPercent & "% | " else: "") &
              detailText & " | " & speedText,
            transferPercent
          )

        proc resetLlamaDownloadResidue*(llama: PlasticLlamaRuntime) =
          if llama.modelDir.len == 0 or not dirExists(llama.modelDir):
            return

          let targetName =
            if llama.modelPath.len > 0:
              extractFilename(llama.modelPath)
            else:
              ""

          for kind, path in walkDir(llama.modelDir):
            if kind != pcFile:
              continue

            let fileName = extractFilename(path)
            let shouldRemove =
              fileName.endsWith(".partial") or
              fileName.endsWith(".tmp") or
              fileName.endsWith(".download") or
              fileName.endsWith(".incomplete") or
              fileName.endsWith(".lock") or
              (targetName.len > 0 and
                fileName.startsWith(targetName) and
                fileName != targetName)

            if shouldRemove:
              try:
                removeFile(path)
                plasticDebugTrace("llama download residue removed: " & path)
              except CatchableError:
                discard

        proc platformLlamaCandidates(): seq[string] =
          let configured = getEnv("GLAUCOPLASTIC_LLAMA_BIN")
          if configured.len > 0:
            result.add expandTilde(configured)

          when defined(windows):
            result.add @[
              getAppDir() / "runtime" / "llama" / "windows-x64" / "bin" / "llama-server.exe",
              getCurrentDir() / "runtime" / "llama" / "windows-x64" / "bin" / "llama-server.exe",
              getAppDir() / "runtime" / "llama" / "windows-x64" / "llama-server.exe",
              getCurrentDir() / "runtime" / "llama" / "windows-x64" / "llama-server.exe",
              getAppDir() / "runtime" / "llama" / "llama-server.exe",
              getCurrentDir() / "runtime" / "llama" / "llama-server.exe"
            ]
          else:
            result.add @[
              getAppDir() / "runtime" / "llama" / "linux-x64" / "bin" / "llama-server",
              getCurrentDir() / "runtime" / "llama" / "linux-x64" / "bin" / "llama-server",
              getAppDir() / "runtime" / "llama" / "linux-x64" / "llama-server",
              getCurrentDir() / "runtime" / "llama" / "linux-x64" / "llama-server",
              getAppDir() / "runtime" / "llama" / "llama-server",
              getCurrentDir() / "runtime" / "llama" / "llama-server",
              getHomeDir() / ".local" / "src" / "llama.cpp" / "build-cuda" / "bin" / "llama-server"
            ]

        proc defaultModelCandidates(): seq[string] =
          let configured = getEnv("GLAUCOPLASTIC_MODEL_PATH")
          if configured.len > 0:
            result.add expandTilde(configured)

          result.add @[
            getAppDir() / "models" / "gemma-4-E4B-it-Q4_K_M.gguf",
            getCurrentDir() / "models" / "gemma-4-E4B-it-Q4_K_M.gguf",
            getHomeDir() / "models" / "gemma-4-E4B-it-Q4_K_M.gguf"
          ]

        proc firstExistingFile(candidates: seq[string]): string =
          for candidate in candidates:
            if fileExists(candidate):
              return candidate
          ""

        type
          PlasticLlamaReleaseAsset = object
            name: string
            downloadUrl: string
            digest: string
            size: BiggestInt

          PlasticLlamaRelease = object
            tag: string
            publishedAt: string
            assets: seq[PlasticLlamaReleaseAsset]

        proc defaultLlamaRuntimeRoot*(): string =
          let configured = getEnv("GLAUCOPLASTIC_LLAMA_RUNTIME_ROOT")
          if configured.len > 0:
            return expandTilde(configured)
          getAppDir() / "runtime" / "llama"

        proc defaultLlamaReleaseRepo*(): string =
          getEnv("GLAUCOPLASTIC_LLAMA_RELEASE_REPO", "ggml-org/llama.cpp")

        proc defaultLlamaReleaseVersion*(): string =
          getEnv("GLAUCOPLASTIC_LLAMA_VERSION", "")

        proc defaultLlamaReleaseBackend*(): string =
          getEnv("GLAUCOPLASTIC_LLAMA_BACKEND", "auto")

        proc defaultLlamaAutoDownloadRuntime*(): bool =
          getEnv("GLAUCOPLASTIC_LLAMA_AUTO_DOWNLOAD_RUNTIME", "1") != "0"

        proc defaultLlamaAutoUpdateRuntime*(): bool =
          getEnv("GLAUCOPLASTIC_LLAMA_AUTO_UPDATE_RUNTIME", "1") != "0"

        proc defaultLlamaUpdateIntervalHours*(): int =
          try:
            parseInt(getEnv("GLAUCOPLASTIC_LLAMA_UPDATE_INTERVAL_HOURS", "24"))
          except ValueError:
            24

        proc plasticLlamaPlatformName(): string =
          when defined(windows):
            "windows"
          elif defined(linux):
            "linux"
          else:
            "unsupported"

        proc plasticLlamaArchitectureName(): string =
          when defined(amd64):
            "x64"
          elif defined(arm64):
            "arm64"
          else:
            "unsupported"

        proc plasticLlamaRuntimeManifestPath(llama: PlasticLlamaRuntime): string =
          llama.runtimeRoot / "current.json"

        proc plasticJsonString(node: JsonNode; key: string; fallback = ""): string =
          if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
            node[key].getStr
          else:
            fallback

        proc plasticJsonEpoch(node: JsonNode; key: string): float =
          if node.kind != JObject or not node.hasKey(key):
            return 0.0
          case node[key].kind
          of JInt:
            node[key].getInt.float
          of JFloat:
            node[key].getFloat
          else:
            0.0

        proc plasticLlamaLoadManifest(llama: PlasticLlamaRuntime): JsonNode =
          let path = llama.plasticLlamaRuntimeManifestPath()
          if not fileExists(path):
            return newJObject()
          try:
            parseJson(readFile(path))
          except CatchableError:
            newJObject()

        proc plasticLlamaWriteManifest(
          llama: PlasticLlamaRuntime;
          release: PlasticLlamaRelease;
          asset: PlasticLlamaReleaseAsset;
          executablePath, backend: string
        ) =
          if not dirExists(llama.runtimeRoot):
            createDir(llama.runtimeRoot)
          let manifestPath = llama.plasticLlamaRuntimeManifestPath()
          let partialPath = manifestPath & ".partial"
          let manifest = %*{
            "schema": 1,
            "repository": llama.releaseRepo,
            "tag": release.tag,
            "publishedAt": release.publishedAt,
            "asset": asset.name,
            "digest": asset.digest,
            "backend": backend,
            "platform": plasticLlamaPlatformName(),
            "architecture": plasticLlamaArchitectureName(),
            "executable": executablePath,
            "installedAtEpoch": epochTime(),
            "lastCheckedEpoch": epochTime()
          }
          writeFile(partialPath, pretty(manifest))
          if fileExists(manifestPath):
            removeFile(manifestPath)
          moveFile(partialPath, manifestPath)

        proc plasticLlamaTouchManifest(
          llama: PlasticLlamaRuntime;
          manifest: JsonNode
        ) =
          if manifest.kind != JObject:
            return
          manifest["lastCheckedEpoch"] = %epochTime()
          let manifestPath = llama.plasticLlamaRuntimeManifestPath()
          let partialPath = manifestPath & ".partial"
          if not dirExists(llama.runtimeRoot):
            createDir(llama.runtimeRoot)
          writeFile(partialPath, pretty(manifest))
          if fileExists(manifestPath):
            removeFile(manifestPath)
          moveFile(partialPath, manifestPath)

        proc plasticLlamaResolveManifestExecutable(
          llama: PlasticLlamaRuntime
        ): string =
          let manifest = llama.plasticLlamaLoadManifest()
          let path = plasticJsonString(manifest, "executable")
          if path.len > 0 and fileExists(path):
            llama.installedTag = plasticJsonString(manifest, "tag")
            llama.installedAsset = plasticJsonString(manifest, "asset")
            llama.managedRuntime = true
            return path
          ""

        proc plasticGitHubHeaders(): HttpHeaders =
          let token =
            block:
              let githubToken = getEnv("GITHUB_TOKEN")
              if githubToken.len > 0:
                githubToken
              else:
                getEnv("GH_TOKEN")
          if token.len > 0:
            newHttpHeaders({
              "Accept": "application/vnd.github+json",
              "Authorization": "Bearer " & token,
              "User-Agent": "GlaucoPlastic-llama-runtime"
            })
          else:
            newHttpHeaders({
              "Accept": "application/vnd.github+json",
              "User-Agent": "GlaucoPlastic-llama-runtime"
            })

        proc plasticLlamaReleaseEndpoint(llama: PlasticLlamaRuntime): string =
          let base = "https://api.github.com/repos/" & llama.releaseRepo & "/releases/"
          if llama.releaseVersion.strip.len > 0 and
              llama.releaseVersion.strip.toLowerAscii != "latest":
            base & "tags/" & encodeUrl(llama.releaseVersion.strip, false)
          else:
            base & "latest"

        proc plasticLlamaFetchRelease(
          llama: PlasticLlamaRuntime
        ): PlasticLlamaRelease =
          var client = newHttpClient(
            timeout = 30_000,
            maxRedirects = 5,
            headers = plasticGitHubHeaders()
          )
          try:
            let response = client.get(llama.plasticLlamaReleaseEndpoint())
            if not response.status.startsWith("200"):
              raise newException(
                PlasticRuntimeError,
                "GitHub Releases retornou " & response.status &
                " ao consultar o runtime llama.cpp."
              )
            let payload = parseJson(response.body)
            result.tag = plasticJsonString(payload, "tag_name")
            result.publishedAt = plasticJsonString(payload, "published_at")
            if result.tag.len == 0:
              raise newException(
                PlasticRuntimeError,
                "A release do llama.cpp não contém tag_name."
              )
            if payload.kind == JObject and payload.hasKey("assets") and
                payload["assets"].kind == JArray:
              for item in payload["assets"].items:
                if item.kind != JObject:
                  continue
                var asset = PlasticLlamaReleaseAsset(
                  name: plasticJsonString(item, "name"),
                  downloadUrl: plasticJsonString(item, "browser_download_url"),
                  digest: plasticJsonString(item, "digest"),
                  size: 0
                )
                if item.hasKey("size") and item["size"].kind == JInt:
                  asset.size = item["size"].getInt.BiggestInt
                if asset.name.len > 0 and asset.downloadUrl.len > 0:
                  result.assets.add(asset)
          finally:
            client.close()

        proc plasticLlamaRequestedBackend(llama: PlasticLlamaRuntime): string =
          let configured = llama.releaseBackend.strip.toLowerAscii
          if configured.len > 0 and configured != "auto":
            return configured

          if llama.config.gpuLayers <= 0:
            return "cpu"

          when defined(windows):
            if findExe("nvidia-smi").len > 0:
              return "cuda12"
            if findExe("vulkaninfo").len > 0:
              return "vulkan"
          elif defined(linux):
            if findExe("vulkaninfo").len > 0:
              return "vulkan"
          "cpu"

        proc plasticLlamaAssetMatches(
          assetName, backend, architecture: string
        ): bool =
          let name = assetName.toLowerAscii
          when defined(windows):
            if not name.startsWith("llama-") or not name.endsWith(".zip"):
              return false
            case backend
            of "cpu":
              name.endsWith("-bin-win-cpu-" & architecture & ".zip")
            of "vulkan":
              architecture == "x64" and
                name.endsWith("-bin-win-vulkan-x64.zip")
            of "cuda", "cuda12", "cuda12.4":
              architecture == "x64" and
                name.contains("-bin-win-cuda-12.") and name.endsWith("-x64.zip")
            of "cuda13", "cuda13.3":
              architecture == "x64" and
                name.contains("-bin-win-cuda-13.") and name.endsWith("-x64.zip")
            of "hip", "rocm":
              architecture == "x64" and
                name.endsWith("-bin-win-hip-radeon-x64.zip")
            of "openvino":
              architecture == "x64" and
                name.contains("-bin-win-openvino-") and name.endsWith("-x64.zip")
            of "sycl":
              architecture == "x64" and
                name.endsWith("-bin-win-sycl-x64.zip")
            else:
              false
          elif defined(linux):
            if not name.startsWith("llama-") or not name.endsWith(".tar.gz"):
              return false
            case backend
            of "cpu":
              name.endsWith("-bin-ubuntu-" & architecture & ".tar.gz")
            of "vulkan":
              name.endsWith("-bin-ubuntu-vulkan-" & architecture & ".tar.gz")
            of "rocm", "hip":
              architecture == "x64" and
                name.contains("-bin-ubuntu-rocm-") and name.endsWith("-x64.tar.gz")
            of "openvino":
              architecture == "x64" and
                name.contains("-bin-ubuntu-openvino-") and name.endsWith("-x64.tar.gz")
            of "sycl", "sycl-fp16":
              architecture == "x64" and
                name.endsWith("-bin-ubuntu-sycl-fp16-x64.tar.gz")
            of "sycl-fp32":
              architecture == "x64" and
                name.endsWith("-bin-ubuntu-sycl-fp32-x64.tar.gz")
            else:
              false
          else:
            false

        proc plasticLlamaSelectAsset(
          llama: PlasticLlamaRuntime;
          release: PlasticLlamaRelease;
          backend: var string
        ): PlasticLlamaReleaseAsset =
          let architecture = plasticLlamaArchitectureName()
          if architecture == "unsupported":
            raise newException(
              PlasticInstallationError,
              "Arquitetura sem runtime oficial do llama.cpp nesta versão."
            )

          for asset in release.assets:
            if plasticLlamaAssetMatches(asset.name, backend, architecture):
              return asset

          let explicitlyConfigured =
            llama.releaseBackend.strip.len > 0 and
            llama.releaseBackend.strip.toLowerAscii != "auto"
          if backend != "cpu" and not explicitlyConfigured:
            plasticDebugTrace(
              "llama runtime: backend " & backend &
              " indisponível; usando CPU."
            )
            backend = "cpu"
            for asset in release.assets:
              if plasticLlamaAssetMatches(asset.name, backend, architecture):
                return asset

          raise newException(
            PlasticInstallationError,
            "A release " & release.tag &
            " não possui um runtime compatível com " &
            plasticLlamaPlatformName() & "-" & architecture &
            " e backend " & backend & "."
          )

        proc plasticLlamaCompanionAssets(
          release: PlasticLlamaRelease;
          primary: PlasticLlamaReleaseAsset
        ): seq[PlasticLlamaReleaseAsset] =
          when defined(windows):
            let lowerName = primary.name.toLowerAscii
            var prefix = ""
            if lowerName.contains("-bin-win-cuda-12."):
              prefix = "cudart-llama-bin-win-cuda-12."
            elif lowerName.contains("-bin-win-cuda-13."):
              prefix = "cudart-llama-bin-win-cuda-13."
            if prefix.len > 0:
              for asset in release.assets:
                let candidate = asset.name.toLowerAscii
                if candidate.startsWith(prefix) and candidate.endsWith("-x64.zip"):
                  result.add(asset)
                  break

        proc plasticPowerShellLiteral(value: string): string =
          "'" & value.replace("'", "''") & "'"

        proc plasticFileSha256(path: string): string =
          when defined(windows):
            var powershell = findExe("powershell.exe")
            if powershell.len == 0:
              powershell = findExe("pwsh.exe")
            if powershell.len == 0:
              return ""
            let script =
              "(Get-FileHash -Algorithm SHA256 -LiteralPath " &
              plasticPowerShellLiteral(path) & ").Hash.ToLowerInvariant()"
            let command =
              quoteShell(powershell) &
              " -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " &
              quoteShell(script)
            let execution = execCmdEx(
              command,
              options = {poUsePath, poStdErrToStdOut}
            )
            if execution.exitCode == 0:
              result = execution.output.strip.toLowerAscii
          else:
            let sha256sum = findExe("sha256sum")
            if sha256sum.len > 0:
              let execution = execCmdEx(
                quoteShell(sha256sum) & " " & quoteShell(path),
                options = {poUsePath, poStdErrToStdOut}
              )
              if execution.exitCode == 0:
                let parts = execution.output.strip.splitWhitespace()
                if parts.len > 0:
                  return parts[0].toLowerAscii
            let openssl = findExe("openssl")
            if openssl.len > 0:
              let execution = execCmdEx(
                quoteShell(openssl) & " dgst -sha256 " & quoteShell(path),
                options = {poUsePath, poStdErrToStdOut}
              )
              if execution.exitCode == 0:
                let output = execution.output.strip
                let separator = output.rfind('=')
                if separator >= 0:
                  return output[(separator + 1) .. ^1].strip.toLowerAscii

        proc plasticLlamaVerifyAsset(
          asset: PlasticLlamaReleaseAsset;
          path: string
        ) =
          if not fileExists(path):
            raise newException(
              PlasticRuntimeError,
              "O download do runtime não gerou o arquivo " & path
            )
          if asset.size > 0 and getFileSize(path) != asset.size:
            raise newException(
              PlasticRuntimeError,
              "Tamanho inválido no asset " & asset.name & "."
            )
          if asset.digest.toLowerAscii.startsWith("sha256:"):
            let expected = asset.digest.split(':', 1)[1].strip.toLowerAscii
            let actual = plasticFileSha256(path)
            if actual.len == 0:
              raise newException(
                PlasticRuntimeError,
                "Não foi possível calcular SHA-256 de " & asset.name & "."
              )
            if actual != expected:
              raise newException(
                PlasticRuntimeError,
                "SHA-256 inválido para " & asset.name & "."
              )

        proc plasticLlamaRuntimeDownloadProgress(
          state: PlasticLlamaBootState;
          assetName: string;
          total, progress, speed: BiggestInt
        ) {.gcsafe.} =
          if state.isNil:
            return
          let totalBytes = if total > 0: total else: 0
          let downloaded = if progress > 0: progress else: 0
          let transferPercent =
            if totalBytes > 0:
              clamp(int((downloaded * 100) div totalBytes), 0, 100)
            else:
              0
          let detail =
            if totalBytes > 0:
              humanByteCount(downloaded) & " de " & humanByteCount(totalBytes)
            else:
              humanByteCount(downloaded)
          state.setLlamaBootState(
            "Baixando llama.cpp",
            "GitHub Releases",
            assetName,
            (if totalBytes > 0: $transferPercent & "% | " else: "") &
              detail &
              (if speed > 0: " | " & humanByteCount(speed) & "/s" else: ""),
            transferPercent
          )

        proc plasticLlamaDownloadAsset(
          llama: PlasticLlamaRuntime;
          release: PlasticLlamaRelease;
          asset: PlasticLlamaReleaseAsset;
          state: PlasticLlamaBootState
        ): string =
          let downloadDir = llama.runtimeRoot / "downloads" / release.tag
          if not dirExists(downloadDir):
            createDir(downloadDir)
          let target = downloadDir / asset.name
          let partial = target & ".partial"
          if fileExists(partial):
            removeFile(partial)

          var client = newHttpClient(
            timeout = -1,
            maxRedirects = 10,
            headers = newHttpHeaders({
              "Accept": "application/octet-stream",
              "User-Agent": "GlaucoPlastic-llama-runtime"
            })
          )
          try:
            if not state.isNil:
              client.onProgressChanged = proc(
                total, progress, speed: BiggestInt
              ): void {.closure, gcsafe.} =
                plasticLlamaRuntimeDownloadProgress(
                  state,
                  asset.name,
                  total,
                  progress,
                  speed
                )
            client.downloadFile(asset.downloadUrl, partial)
            asset.plasticLlamaVerifyAsset(partial)
            if fileExists(target):
              removeFile(target)
            moveFile(partial, target)
            result = target
          except CatchableError:
            if fileExists(partial):
              try:
                removeFile(partial)
              except CatchableError:
                discard
            raise
          finally:
            client.close()

        proc plasticLlamaExtractArchive(archivePath, targetDir: string) =
          if dirExists(targetDir):
            removeDir(targetDir)
          createDir(targetDir)

          when defined(windows):
            var powershell = findExe("powershell.exe")
            if powershell.len == 0:
              powershell = findExe("pwsh.exe")
            if powershell.len == 0:
              raise newException(
                PlasticInstallationError,
                "PowerShell não foi encontrado para extrair o runtime llama.cpp."
              )
            let script =
              "Expand-Archive -LiteralPath " & plasticPowerShellLiteral(archivePath) &
              " -DestinationPath " & plasticPowerShellLiteral(targetDir) & " -Force"
            let execution = execCmdEx(
              quoteShell(powershell) &
                " -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " &
                quoteShell(script),
              options = {poUsePath, poStdErrToStdOut}
            )
            if execution.exitCode != 0:
              raise newException(
                PlasticRuntimeError,
                "Falha ao extrair " & extractFilename(archivePath) & ": " &
                execution.output.strip
              )
          else:
            let tar = findExe("tar")
            if tar.len == 0:
              raise newException(
                PlasticInstallationError,
                "O utilitário tar não foi encontrado para extrair o runtime llama.cpp."
              )
            let execution = execCmdEx(
              quoteShell(tar) & " -xzf " & quoteShell(archivePath) &
                " -C " & quoteShell(targetDir),
              options = {poUsePath, poStdErrToStdOut}
            )
            if execution.exitCode != 0:
              raise newException(
                PlasticRuntimeError,
                "Falha ao extrair " & extractFilename(archivePath) & ": " &
                execution.output.strip
              )

        proc plasticLlamaFindServer(root: string): string =
          let expected =
            when defined(windows): "llama-server.exe"
            else: "llama-server"
          if not dirExists(root):
            return ""
          for path in walkDirRec(root):
            if fileExists(path) and extractFilename(path).toLowerAscii == expected:
              return path
          ""

        proc plasticLlamaMakeExecutable(path: string) =
          when not defined(windows):
            var permissions = getFilePermissions(path)
            permissions.incl(fpUserExec)
            permissions.incl(fpGroupExec)
            permissions.incl(fpOthersExec)
            setFilePermissions(path, permissions)

        proc plasticLlamaValidateExecutable(path: string) =
          if path.len == 0 or not fileExists(path):
            raise newException(
              PlasticRuntimeError,
              "llama-server não foi encontrado após a extração."
            )
          plasticLlamaMakeExecutable(path)
          let execution = execCmdEx(
            quoteShell(path) & " --version",
            options = {poUsePath, poStdErrToStdOut}
          )
          if execution.exitCode != 0:
            raise newException(
              PlasticRuntimeError,
              "O llama-server baixado não pôde ser executado: " &
              execution.output.strip
            )

        proc plasticLlamaInstallRelease(
          llama: PlasticLlamaRuntime;
          release: PlasticLlamaRelease;
          primary: PlasticLlamaReleaseAsset;
          backend: string;
          state: PlasticLlamaBootState
        ) =
          let versionToken =
            release.tag.replace("/", "_").replace("\\", "_")
          let installDir =
            llama.runtimeRoot / "versions" /
            (versionToken & "-" & backend & "-" &
              plasticLlamaPlatformName() & "-" & plasticLlamaArchitectureName())
          let stagingDir = installDir & ".staging"
          let primaryArchive =
            llama.plasticLlamaDownloadAsset(release, primary, state)

          if not state.isNil:
            state.setLlamaBootState(
              "Instalando llama.cpp",
              plasticLlamaPlatformName() & "-" & plasticLlamaArchitectureName(),
              primary.name,
              "Extraindo release " & release.tag & "...",
              17
            )

          plasticLlamaExtractArchive(primaryArchive, stagingDir)
          for companion in plasticLlamaCompanionAssets(release, primary):
            let companionArchive =
              llama.plasticLlamaDownloadAsset(release, companion, state)
            when defined(windows):
              var powershell = findExe("powershell.exe")
              if powershell.len == 0:
                powershell = findExe("pwsh.exe")
              let script =
                "Expand-Archive -LiteralPath " & plasticPowerShellLiteral(companionArchive) &
                " -DestinationPath " & plasticPowerShellLiteral(stagingDir) & " -Force"
              let execution = execCmdEx(
                quoteShell(powershell) &
                  " -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " &
                  quoteShell(script),
                options = {poUsePath, poStdErrToStdOut}
              )
              if execution.exitCode != 0:
                raise newException(
                  PlasticRuntimeError,
                  "Falha ao extrair dependências CUDA do llama.cpp: " &
                  execution.output.strip
                )

          let stagedExecutable = plasticLlamaFindServer(stagingDir)
          plasticLlamaValidateExecutable(stagedExecutable)
          let executableRelative = relativePath(stagedExecutable, stagingDir)

          if dirExists(installDir):
            removeDir(installDir)
          moveDir(stagingDir, installDir)
          let executable = installDir / executableRelative
          plasticLlamaValidateExecutable(executable)

          llama.executablePath = executable
          llama.installedTag = release.tag
          llama.installedAsset = primary.name
          llama.managedRuntime = true
          llama.plasticLlamaWriteManifest(
            release,
            primary,
            executable,
            backend
          )

          if not state.isNil:
            state.setLlamaBootState(
              "llama.cpp instalado",
              plasticLlamaPlatformName() & "-" & plasticLlamaArchitectureName(),
              release.tag,
              "llama-server validado em " & executable,
              20
            )

        proc plasticLlamaUpdateCheckDue(
          llama: PlasticLlamaRuntime;
          manifest: JsonNode
        ): bool =
          if not llama.autoUpdateRuntime:
            return false
          if llama.releaseVersion.strip.len > 0 and
              llama.releaseVersion.strip.toLowerAscii != "latest" and
              plasticJsonString(manifest, "tag") != llama.releaseVersion.strip:
            return true
          if llama.updateIntervalHours <= 0:
            return true
          let checkedAt = plasticJsonEpoch(manifest, "lastCheckedEpoch")
          checkedAt <= 0.0 or
            epochTime() - checkedAt >= llama.updateIntervalHours.float * 3600.0

        proc ensureLlamaRuntime*(
          llama: PlasticLlamaRuntime;
          state: PlasticLlamaBootState = nil
        ) =
          let configured = getEnv("GLAUCOPLASTIC_LLAMA_BIN")
          if configured.len > 0:
            let explicitPath = expandTilde(configured)
            if not fileExists(explicitPath):
              raise newException(
                PlasticInstallationError,
                "GLAUCOPLASTIC_LLAMA_BIN aponta para um arquivo inexistente: " &
                explicitPath
              )
            llama.executablePath = explicitPath
            llama.managedRuntime = false
            return

          if llama.runtimeRoot.len == 0:
            llama.runtimeRoot = defaultLlamaRuntimeRoot()
          if llama.releaseRepo.len == 0:
            llama.releaseRepo = defaultLlamaReleaseRepo()
          if llama.releaseBackend.len == 0:
            llama.releaseBackend = defaultLlamaReleaseBackend()

          if llama.executablePath.len == 0 or not fileExists(llama.executablePath):
            llama.executablePath = llama.plasticLlamaResolveManifestExecutable()
          if llama.executablePath.len == 0 or not fileExists(llama.executablePath):
            let existing = firstExistingFile(platformLlamaCandidates())
            if existing.len > 0:
              llama.executablePath = existing
              llama.managedRuntime =
                absolutePath(existing).startsWith(absolutePath(llama.runtimeRoot))

          let hasRuntime =
            llama.executablePath.len > 0 and fileExists(llama.executablePath)
          if hasRuntime and not llama.managedRuntime:
            return
          if hasRuntime and not llama.autoUpdateRuntime:
            return

          let manifest = llama.plasticLlamaLoadManifest()
          if hasRuntime and not llama.plasticLlamaUpdateCheckDue(manifest):
            return
          if not hasRuntime and not llama.autoDownloadRuntime:
            raise newException(
              PlasticInstallationError,
              "llama-server ausente e o download automático do runtime está desativado."
            )

          if not state.isNil:
            state.setLlamaBootState(
              "Preparando llama.cpp",
              "Consultando GitHub Releases",
              plasticLlamaPlatformName() & "-" & plasticLlamaArchitectureName(),
              "Selecionando o runtime oficial compatível...",
              2
            )

          try:
            let release = llama.plasticLlamaFetchRelease()
            var backend = llama.plasticLlamaRequestedBackend()
            let asset = llama.plasticLlamaSelectAsset(release, backend)

            if hasRuntime and
                plasticJsonString(manifest, "tag") == release.tag and
                plasticJsonString(manifest, "asset") == asset.name:
              llama.installedTag = release.tag
              llama.installedAsset = asset.name
              llama.plasticLlamaTouchManifest(manifest)
              return

            llama.plasticLlamaInstallRelease(
              release,
              asset,
              backend,
              state
            )
          except CatchableError as error:
            if hasRuntime:
              plasticDebugTrace(
                "llama runtime update skipped after error: " & error.msg
              )
              if not state.isNil:
                state.setLlamaBootState(
                  "llama.cpp em cache",
                  "Atualização indisponível",
                  extractFilename(llama.executablePath),
                  "Usando o runtime instalado: " & error.msg,
                  20
                )
              return
            raise newException(
              PlasticInstallationError,
              "Falha ao preparar o runtime llama.cpp: " & error.msg
            )

        proc newLlamaRuntime*(config = defaultLlamaConfig()): PlasticLlamaRuntime =
          let modelPath = defaultLlamaModelPath()
          PlasticLlamaRuntime(
            config: config,
            executablePath: firstExistingFile(platformLlamaCandidates()),
            modelPath: modelPath,
            modelRepo: defaultLlamaModelRepo(),
            modelFile: defaultLlamaModelFile(),
            modelDir: defaultLlamaModelDir(modelPath),
            downloadScriptPath: defaultLlamaDownloadScript(),
            autoDownloadModel: defaultLlamaAutoDownload(),
            runtimeRoot: defaultLlamaRuntimeRoot(),
            releaseRepo: defaultLlamaReleaseRepo(),
            releaseVersion: defaultLlamaReleaseVersion(),
            releaseBackend: defaultLlamaReleaseBackend(),
            autoDownloadRuntime: defaultLlamaAutoDownloadRuntime(),
            autoUpdateRuntime: defaultLlamaAutoUpdateRuntime(),
            updateIntervalHours: defaultLlamaUpdateIntervalHours(),
            managedRuntime: false,
            endpoint: "http://" & config.host & ":" & $config.port & "/v1"
          )

        proc downloadLlamaModel(
          llama: PlasticLlamaRuntime;
          state: PlasticLlamaBootState = nil
        ) =
          if llama.modelPath.len > 0 and fileExists(llama.modelPath):
            return

          if not llama.autoDownloadModel:
            raise newException(
              PlasticInstallationError,
              "Modelo GGUF ausente e autoDownload desabilitado: " & llama.modelPath
            )

          if llama.modelRepo.len == 0 or llama.modelFile.len == 0:
            raise newException(
              PlasticInstallationError,
              "Configuração de modelo incompleta para download."
            )

          if llama.modelDir.len > 0 and not dirExists(llama.modelDir):
            createDir(llama.modelDir)
          llama.resetLlamaDownloadResidue()

          let modelPath = llama.modelPath
          let partialPath = modelPath & ".partial"
          let downloadUrl = llama.llamaModelDownloadUrl()
          let token = defaultHfToken()
          let headers =
            if token.len > 0:
              newHttpHeaders({
                "Authorization": "Bearer " & token,
                "Accept": "application/octet-stream"
              })
            else:
              newHttpHeaders({
                "Accept": "application/octet-stream"
              })
          var client = newHttpClient(timeout = -1, maxRedirects = 5, headers = headers)
          try:
            if fileExists(partialPath):
              try:
                removeFile(partialPath)
              except CatchableError:
                discard

            if not state.isNil:
              state.setLlamaBootState(
                "Baixando modelo",
                "Baixando " & llama.modelFile & " do Hugging Face",
                llama.modelFile,
                "Iniciando transferência via HttpClient...",
                5
              )
              client.onProgressChanged = proc(
                total, progress, speed: BiggestInt
              ): void {.closure, gcsafe.} =
                bootDownloadProgress(state, llama.modelFile, total, progress, speed)

            plasticDebugTrace("llama download: " & downloadUrl)
            client.downloadFile(downloadUrl, partialPath)

            if fileExists(modelPath):
              try:
                removeFile(modelPath)
              except CatchableError:
                discard
            moveFile(partialPath, modelPath)

            if not isValidGgufModelFile(modelPath):
              raise newException(
                PlasticRuntimeError,
                "Modelo baixado, mas a assinatura GGUF é inválida: " & modelPath
              )
          except CatchableError as error:
            if fileExists(partialPath):
              try:
                removeFile(partialPath)
              except CatchableError:
                discard
            raise newException(
              PlasticRuntimeError,
              "Falha ao baixar o modelo via HttpClient: " & error.msg
            )
          finally:
            client.close()

          if not fileExists(modelPath):
            raise newException(
              PlasticRuntimeError,
              "Download concluído sem gerar o modelo em: " & modelPath
            )

        proc ensureLlamaModel*(llama: PlasticLlamaRuntime; state: PlasticLlamaBootState = nil) =
          if llama.modelPath.len > 0 and fileExists(llama.modelPath):
            if isValidGgufModelFile(llama.modelPath):
              if not state.isNil:
                state.setLlamaBootState(
                  "Modelo em cache",
                  "Modelo local íntegro",
                  extractFilename(llama.modelPath),
                  "O modelo já existe e passou na validação GGUF; pulando o download.",
                  20
                )
                sleep(120)
              return

            if not state.isNil:
              state.setLlamaBootState(
                "Modelo corrompido",
                "Revalidando modelo local",
                extractFilename(llama.modelPath),
                "O arquivo GGUF existente parece inválido; ele será baixado novamente.",
                12
              )
              sleep(120)
            try:
              removeFile(llama.modelPath)
            except CatchableError:
              discard

          plasticDebugTrace("llama model cache miss path=" & llama.modelPath)
          llama.downloadLlamaModel(state)

        proc validateAssets*(llama: PlasticLlamaRuntime; state: PlasticLlamaBootState = nil) =
          llama.ensureLlamaRuntime(state)
          if llama.executablePath.len == 0 or not fileExists(llama.executablePath):
            raise newException(
              PlasticInstallationError,
              "O motor de instalação não conseguiu preparar o llama-server."
            )
          llama.ensureLlamaModel(state)

        proc running*(llama: PlasticLlamaRuntime): bool =
          not llama.process.isNil and llama.process.running

        proc health*(llama: PlasticLlamaRuntime): bool =
          var client = newHttpClient(timeout = 2_000)
          try:
            let response = client.get(llama.endpoint & "/models")
            result = response.status.startsWith("200")
          except CatchableError:
            result = false
          finally:
            client.close()

        proc start*(llama: PlasticLlamaRuntime; waitSeconds = 60) =
          if llama.health():
            return

          llama.validateAssets()
          let targets = plasticLlamaConnectionTargets(llama.config)
          let selectionDeadline =
            epochTime() + plasticLlamaPortSelectionTimeoutSeconds().float
          let probeSeconds = plasticLlamaPortProbeSeconds()
          var lastError = ""

          while epochTime() < selectionDeadline:
            for target in targets:
              if epochTime() >= selectionDeadline:
                break

              llama.config.host = target.host
              llama.config.port = target.port
              llama.endpoint = "http://" & target.host & ":" & $target.port & "/v1"
              lastError = ""

              let arguments = @[
                "--model", llama.modelPath,
                "--host", target.host,
                "--port", $target.port,
                "--alias", llama.config.modelAlias,
                "--ctx-size", $llama.config.contextSize,
                "--n-gpu-layers", $llama.config.gpuLayers
              ]

              try:
                llama.process = startProcess(
                  command = llama.executablePath,
                  workingDir = getAppDir(),
                  args = arguments,
                  options = {poStdErrToStdOut}
                )
              except CatchableError as error:
                lastError = error.msg
                continue

              lastError = "llama-server iniciou, aguardando healthcheck em " &
                llama.endpoint
              var probeEnd = epochTime() + probeSeconds.float
              while epochTime() < probeEnd:
                if not llama.process.running:
                  break
                if llama.health():
                  return
                sleep(250)

              if llama.process.running:
                var healthy = false
                for _ in 0 ..< waitSeconds * 2:
                  if llama.health():
                    healthy = true
                    break
                  if not llama.process.running:
                    break
                  sleep(500)

                if healthy:
                  return

              lastError = "llama-server não respondeu em " & llama.endpoint
              if not llama.process.isNil:
                if llama.process.running:
                  llama.process.terminate()
                llama.process.close()
                llama.process = nil

            if epochTime() < selectionDeadline:
              sleep(250)

          if lastError.len == 0:
            lastError = "llama-server não pôde ser iniciado em nenhum alvo configurado."

          raise newException(
            PlasticRuntimeError,
            lastError
          )

        proc newLlamaBootState*(message = ""): PlasticLlamaBootState =
          new(result)
          initLock(result.lock)
          result.message = message
          result.phase = message
          result.connection = ""
          result.model = ""
          result.detail = message
          result.progress = 0

        proc setLlamaBootProgress(
          state: PlasticLlamaBootState;
          phase: string;
          progress: int
        ) {.gcsafe.} =
          if state.isNil:
            return

          acquire(state.lock)
          state.phase = phase
          state.progress = clamp(progress, 0, 100)
          release(state.lock)
          plasticDebugTrace(
            "boot state progress set phase=" & phase &
            " progress=" & $state.progress
          )

        proc setLlamaBootState(
          state: PlasticLlamaBootState;
          phase, connection, model, detail: string;
          progress: int
        ) {.gcsafe.} =
          if state.isNil:
            return

          acquire(state.lock)
          state.phase = phase
          state.connection = connection
          state.model = model
          state.detail = detail
          state.message = detail
          state.progress = clamp(progress, 0, 100)
          release(state.lock)
          plasticDebugTrace(
            "boot state set phase=" & phase &
            " connection=" & connection &
            " model=" & model &
            " progress=" & $state.progress
          )

        proc runLlamaBootWorker(state: PlasticLlamaBootState) {.thread.} =
          if state.isNil:
            return

          try:
            plasticDebugTrace("boot worker: started")
            plasticDebugTrace("boot worker: stage=Preparando boot")
            state.setLlamaBootState(
              "Preparando boot",
              "Verificando llama-server",
              "Validando Gemma GGUF e Metis",
              "Checando llama.cpp, Python 3.10 e modelos locais...",
              8
            )
            sleep(150)
            plasticDebugTrace("boot worker: before validateAssets")
            state.llama.validateAssets(state)
            plasticDebugTrace("boot worker: after validateAssets")
            let targets = plasticLlamaConnectionTargets(state.llama.config)
            let selectionDeadline =
              epochTime() + plasticLlamaPortSelectionTimeoutSeconds().float
            let probeSeconds = plasticLlamaPortProbeSeconds()
            var lastError = ""
            var started = false

            plasticDebugTrace("boot worker: stage=Selecionando porta")
            state.setLlamaBootState(
              "Selecionando porta",
              "Procurando host/porta livre",
              extractFilename(state.llama.modelPath),
              "Checando candidatos de conexão do llama-server...",
              78
            )
            sleep(75)

            while epochTime() < selectionDeadline and not started:
              for target in targets:
                if epochTime() >= selectionDeadline or started:
                  break

                state.llama.config.host = target.host
                state.llama.config.port = target.port
                state.llama.endpoint =
                  "http://" & target.host & ":" & $target.port & "/v1"

                plasticDebugTrace(
                  "boot worker: stage=Subindo llama-server target=" &
                  target.host & ":" & $target.port
                )
                state.setLlamaBootState(
                  "Subindo llama-server",
                  "Conectando em " & target.host & ":" & $target.port,
                  extractFilename(state.llama.modelPath),
                  "Iniciando processo e testando disponibilidade...",
                  85
                )
                plasticDebugTrace(
                  "boot worker: trying " & target.host & ":" & $target.port
                )

                let effectiveGpuLayers =
                  if not state.metis.isNil and
                      state.metis.config.enabled and
                      state.metis.config.startup:
                    parseInt(
                      getEnv(
                        "GLAUCOPLASTIC_LLAMA_GPU_LAYERS_WITH_METIS",
                        "0"
                      )
                    )
                  else:
                    state.llama.config.gpuLayers

                let arguments = @[
                  "--model", state.llama.modelPath,
                  "--host", target.host,
                  "--port", $target.port,
                  "--alias", state.llama.config.modelAlias,
                  "--ctx-size", $state.llama.config.contextSize,
                  "--n-gpu-layers", $effectiveGpuLayers
                ]

                try:
                  state.llama.process = startProcess(
                    command = state.llama.executablePath,
                    workingDir = getAppDir(),
                    args = arguments,
                    options = {poStdErrToStdOut}
                  )
                except CatchableError as error:
                  lastError = error.msg
                  plasticDebugTrace(
                    "boot worker: startProcess failed at " &
                    target.host & ":" & $target.port & ": " & error.msg
                  )
                  continue

                plasticDebugTrace("boot worker: after startProcess")

                plasticDebugTrace(
                  "boot worker: stage=Aguardando healthcheck target=" &
                  target.host & ":" & $target.port
                )
                state.setLlamaBootState(
                  "Aguardando healthcheck",
                  "Processo ativo em " & target.host & ":" & $target.port,
                  extractFilename(state.llama.modelPath),
                  "Validando resposta HTTP do llama-server...",
                  92
                )

                let probeEnd = epochTime() + probeSeconds.float
                while epochTime() < probeEnd:
                  if not state.llama.process.running:
                    break
                  if state.llama.health():
                    plasticDebugTrace("boot worker: health ok")
                    acquire(state.lock)
                    state.progress = 93
                    state.phase = "llama-server pronto"
                    state.connection = target.host & ":" & $target.port
                    state.model = extractFilename(state.llama.modelPath)
                    state.detail = "llama-server pronto; preparando memória Metis."
                    release(state.lock)
                    started = true
                    break
                  sleep(250)

                if started:
                  break

                if state.llama.process.running:
                  state.setLlamaBootState(
                    "Aguardando healthcheck",
                    "Processo ativo em " & target.host & ":" & $target.port,
                    extractFilename(state.llama.modelPath),
                    "Llama-server subiu; aguardando endpoint /models responder...",
                    72
                  )
                  plasticDebugTrace("boot worker: waiting health")
                  for step in 0 ..< 80:
                    if state.llama.health():
                      plasticDebugTrace("boot worker: health ok")
                      acquire(state.lock)
                      state.progress = 93
                      state.phase = "llama-server pronto"
                      state.connection = target.host & ":" & $target.port
                      state.model = extractFilename(state.llama.modelPath)
                      state.detail = "llama-server pronto; preparando memória Metis."
                      state.message = state.detail
                      release(state.lock)
                      started = true
                      break

                    acquire(state.lock)
                    if state.progress < 95:
                      state.progress = min(95, 60 + (step * 35) div 80)
                    release(state.lock)
                    sleep(500)

                  if started:
                    break

                if not state.llama.process.isNil:
                  if state.llama.process.running:
                    state.llama.process.terminate()
                  state.llama.process.close()
                  state.llama.process = nil

                if lastError.len == 0:
                  lastError = "llama-server não respondeu em " & state.llama.endpoint

                plasticDebugTrace(
                  "boot worker: stage=Tentando próximo alvo lastError=" &
                  lastError
                )
                state.setLlamaBootState(
                  "Tentando próximo alvo",
                  "Último alvo: " & target.host & ":" & $target.port,
                  extractFilename(state.llama.modelPath),
                  lastError,
                  78
                )

              if epochTime() < selectionDeadline and not started:
                sleep(250)

            if not started:
              plasticDebugTrace("boot worker: health timeout")
              raise newException(
                PlasticRuntimeError,
                if lastError.len > 0:
                  lastError
                else:
                  "llama-server não respondeu em " & state.llama.endpoint
              )

            if not state.metis.isNil and state.metis.config.enabled and
                state.metis.config.startup:
              state.setLlamaBootState(
                "Preparando runtime Metis",
                "llama-server pronto; preparando Python 3.10 local",
                state.metis.config.modelId,
                "Validando o runtime e as dependências locais do Metis...",
                94
              )
              {.cast(gcsafe).}:
                state.metis.prepareRuntime()

              state.setLlamaBootState(
                "Preparando modelo Metis",
                "Runtime Python 3.10 validado",
                state.metis.config.modelId,
                "Validando o checkpoint incluído no produto...",
                96
              )
              {.cast(gcsafe).}:
                state.metis.prepareModel(state)

              state.setLlamaBootState(
                "Carregando memória Metis",
                "llama-server e Python prontos",
                state.metis.config.modelId,
                "Carregando o checkpoint, restaurando runtime.metis.pt e iniciando o worker...",
                98
              )
              {.cast(gcsafe).}:
                state.metis.ensureInitialized(state.llama)

              state.setLlamaBootState(
                "Finalizando startup",
                "llama-server e Metis ativos",
                extractFilename(state.llama.modelPath) & " + " &
                  state.metis.config.modelId,
                "Os dois runtimes foram iniciados e a memória persistente foi restaurada.",
                99
              )

            acquire(state.lock)
            state.failed = false
            state.done = true
            state.progress = 100
            state.phase = "Pronto"
            state.connection =
              if not state.metis.isNil and state.metis.config.enabled and
                  state.metis.config.startup:
                "llama-server e Metis prontos"
              else:
                "llama-server pronto"
            state.model =
              if not state.metis.isNil and state.metis.config.enabled and
                  state.metis.config.startup:
                extractFilename(state.llama.modelPath) & " + " &
                  state.metis.config.modelId
              else:
                extractFilename(state.llama.modelPath)
            state.detail =
              if not state.metis.isNil and state.metis.config.enabled and
                  state.metis.config.startup:
                "Backend e memória nativa persistente validados."
              else:
                "Backend validado."
            state.message = state.detail
            release(state.lock)
            plasticDebugTrace("boot worker: stage=Pronto")
            plasticDebugTrace("boot worker: done")
          except CatchableError as error:
            plasticDebugTrace("boot worker: failed: " & error.msg)
            acquire(state.lock)
            state.failed = true
            state.done = true
            state.message = error.msg
            state.phase = "Falha"
            release(state.lock)

        proc stop*(llama: PlasticLlamaRuntime) =
          if not llama.process.isNil:
            if llama.process.running:
              llama.process.terminate()
            llama.process.close()
            llama.process = nil

        proc chat*(
          llama: PlasticLlamaRuntime;
          messages: JsonNode;
          responseFormat = newJNull();
          maxTokensOverride = 0;
          enableThinkingOverride = -1
        ): JsonNode =
          let llmDebug =
            getEnv("GLAUCOPLASTIC_LLM_DEBUG").strip.toLowerAscii in
            ["1", "true", "yes", "on", "enabled"]

          if not llama.health():
            if llmDebug:
              plasticDebugTrace(
                "llm.health unavailable endpoint=" & llama.endpoint &
                "; attempting start"
              )
            llama.start()

          let requestMaxTokens =
            if maxTokensOverride > 0:
              maxTokensOverride
            else:
              llama.config.maxTokens
          let requestTimeoutMs =
            max(
              1_000,
              parseInt(
                getEnv(
                  "GLAUCOPLASTIC_LLM_TIMEOUT_MS",
                  "900000"
                )
              )
            )

          var payload = %*{
            "model": llama.config.modelAlias,
            "messages": messages,
            "temperature": llama.config.temperature,
            "max_tokens": requestMaxTokens,
            "stream": false
          }
          if responseFormat.kind != JNull:
            payload["response_format"] = responseFormat

          if enableThinkingOverride >= 0:
            payload["chat_template_kwargs"] = %*{
              "enable_thinking": enableThinkingOverride != 0
            }

          if llmDebug:
            var promptChars = 0
            if messages.kind == JArray:
              for message in messages.items:
                if message.kind == JObject and message.hasKey("content") and
                    message["content"].kind == JString:
                  promptChars += message["content"].getStr.len
            plasticDebugTrace(
              "llm.request endpoint=" & llama.endpoint &
              "/chat/completions promptChars=" & $promptChars &
              " maxTokens=" & $requestMaxTokens &
              " timeoutMs=" & $requestTimeoutMs
            )
            if getEnv("GLAUCOPLASTIC_LLM_DEBUG_PAYLOAD").strip.toLowerAscii in
                ["1", "true", "yes", "on", "enabled"]:
              plasticDebugTrace("llm.request.payload=" & $payload)

          var client = newHttpClient(timeout = requestTimeoutMs)
          client.headers = newHttpHeaders({"Content-Type": "application/json"})
          try:
            let response = client.request(
              llama.endpoint & "/chat/completions",
              httpMethod = HttpPost,
              body = $payload
            )
            if llmDebug:
              plasticDebugTrace(
                "llm.response status=" & response.status &
                " bodyChars=" & $response.body.len
              )
              let logResponseBody =
                llama.config.logResponseBody or
                getEnv("GLAUCOPLASTIC_LLM_DEBUG_RESPONSE").strip.toLowerAscii in
                  ["1", "true", "yes", "on", "enabled"]
              if logResponseBody:
                plasticDebugTrace("llm.response.body=" & response.body)
            if not response.status.startsWith("200"):
              raise newException(
                PlasticAgentError,
                "llama-server retornou " & response.status & ": " & response.body
              )
            result = parseJson(response.body)
          except CatchableError as error:
            plasticDebugTrace(
              "llm.error endpoint=" & llama.endpoint &
              " message=" & error.msg
            )
            raise
          finally:
            client.close()

        proc assistantContent(response: JsonNode): string =
          try:
            let choice = response["choices"][0]
            let message = choice["message"]

            if message.hasKey("content") and
                message["content"].kind == JString:
              result = message["content"].getStr
              if result.strip.len > 0:
                return

            # Alguns templates de raciocínio podem devolver o objeto final em
            # reasoning_content e deixar content vazio. Só aceitamos esse
            # campo quando ele contém um objeto JSON observável.
            if message.hasKey("reasoning_content") and
                message["reasoning_content"].kind == JString:
              let reasoning = message["reasoning_content"].getStr
              if reasoning.find('{') >= 0 and reasoning.rfind('}') >= 0:
                return reasoning

            let finishReason =
              if choice.hasKey("finish_reason") and
                  choice["finish_reason"].kind == JString:
                choice["finish_reason"].getStr
              else:
                "desconhecido"
            let reasoningChars =
              if message.hasKey("reasoning_content") and
                  message["reasoning_content"].kind == JString:
                message["reasoning_content"].getStr.len
              else:
                0

            raise newException(
              PlasticAgentError,
              "Resposta vazia do modelo; finish_reason=" &
              finishReason &
              ", reasoningChars=" & $reasoningChars
            )
          except PlasticAgentError:
            raise
          except CatchableError:
            raise newException(
              PlasticAgentError,
              "Resposta do modelo sem choices[0].message.content"
            )

        proc interpretOkfAccess(
          agent: PlasticAgent;
          operation: string;
          raw: JsonNode;
          context: JsonNode = newJNull()
        ): JsonNode =
          let systemPrompt = """
Você interpreta leituras de OKF para um agente.
Analise apenas os dados públicos disponibilizados e devolva JSON válido com:
{
  "summary": string,
  "entities": [string],
  "signals": [string],
  "suggestedNextActions": [string]
}
Mantenha a resposta objetiva e útil para inferência.
"""

          let userContent =
            %*{
              "operation": operation,
              "context": context,
              "raw": raw
            }

          try:
            let response = agent.application.llamaValue.chat(
              %*[
                %*{"role": "system", "content": systemPrompt},
                %*{"role": "user", "content": $userContent}
              ],
              %*{"type": "json_object"}
            )
            let content = assistantContent(response)
            let interpretation = parseJson(content)
            result = %*{
              "operation": operation,
              "raw": raw,
              "interpretation": interpretation
            }
            if context.kind != JNull:
              result["context"] = context.copy
          except CatchableError as error:
            result = %*{
              "operation": operation,
              "raw": raw,
              "interpretation": %*{
                "summary": "LLM indisponivel ou resposta invalida.",
                "error": error.msg
              }
            }
            if context.kind != JNull:
              result["context"] = context.copy

        proc newRlmRuntime*(): PlasticRlmRuntime =
          PlasticRlmRuntime(capabilities: initTable[string, PlasticCapability]())

        proc register*(runtime: PlasticRlmRuntime; name: string; capability: PlasticCapability) =
          runtime.capabilities[name] = capability

        proc invoke(runtime: PlasticRlmRuntime; agent: PlasticAgent; name: string; arguments: JsonNode): JsonNode =
          if not runtime.capabilities.hasKey(name):
            raise newException(PlasticAgentError, "Capability RLM inexistente: " & name)
          runtime.capabilities[name](agent, arguments)

        const PlasticRlmBasePrompt* = """
        Você é o assistente local do GlaucoPlastic.

        O objetivo principal é responder normalmente ao usuário. O JSON abaixo
        é apenas o protocolo interno entre você e o runtime:
        {
          "instructions": [
            {
              "capability": "capability.exata.registrada",
              "arguments": {},
              "assign": "variavel-opcional"
            }
          ],
          "answer": "resposta normal ao usuário ou null"
        }

        DECISÃO OBRIGATÓRIA ANTES DE RESPONDER:
        1. Primeiro avalie se a solicitação pode ser respondida usando a
           conversa, o system prompt, o domínio, as memórias, variables e
           observations já presentes.
        2. Se puder, não use Tool. Retorne instructions=[] e escreva a resposta
           normal em answer.
        3. Use uma capability somente quando for necessário observar um estado
           atual da aplicação, ler um recurso que ainda não está no contexto ou
           executar uma ação concreta solicitada pelo usuário.
        4. A simples existência de uma Tool nunca é motivo para chamá-la.
        5. Não use Tool para saudação, conversa comum, explicação, opinião,
           raciocínio, conhecimento geral, resumo do próprio contexto, redação
           de texto ou código que possa ser respondido diretamente.
        6. Para operações de arquivos, use Tool somente quando o usuário pedir
           concretamente criar, abrir, extrair, listar, modificar ou resumir um
           arquivo/workspace real.
        7. Quando precisar de Tool, use somente uma capability presente
           literalmente em CAPABILITIES DISPONÍVEIS. Copie o identificador
           exatamente; o campo name da Tool é apenas legível e não executável.
        8. Depois que uma Tool produzir uma observation, responda com base nela.
           Não repita a mesma chamada. Use outra Tool apenas se faltar uma
           observação diferente e indispensável.
        9. Não produza código Nim, markdown ou texto fora do objeto JSON.

        REGRA PADRÃO:
        Na dúvida entre responder e usar Tool, responda sem Tool.
        """

        proc extractRlmJsonPayload(content: string): string =
          ## Modelos com raciocínio explícito podem prefixar a resposta com
          ## `<think>...</think>` ou cercar o JSON com markdown. O protocolo
          ## interno continua estritamente JSON; esta função remove somente os
          ## envelopes textuais antes da validação com `parseJson`.
          var normalized = content.strip

          while true:
            let thinkStart = normalized.find("<think>")
            if thinkStart < 0:
              break

            let thinkEnd = normalized.find("</think>", thinkStart + "<think>".len)
            if thinkEnd < 0:
              normalized =
                if thinkStart > 0:
                  normalized[0 ..< thinkStart].strip
                else:
                  ""
              break

            let suffixStart = thinkEnd + "</think>".len
            let prefix =
              if thinkStart > 0:
                normalized[0 ..< thinkStart]
              else:
                ""
            let suffix =
              if suffixStart < normalized.len:
                normalized[suffixStart .. ^1]
              else:
                ""
            normalized = (prefix & suffix).strip

          if normalized.startsWith("```"):
            let firstLineEnd = normalized.find('\n')
            if firstLineEnd >= 0 and firstLineEnd + 1 < normalized.len:
              normalized = normalized[firstLineEnd + 1 .. ^1]
            let closingFence = normalized.rfind("```")
            if closingFence >= 0:
              normalized = normalized[0 ..< closingFence].strip

          let objectStart = normalized.find('{')
          let objectEnd = normalized.rfind('}')
          if objectStart >= 0 and objectEnd >= objectStart:
            return normalized[objectStart .. objectEnd]

          normalized

        proc agentPropertiesJson(agent: PlasticAgent): JsonNode =
          result = newJObject()
          for key, value in agent.properties:
            result[key] = value.copy

        proc extractPurpose(agentNode: JsonNode): string =
          for child in planChildren(agentNode):
            if planKind(child) == "call" and planName(child) == "purpose":
              let literal = firstLiteralString(child)
              if literal.len > 0:
                return literal
          ""

        proc compactAgentToolManifest(agent: PlasticAgent): JsonNode =
          result = newJArray()
          if agent.toolPlans.kind != JArray:
            return

          for functionPlan in agent.toolPlans.items:
            if functionPlan.kind != JObject:
              continue

            var manifest = newJObject()
            for key in ["name", "capability", "returnType", "systemPrompt"]:
              if functionPlan.hasKey(key):
                manifest[key] = functionPlan[key].copy

            manifest["parameters"] = newJArray()
            if functionPlan.hasKey("parameters") and
                functionPlan["parameters"].kind == JArray:
              for parameter in functionPlan["parameters"].items:
                var parameterManifest = newJObject()
                parameterManifest["name"] = %planName(parameter)
                parameterManifest["source"] = %planSource(parameter)
                manifest["parameters"].add parameterManifest

            result.add manifest

        proc buildAgentSystemPrompt(agent: PlasticAgent): string =
          var parts = newSeq[string]()
          parts.add PlasticRlmBasePrompt
          parts.add plasticOkfConsultationSkillText()
          parts.add plasticOkfGenerationSkillText()
          parts.add "CONSTRUTOR: " & agent.constructorName
          parts.add "INSTÂNCIA: " & agent.instanceName
          if agent.memoryName.len > 0:
            parts.add "MEMÓRIA: " & agent.memoryName
          if agent.okfPrincipalName.len > 0:
            parts.add "OKF PRINCIPAL: " & agent.okfPrincipalName
          if agent.metisSession.len > 0:
            parts.add "METIS SESSION: " & agent.metisSession
            parts.add "METIS CAPABILITIES: memory.query, memory.status, memory.save, memory.newSession, memory.rebuild, memory.reset"
          if agent.okfPath.len > 0:
            parts.add "OKF PATH: " & agent.okfPath
          parts.add "OKF ACCESS: leituras okf.* retornam interpretacao do LLM sobre o dado bruto."
          if agent.purpose.len > 0:
            parts.add "PURPOSE:\n" & agent.purpose
          if agent.domainPlan.kind == JArray and agent.domainPlan.len > 0:
            parts.add "DOMÍNIO:\n" & $agent.domainPlan
          elif agent.domainPlan.kind == JObject and agent.domainPlan.hasKey("children"):
            parts.add "DOMÍNIO:\n" & $agent.domainPlan
          if agent.rlmConditions.len > 0:
            parts.add "RLM CONDITIONS:\n" & agent.rlmConditions
          if agent.toolPlans.kind == JArray and agent.toolPlans.len > 0:
            parts.add "TOOLS DECLARADAS (manifesto compacto; invoque capability):\n" &
              $compactAgentToolManifest(agent)
          parts.add "PROPRIEDADES: " & $agent.agentPropertiesJson()
          if not agent.okfValue.isNil:
            parts.add "ESPAÇOS OKF: " & $agent.okfValue.spaces
          else:
            parts.add "ESPAÇOS OKF: " & $agent.application.okfValue.spaces
          parts.add "WEBCONTENTS: " & $agent.application.foreignValue.list()
          var registeredToolNames = newSeq[string]()
          if not agent.application.rlmValue.isNil:
            for toolName, _ in agent.application.rlmValue.capabilities:
              registeredToolNames.add toolName
          registeredToolNames.sort()

          var registeredTools = newJArray()
          for toolName in registeredToolNames:
            registeredTools.add %toolName

          parts.add(
            "CAPABILITIES DISPONÍVEIS — opcionais e lista fechada:\n" &
            $registeredTools
          )
          parts.add(
            "CONTRATO DE DECISÃO:\n" &
            "- Primeiro decida se alguma Tool é realmente necessária.\n" &
            "- Sem necessidade operacional: instructions=[] e answer normal.\n" &
            "- Ao usar Tool, instructions[].capability deve ser cópia exata " &
            "de um item da lista CAPABILITIES DISPONÍVEIS.\n" &
            "- O campo name de TOOLS DECLARADAS nunca é executável.\n" &
            "- Sem operação necessária: instructions=[] e answer preenchido.\n" &
            "- Capability inexistente ou inventada torna o programa inválido."
          )
          result = parts.join("\n\n")

        proc validateRlmProgramCapabilities(
          agent: PlasticAgent;
          program: JsonNode
        ): string =
          if program.kind != JObject:
            return "O programa RLM deve ser um objeto JSON."

          if not program.hasKey("instructions") or
              program["instructions"].kind != JArray:
            return "O campo instructions deve existir e ser um array."

          if not program.hasKey("answer"):
            return "O campo answer deve existir, mesmo quando for null."

          var allowedNames = newSeq[string]()
          if not agent.application.rlmValue.isNil:
            for registeredName, _ in
                agent.application.rlmValue.capabilities:
              allowedNames.add registeredName
          allowedNames.sort()

          var instructionIndex = 0
          for instruction in program["instructions"].items:
            let index = instructionIndex
            inc instructionIndex
            if instruction.kind != JObject:
              return(
                "instructions[" & $index &
                "] deve ser um objeto JSON."
              )

            if not instruction.hasKey("capability") or
                instruction["capability"].kind != JString:
              return(
                "instructions[" & $index &
                "].capability deve ser uma string."
              )

            let capabilityName =
              instruction["capability"].getStr.strip

            if capabilityName.len == 0:
              return(
                "instructions[" & $index &
                "].capability não pode ser vazia."
              )

            if agent.application.rlmValue.isNil or
                not agent.application.rlmValue.capabilities.hasKey(
                  capabilityName
                ):
              return(
                "Capability não registrada: " & capabilityName &
                ". Use exatamente uma destas: " &
                allowedNames.join(", ")
              )

            if instruction.hasKey("arguments") and
                instruction["arguments"].kind != JObject:
              return(
                "arguments de " & capabilityName &
                " deve ser um objeto JSON."
              )

            if instruction.hasKey("assign") and
                instruction["assign"].kind notin {JNull, JString}:
              return(
                "assign de " & capabilityName &
                " deve ser string ou null."
              )

          if program["instructions"].len == 0 and
              program["answer"].kind == JNull:
            return(
              "Sem capability a executar, answer deve conter a resposta. " &
              "Para saudações e conversa comum use instructions=[] e " &
              "answer preenchido."
            )

          ""

        proc parseAgentToolPlan(node: JsonNode): JsonNode =
          result = newJObject()
          result["source"] = %planSource(node)
          result["kind"] = %"Tool"

          let arguments = planArguments(node)
          var signatureNode: JsonNode = newJNull()
          var returnNode: JsonNode = newJNull()

          if arguments.len > 0:
            signatureNode = arguments[0].copy
            result["signature"] = signatureNode.copy
            result["name"] = %planName(arguments[0])
            if planKind(arguments[0]) == "call":
              result["parameters"] = newJArray()
              for parameter in planArguments(arguments[0]):
                result["parameters"].add parameter.copy
          else:
            result["name"] = %planName(node)

          if arguments.len > 1:
            returnNode = arguments[1].copy
            result["return"] = returnNode.copy
            result["returnType"] = %planTextValue(arguments[1])

          result["children"] = newJArray()

          for child in planChildren(node):
            if planKind(child) == "call" and planName(child) == "systemPrompt":
              result["systemPrompt"] = %firstLiteralString(child)
            elif planKind(child) == "call" and planName(child) == "capability":
              result["capability"] = %firstLiteralString(child)
            elif planKind(child) == "call" and planName(child) == "render":
              var renderNodes = newJArray()
              for renderNode in planChildren(child):
                renderNodes.add renderNode.copy
              result["render"] = renderNodes
            else:
              result["children"].add child.copy

        proc parseAgentWhenNode(node: JsonNode; fallbackEntity = ""): JsonNode =
          proc whenBranchCondition(branch: JsonNode): JsonNode =
            if branch.kind == JObject and branch.hasKey("condition"):
              return branch["condition"].copy
            newJNull()

          proc whenBranchChildren(branch: JsonNode): JsonNode =
            if branch.kind == JObject and branch.hasKey("children") and branch["children"].kind == JArray:
              return branch["children"].copy
            newJArray()

          proc whenHookName(condition: JsonNode): string =
            case planKind(condition)
            of "identifier", "call", "path":
              let name = planName(condition)
              if name.len > 0:
                return name
              planSource(condition)
            else:
              planSource(condition)

          proc whenEventName(condition: JsonNode): string =
            case planKind(condition)
            of "identifier":
              planName(condition)
            of "call":
              let arguments = planArguments(condition)
              if arguments.len > 0:
                let argumentName = planName(arguments[0])
                if argumentName.len > 0:
                  return argumentName
              planName(condition)
            of "path":
              planName(condition)
            else:
              planSource(condition)

          result = newJObject()
          result["kind"] = %"when"
          result["source"] = %planSource(node)
          result["children"] = newJArray()
          result["entity"] = %fallbackEntity
          result["event"] = %""
          result["whenKind"] = %""
          result["whenBody"] = %""
          result["intoKind"] = %""
          result["intoPath"] = %""
          result["intoName"] = %""

          let branches = planChildren(node)
          if branches.len == 0:
            return

          let branch = branches[0]
          if branch.kind != JObject:
            return

          let condition = whenBranchCondition(branch)
          let bodyChildren = whenBranchChildren(branch)
          result["children"] = bodyChildren.copy
          result["whenKind"] = %whenHookName(condition)
          result["event"] = %whenEventName(condition)
          result["whenBody"] = %firstChildLiteralText(branch)

          for child in bodyChildren.items:
            if planKind(child) == "call" and planName(child) == "into":
              let arguments = planArguments(child)
              if arguments.len > 0:
                result["intoKind"] = %planName(arguments[0])
                result["intoPath"] = %planSource(arguments[0])
              if arguments.len > 1:
                result["intoName"] = %planTextValue(arguments[1])
              else:
                result["intoName"] = %positionalIdentityName(child)

        proc parseAgentDomainEntry(node: JsonNode): JsonNode =
          result = newJObject()
          result["kind"] = %planName(node)
          result["name"] = %positionalIdentityName(node)
          result["path"] = %positionalIdentityPath(node)
          result["source"] = %planSource(node)
          result["description"] = %firstChildLiteralText(node)
          result["children"] = newJArray()

          for child in planChildren(node):
            if planKind(child) == "when":
              let eventNode = parseAgentWhenNode(child, planName(node))
              if eventNode.kind == JObject:
                result["children"].add eventNode
            elif planKind(child) == "call" and planName(child) == "into":
              let arguments = planArguments(child)
              if arguments.len > 0:
                result["intoKind"] = %planName(arguments[0])
                result["intoPath"] = %planSource(arguments[0])
              if arguments.len > 1:
                result["intoName"] = %planTextValue(arguments[1])
              else:
                result["intoName"] = %positionalIdentityName(child)
            else:
              result["children"].add child.copy

        proc parseAgentDomainPlan(agentNode: JsonNode): JsonNode =
          result = newJArray()
          var lastEntityName = ""
          for child in planChildren(agentNode):
            if planKind(child) in ["call", "command"] and planName(child) in ["state", "orm", "okf"]:
              let entry = parseAgentDomainEntry(child)
              result.add entry
              if entry.hasKey("name") and entry["name"].kind == JString:
                lastEntityName = entry["name"].getStr
            elif planKind(child) == "when":
              let hookNode = parseAgentWhenNode(child, lastEntityName)
              if hookNode.kind == JObject:
                result.add hookNode

        proc parseAgentRlmPlan(agentNode: JsonNode): tuple[conditions: string, tools: JsonNode] =
          result.conditions = ""
          result.tools = newJArray()
          for child in planChildren(agentNode):
            if planKind(child) == "call" and planName(child) == "conditions":
              result.conditions = firstLiteralString(child)
            elif planKind(child) == "call" and planName(child) in ["Tool", "Function"]:
              result.tools.add parseAgentToolPlan(child)

        proc deriveMemorySections(application: PlasticApplication) =
          let section = findPlanSection(application.planValue, "memory")
          if section.isNone:
            application.memoryValue = newJObject()
            return

          var memories = newJObject()
          for memoryNode in planChildren(section.get):
            let memoryName = planName(memoryNode)
            if memoryName.len == 0:
              continue

            var memoryPlan = newJObject()
            memoryPlan["name"] = %memoryName
            memoryPlan["purpose"] = %extractPurpose(memoryNode)
            memoryPlan["source"] = %planSource(memoryNode)
            memoryPlan["children"] =
              if memoryNode.hasKey("children") and memoryNode["children"].kind == JArray:
                memoryNode["children"].copy
              else:
                newJArray()
            memories[memoryName] = memoryPlan

          application.memoryValue = memories

        proc newAgent*(
          constructorName,
          instanceName,
          purpose: string;
          application: PlasticApplication;
          properties: Table[string, JsonNode]
        ): PlasticAgent =
          PlasticAgent(
            constructorName: constructorName,
            instanceName: instanceName,
            purpose: purpose,
            memoryName: "",
            okfPrincipalName: "",
            okfPath: "",
            okfValue: nil,
            metisSession: "",
            domainPlan: newJArray(),
            rlmConditions: "",
            toolPlans: newJArray(),
            application: application,
            properties: properties,
            sessionVariables: initTable[string, JsonNode](),
            hookDispatching: false,
            asyncExecution: false,
            asyncStateSnapshot: newJObject(),
            asyncStateWrites: @[],
            stateWriteCount: 0,
            workerState: nil,
            maxIterations: 8,
            maxRecursionDepth: 1
          )

        proc newAgent*(
          constructorName,
          instanceName,
          purpose: string;
          application: PlasticApplication
        ): PlasticAgent =
          newAgent(
            constructorName,
            instanceName,
            purpose,
            application,
            initTable[string, JsonNode]()
          )

        proc ensureAgentOrmEntity(orm: PlasticOrmRuntime; entity: string): JsonNode =
          if orm.data.kind != JObject:
            orm.data = newJObject()
          if not orm.data.hasKey(entity) or orm.data[entity].kind != JArray:
            orm.data[entity] = newJArray()
          orm.data[entity]

        proc persistAgentOrm(orm: PlasticOrmRuntime) =
          if orm.path.len == 0:
            return
          writeJsonFile(orm.path, orm.data)

        proc findAgentOrmById(orm: PlasticOrmRuntime; entity: string; id: int): JsonNode =
          for row in ensureAgentOrmEntity(orm, entity).items:
            if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
              return row.copy
          newJNull()

        proc insertAgentOrmRow(orm: PlasticOrmRuntime; entity: string; value: JsonNode): JsonNode =
          if value.kind != JObject:
            raise newException(PlasticRuntimeError, "ORM insert espera objeto JSON")

          let rows = ensureAgentOrmEntity(orm, entity)
          result = value.copy
          if not result.hasKey("id") or result["id"].kind == JNull:
            var nextIdValue = 1
            for row in rows.items:
              if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt:
                nextIdValue = max(nextIdValue, row["id"].getInt + 1)
            result["id"] = %nextIdValue
          rows.add result.copy
          persistAgentOrm(orm)

        proc plasticAgentStateSet(
          agent: PlasticAgent;
          path: openArray[string];
          value: JsonNode
        )

        proc plasticAgentNormalizeStatePath(
          name: string
        ): seq[string] =
          var normalized = name.strip

          if normalized.toLowerAscii.startsWith("states."):
            normalized = normalized[7 .. ^1]
          elif normalized.toLowerAscii.startsWith("state."):
            normalized = normalized[6 .. ^1]

          result =
            normalized
              .split('.')
              .filterIt(it.strip.len > 0)
              .mapIt(it.strip)

        proc plasticAgentApplyStateValue(
          agent: PlasticAgent;
          basePath: seq[string];
          value: JsonNode
        ): int =
          if agent.isNil or basePath.len == 0:
            return 0

          if value.kind == JObject:
            for key, fieldValue in value.pairs:
              var fieldPath = basePath
              fieldPath.add plasticAgentNormalizeStatePath(key)

              if fieldPath.len > basePath.len:
                plasticAgentStateSet(
                  agent,
                  fieldPath,
                  fieldValue
                )
                inc result
          else:
            plasticAgentStateSet(agent, basePath, value)
            result = 1

        proc plasticAgentApplyStateSetArguments(
          agent: PlasticAgent;
          arguments: JsonNode
        ): int =
          if agent.isNil or arguments.kind != JObject:
            return 0

          var baseName = ""
          for key in ["name", "path", "state"]:
            if arguments.hasKey(key) and
                arguments[key].kind == JString:
              baseName = arguments[key].getStr
              if baseName.len > 0:
                break

          var explicitValue = newJNull()
          var hasExplicitValue = false
          for key in ["value", "values"]:
            if arguments.hasKey(key):
              explicitValue = arguments[key]
              hasExplicitValue = true
              break

          if baseName.len > 0 and hasExplicitValue:
            result += plasticAgentApplyStateValue(
              agent,
              plasticAgentNormalizeStatePath(baseName),
              explicitValue
            )

          # Aceita formas de mapa produzidas naturalmente pelos modelos:
          #
          # {"states.Search": {"selectedTitle": "..."}}
          # {"Search.selectedTitle": "...", "Search.selectedHref": "..."}
          # {"Search": {"selectedTitle": "..."}}
          #
          # Dentro da capability state.set, cada chave não reservada é tratada
          # como caminho de estado. Isso evita depender de uma única convenção
          # de serialização do modelo.
          for key, value in arguments.pairs:
            if key in [
              "name",
              "path",
              "state",
              "value",
              "values",
              "assign"
            ]:
              continue

            let normalizedPath =
              plasticAgentNormalizeStatePath(key)

            if normalizedPath.len > 0:
              result += plasticAgentApplyStateValue(
                agent,
                normalizedPath,
                value
              )

        proc plasticAgentSnapshotGet(
          snapshot: JsonNode;
          path: openArray[string]
        ): JsonNode =
          if path.len == 0 or snapshot.kind != JObject:
            return newJNull()

          var current = snapshot
          for part in path:
            if current.kind != JObject:
              return newJNull()
            let key = glaucoplasticJsonObjectResolveKey(current, part)
            if key.len == 0:
              return newJNull()
            current = current[key]

          current.copy

        proc plasticAgentStateGet(
          agent: PlasticAgent;
          name: string
        ): JsonNode =
          if agent.isNil:
            return newJNull()

          let path = plasticAgentNormalizeStatePath(name)
          if agent.asyncExecution:
            return plasticAgentSnapshotGet(
              agent.asyncStateSnapshot,
              path
            )

          glaucoplasticStateGetPathInternal(
            agent.application.statesValue,
            path
          )

        proc plasticAgentStateSet(
          agent: PlasticAgent;
          path: openArray[string];
          value: JsonNode
        ) =
          if agent.isNil or path.len == 0:
            return

          inc agent.stateWriteCount

          if agent.asyncExecution:
            agent.asyncStateWrites.add(
              PlasticAgentAsyncStateWrite(
                path: @path,
                value: value.copy
              )
            )
            return

          glaucoplasticStateSetPathInternal(
            agent.application.statesValue,
            path,
            value
          )

        proc plasticAgentStateSet(
          agent: PlasticAgent;
          name: string;
          value: JsonNode
        ) =
          plasticAgentStateSet(
            agent,
            plasticAgentNormalizeStatePath(name),
            value
          )

        proc plasticAgentMergeAnswer(
          agent: PlasticAgent;
          intoPath: string;
          answer: JsonNode
        ) =
          let path = intoPath.split('.').filterIt(it.len > 0)
          if path.len == 0 or answer.kind == JNull:
            return

          if answer.kind == JObject:
            for key, value in answer.pairs:
              var fieldPath = path
              fieldPath.add key
              plasticAgentStateSet(agent, fieldPath, value)
          else:
            plasticAgentStateSet(agent, path, answer)

        proc installDefaultCapabilities(application: PlasticApplication) =
          application.rlmValue.register("state.get", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticAgentStateGet(
              agent,
              `jsonStringFieldSym`(arguments, "name")
            )
          )

          application.rlmValue.register("state.set", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let writes =
              plasticAgentApplyStateSetArguments(agent, arguments)

            if writes <= 0:
              var argumentKeys: seq[string] = @[]
              if arguments.kind == JObject:
                for key, _ in arguments.pairs:
                  argumentKeys.add key

              raise newException(
                PlasticAgentError,
                "state.set recebeu argumentos sem caminho/valor aplicável. " &
                "Chaves recebidas: " & argumentKeys.join(", ")
              )

            %*{
              "ok": true,
              "writes": writes
            }
          )

          application.rlmValue.register("orm.find", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            findAgentOrmById(
              agent.application.ormValue,
              `jsonStringFieldSym`(arguments, "entity"),
              `jsonIntFieldSym`(arguments, "id")
            )
          )

          application.rlmValue.register("orm.insert", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            insertAgentOrmRow(
              agent.application.ormValue,
              `jsonStringFieldSym`(arguments, "entity"),
              arguments{"value"}
            )
          )

          application.rlmValue.register("okf.list", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let space = `jsonStringFieldSym`(arguments, "space")
            interpretOkfAccess(
              agent,
              "okf.list",
              activeOkfRuntime(agent).list(space),
              %*{"space": space}
            )
          )

          application.rlmValue.register("okf.search", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let query = `jsonStringFieldSym`(arguments, "query")
            let space = `jsonStringFieldSym`(arguments, "space")
            interpretOkfAccess(
              agent,
              "okf.search",
              activeOkfRuntime(agent).search(query, space),
              %*{"query": query, "space": space}
            )
          )

          application.rlmValue.register("okf.get", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let id = `jsonStringFieldSym`(arguments, "id")
            interpretOkfAccess(
              agent,
              "okf.get",
              activeOkfRuntime(agent).get(id),
              %*{"id": id}
            )
          )

          application.rlmValue.register("okf.persist", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            activeOkfRuntime(agent).persist(arguments{"document"})
          )

          application.rlmValue.register("memory.query", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            %agent.application.metisMemoryValue.query(
              agent.application.llamaValue,
              agent.metisSession,
              `jsonStringFieldSym`(arguments, "query")
            )
          )

          application.rlmValue.register("memory.status", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            result = agent.application.metisMemoryValue.statusJson()
            result["session"] = %agent.metisSession
          )

          application.rlmValue.register("memory.save", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.metisMemoryValue.flush()
            %*{"saved": true, "session": agent.metisSession}
          )

          application.rlmValue.register("memory.newSession", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let session = `jsonStringFieldSym`(arguments, "session", agent.metisSession)
            agent.application.metisMemoryValue.clearSession(session)
            %*{"cleared": true, "session": session}
          )

          application.rlmValue.register("memory.rebuild", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            let count = agent.application.metisMemoryValue.rebuild(
              agent.application.llamaValue
            )
            %*{"rebuilt": count}
          )

          application.rlmValue.register("memory.reset", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.metisMemoryValue.reset(
              agent.application.llamaValue
            )
            %*{"reset": true}
          )

          application.rlmValue.register("okf.tree", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            interpretOkfAccess(
              agent,
              "okf.tree",
              activeOkfRuntime(agent).tree(),
              newJObject()
            )
          )

          application.rlmValue.register("webcontents.list", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.foreignValue.list()
          )

          application.rlmValue.register("webcontents.describe", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.foreignValue.describe(`jsonStringFieldSym`(arguments, "path"))
          )

          application.rlmValue.register("webcontents.eval_js", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.foreignValue.evalJs(
              `jsonStringFieldSym`(arguments, "path"),
              `jsonStringFieldSym`(arguments, "script"),
              `jsonIntFieldSym`(arguments, "timeoutMs", 15_000)
            )
          )

          application.rlmValue.register("webcontents.navigate", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            agent.application.foreignValue.navigate(
              `jsonStringFieldSym`(arguments, "path"),
              `jsonStringFieldSym`(arguments, "url")
            )
            %*{"ok": true}
          )

          application.rlmValue.register("office.document.create", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.document.create", arguments)
          )
          application.rlmValue.register("office.spreadsheet.create", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.spreadsheet.create", arguments)
          )
          application.rlmValue.register("office.presentation.create", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.presentation.create", arguments)
          )
          application.rlmValue.register("office.pdf.create", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.pdf.create", arguments)
          )
          application.rlmValue.register("office.text.extract", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.text.extract", arguments)
          )
          application.rlmValue.register("office.files.list", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.files.list", arguments)
          )
          application.rlmValue.register("office.workspace.summary", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
            plasticOfficeInvoke("office.workspace.summary", arguments)
          )

        proc normalizeAgentHookName(name: string): string =
          case name.strip.toLowerAscii
          of "changed", "change", "changes":
            "changes"
          of "initialize", "initializes", "initialised", "initialized":
            "initializes"
          else:
            name.strip.toLowerAscii

        proc extractStatePathReference(text: string): string =
          for prefix in ["states.", "state."]:
            let start = text.find(prefix)
            if start < 0:
              continue
            var index = start + prefix.len
            while index < text.len and text[index] in {' ', '\t', '\n', '\r'}:
              inc index
            let beginIndex = index
            while index < text.len:
              let ch = text[index]
              if ch.isAlphaNumeric or ch in {'.', '_'}:
                inc index
              else:
                break
            if index > beginIndex:
              return text[start + prefix.len ..< index].strip
          ""

        proc run*(agent: PlasticAgent; input: JsonNode): JsonNode

        proc runAgentHook(
          agent: PlasticAgent;
          hookName, entityName: string;
          change: PlasticStateChange;
          hookNode, domainNode: JsonNode
        )

        proc runPlasticAgentInferenceWorker(
          state: PlasticAgentWorkerState
        ) {.thread.} =
          if state.isNil:
            return

          state.running = true
          while true:
            var hasJob = false
            var job: PlasticAgentAsyncJob

            acquire(state.lock)
            if state.jobs.len > 0:
              job = state.jobs[0]
              state.jobs.delete(0)
              state.active = true
              hasJob = true
            elif state.stopping:
              state.running = false
              release(state.lock)
              break
            release(state.lock)

            if not hasJob:
              sleep(20)
              continue

            var completion = PlasticAgentAsyncResult(
              writes: @[],
              error: ""
            )

            try:
              let agent = state.agent
              agent.asyncExecution = true
              agent.asyncStateSnapshot = job.stateSnapshot.copy
              agent.asyncStateWrites = @[]
              agent.stateWriteCount = 0

              {.cast(gcsafe).}:
                runAgentHook(
                  agent,
                  job.hookName,
                  job.entityName,
                  job.change,
                  job.hookNode,
                  job.domainNode
                )

              completion.writes = agent.asyncStateWrites
            except CatchableError as error:
              completion.error = error.msg
            finally:
              if not state.agent.isNil:
                state.agent.asyncExecution = false
                state.agent.asyncStateSnapshot = newJObject()
                state.agent.asyncStateWrites = @[]

            acquire(state.lock)
            state.results.add completion
            state.active = false
            release(state.lock)

        proc startPlasticAgentWorker(agent: PlasticAgent) =
          if agent.isNil or not agent.workerState.isNil:
            return

          agent.workerState = PlasticAgentWorkerState(
            agent: agent,
            jobs: @[],
            results: @[],
            running: false,
            stopping: false,
            active: false
          )
          initLock(agent.workerState.lock)
          createThread(
            agent.workerThread,
            runPlasticAgentInferenceWorker,
            agent.workerState
          )

        proc enqueuePlasticAgentHook(
          agent: PlasticAgent;
          hookName, entityName: string;
          change: PlasticStateChange;
          hookNode, domainNode: JsonNode
        ) =
          if agent.isNil:
            return

          startPlasticAgentWorker(agent)

          let job = PlasticAgentAsyncJob(
            hookName: hookName,
            entityName: entityName,
            change: change,
            hookNode: hookNode.copy,
            domainNode: domainNode.copy,
            stateSnapshot: agent.application.statesValue.snapshot()
          )

          acquire(agent.workerState.lock)

          # Para hooks reativos, o estado mais recente é mais útil que uma
          # fila antiga. Preservamos o trabalho ativo e substituímos pendências
          # da mesma entidade.
          var retained: seq[PlasticAgentAsyncJob] = @[]
          for pending in agent.workerState.jobs:
            if pending.entityName != entityName or
                pending.hookName != hookName:
              retained.add pending
          agent.workerState.jobs = retained

          let maxPending =
            max(
              1,
              parseInt(
                getEnv(
                  "GLAUCOPLASTIC_AGENT_MAX_PENDING",
                  "4"
                )
              )
            )
          while agent.workerState.jobs.len >= maxPending:
            agent.workerState.jobs.delete(0)

          agent.workerState.jobs.add job
          release(agent.workerState.lock)

          plasticDebugTrace(
            "agent.hook.queued agent=" & agent.instanceName &
            " hook=" & hookName &
            " entity=" & entityName
          )

        proc drainPlasticAgentInferenceResults(
          application: PlasticApplication
        ) =
          if application.isNil:
            return

          for _, agent in application.agentsValue.pairs:
            if agent.isNil or agent.workerState.isNil:
              continue

            while true:
              var hasCompletion = false
              var completion: PlasticAgentAsyncResult

              acquire(agent.workerState.lock)
              if agent.workerState.results.len > 0:
                completion = agent.workerState.results[0]
                agent.workerState.results.delete(0)
                hasCompletion = true
              release(agent.workerState.lock)

              if not hasCompletion:
                break

              if completion.error.len > 0:
                plasticDebugTrace(
                  "agent.hook.async.error agent=" &
                  agent.instanceName &
                  " message=" & completion.error
                )

              for write in completion.writes:
                glaucoplasticStateSetPathInternal(
                  application.statesValue,
                  write.path,
                  write.value
                )

        when defined(linux):
          proc pollPlasticAgentInferenceResults(
            data: pointer
          ): cint {.cdecl.} =
            let application = cast[PlasticApplication](data)
            if application.isNil:
              return 0

            try:
              drainPlasticAgentInferenceResults(application)
            except CatchableError as error:
              plasticDebugTrace(
                "agent.poll.error message=" & error.msg
              )

            return 1

          proc ensurePlasticAgentInferencePoll(
            application: PlasticApplication
          ) =
            if application.isNil or application.agentPollStartedValue:
              return

            application.agentPollStartedValue = true
            discard plasticAgentTimeoutAdd(
              25,
              pollPlasticAgentInferenceResults,
              cast[pointer](application)
            )

        proc runAgentHook(
          agent: PlasticAgent;
          hookName, entityName: string;
          change: PlasticStateChange;
          hookNode, domainNode: JsonNode
        ) =
          if agent.isNil or agent.hookDispatching:
            return

          agent.hookDispatching = true
          agent.stateWriteCount = 0
          try:
            if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.len > 0:
              plasticDebugTrace(
                "agent.hook agent=" & agent.instanceName &
                " hook=" & hookName &
                " entity=" & entityName &
                " into=" & `jsonStringFieldSym`(domainNode, "intoPath")
              )
            let payload = %*{
              "hook": hookName,
              "entity": entityName,
              "prompt": `jsonStringFieldSym`(hookNode, "whenBody", `jsonStringFieldSym`(hookNode, "source")),
              "event": `jsonStringFieldSym`(hookNode, "event"),
              "change": %*{
                "name": change.name,
                "path": change.path,
                "previousValue": change.previousValue,
                "currentValue": change.currentValue,
                "changedAt": change.changedAt.format("yyyy-MM-dd'T'HH:mm:sszzz")
              },
              "into": %*{
                "kind": `jsonStringFieldSym`(domainNode, "intoKind"),
                "path": `jsonStringFieldSym`(domainNode, "intoPath"),
                "name": `jsonStringFieldSym`(domainNode, "intoName")
              }
            }

            if agent.application.llamaValue.config.logResponseBody or
                getEnv("GLAUCOPLASTIC_LLM_DEBUG_RESPONSE").strip.toLowerAscii in
                  ["1", "true", "yes", "on", "enabled"]:
              plasticDebugTrace(
                "agent.hook.input agent=" & agent.instanceName &
                " payload=" & $payload
              )

            let answer = agent.run(payload)

            if agent.application.llamaValue.config.logResponseBody or
                getEnv("GLAUCOPLASTIC_LLM_DEBUG_RESPONSE").strip.toLowerAscii in
                  ["1", "true", "yes", "on", "enabled"]:
              plasticDebugTrace(
                "agent.hook.answer agent=" & agent.instanceName &
                " answer=" & $answer
              )

            var intoPath = `jsonStringFieldSym`(domainNode, "intoPath")
            if intoPath.len > 0 and intoPath.toLowerAscii.startsWith("states."):
              intoPath = intoPath[7 .. ^1]
            elif intoPath.len > 0 and intoPath.toLowerAscii.startsWith("state."):
              intoPath = intoPath[6 .. ^1]
            if intoPath.len > 0 and
                answer.kind != JNull and
                agent.stateWriteCount == 0:
              plasticAgentMergeAnswer(
                agent,
                intoPath,
                answer
              )
          except CatchableError as error:
            plasticDebugTrace(
              "agent.hook.error agent=" & agent.instanceName &
              " hook=" & hookName &
              " entity=" & entityName &
              " message=" & error.msg
            )

            try:
              let stateSnapshot =
                if agent.asyncExecution:
                  agent.asyncStateSnapshot
                else:
                  agent.application.statesValue.snapshot()
              if entityName.len > 0 and
                  stateSnapshot.kind == JObject and
                  stateSnapshot.hasKey(entityName) and
                  stateSnapshot[entityName].kind == JObject and
                  stateSnapshot[entityName].hasKey("status"):
                plasticAgentStateSet(
                  agent,
                  @[entityName, "status"],
                  %(
                    "Falha na inferência: " &
                    error.msg
                  )
                )
            except CatchableError:
              discard
          finally:
            agent.hookDispatching = false

        proc registerAgentDomainHooks(application: PlasticApplication; agent: PlasticAgent) =
          if agent.isNil or agent.domainPlan.kind != JArray:
            return

          proc registerAgentHookNode(entityName: string; hookNode: JsonNode) =
            if hookNode.kind != JObject:
              return

            var effectiveEntity = entityName
            if effectiveEntity.len == 0:
              effectiveEntity = `jsonStringFieldSym`(hookNode, "entity")
            if effectiveEntity.toLowerAscii.startsWith("states."):
              effectiveEntity = effectiveEntity[7 .. ^1]
            elif effectiveEntity.toLowerAscii.startsWith("state."):
              effectiveEntity = effectiveEntity[6 .. ^1]
            if effectiveEntity.len == 0:
              return

            let hookName =
              normalizeAgentHookName(
                `jsonStringFieldSym`(
                  hookNode,
                  "whenKind",
                  `jsonStringFieldSym`(hookNode, "event")
                )
              )

            case hookName
            of "initializes":
              if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.len > 0:
                plasticDebugTrace(
                  "agent.register agent=" & agent.instanceName &
                  " entity=" & effectiveEntity &
                  " hook=" & hookName
                )
              discard
            of "changes":
              if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.len > 0:
                plasticDebugTrace(
                  "agent.register agent=" & agent.instanceName &
                  " entity=" & effectiveEntity &
                  " hook=" & hookName
                )
              var triggerEntity = effectiveEntity
              let intoPath = `jsonStringFieldSym`(hookNode, "intoPath")
              if intoPath.len > 0:
                triggerEntity = intoPath
                if triggerEntity.toLowerAscii.startsWith("states."):
                  triggerEntity = triggerEntity[7 .. ^1]
                elif triggerEntity.toLowerAscii.startsWith("state."):
                  triggerEntity = triggerEntity[6 .. ^1]
              if triggerEntity.len == 0:
                triggerEntity = effectiveEntity

              let expectedTriggerPath =
                extractStatePathReference(
                  `jsonStringFieldSym`(hookNode, "whenBody", `jsonStringFieldSym`(hookNode, "source"))
                )

              let domainCopy = hookNode.copy
              application.statesValue.onChanged(
                triggerEntity,
                proc(change: PlasticStateChange) =
                  if expectedTriggerPath.len > 0 and change.path.len > 0 and
                      change.path != expectedTriggerPath and
                      change.path != triggerEntity:
                    return
                  when defined(linux):
                    enqueuePlasticAgentHook(
                      agent,
                      hookName,
                      triggerEntity,
                      change,
                      domainCopy,
                      domainCopy
                    )
                  else:
                    # Backends ainda sem integração de poll mantêm o caminho
                    # síncrono até receberem um dispatcher próprio.
                    runAgentHook(
                      agent,
                      hookName,
                      triggerEntity,
                      change,
                      domainCopy,
                      domainCopy
                    )
              )
            else:
              discard

          for domainNode in agent.domainPlan.items:
            if domainNode.kind != JObject:
              continue

            if `jsonStringFieldSym`(domainNode, "kind") == "when":
              registerAgentHookNode("", domainNode)
              continue

            var entityName = `jsonStringFieldSym`(domainNode, "name")
            if entityName.toLowerAscii.startsWith("states."):
              entityName = entityName[7 .. ^1]
            elif entityName.toLowerAscii.startsWith("state."):
              entityName = entityName[6 .. ^1]
            if entityName.len == 0:
              continue

            if not domainNode.hasKey("children") or domainNode["children"].kind != JArray:
              continue

            for hookNode in domainNode["children"].items:
              if hookNode.kind != JObject or `jsonStringFieldSym`(hookNode, "kind") != "when":
                continue
              registerAgentHookNode(entityName, hookNode)

        proc deriveAgents(application: PlasticApplication) =
          deriveMemorySections(application)

          let section = findPlanSection(application.planValue, "agents")
          if section.isNone:
            return

          for agentNode in planChildren(section.get):
            let arguments = planArguments(agentNode)
            var instanceName = planName(agentNode)
            var properties = initTable[string, JsonNode]()
            var memoryName = ""
            var okfPrincipalName = ""
            var okfPath = ""
            var metisSession = ""
            var purpose = extractPurpose(agentNode)
            var domainPlan = newJArray()
            var rlmConditions = ""
            var toolPlans = newJArray()

            if arguments.len > 0:
              let first = literalOrNull(arguments[0])
              if first.kind == JString:
                instanceName = first.getStr

            for argument in arguments:
              if planKind(argument) == "namedArgument":
                let argumentName = planName(argument)
                properties[argumentName] = planValueOrName(argument{"value"})
                case argumentName
                of "okfPrincipal":
                  okfPrincipalName = planName(argument{"value"})
                of "okfPath":
                  okfPath = planTextValue(argument{"value"})
                of "session", "metisSession":
                  metisSession = planTextValue(argument{"value"})
                of "metisMemory":
                  # Compatibilidade: o valor antigo passa a nomear a sessão.
                  metisSession = planTextValue(argument{"value"})
                of "memory":
                  memoryName = planName(argument{"value"})
                else:
                  discard

            for child in planChildren(agentNode):
              case planKind(child)
              of "call":
                case planName(child)
                of "purpose":
                  let value = firstLiteralString(child)
                  if value.len > 0:
                    purpose = value
                of "dominio":
                  domainPlan = parseAgentDomainPlan(child)
                of "rlm":
                  let parsed = parseAgentRlmPlan(child)
                  rlmConditions = parsed.conditions
                  toolPlans = parsed.tools
                else:
                  discard
              of "when":
                if domainPlan.kind != JArray:
                  domainPlan = newJArray()
                var fallbackDomain = newJObject()
                fallbackDomain["kind"] = %"when"
                fallbackDomain["source"] = %planSource(child)
                fallbackDomain["children"] =
                  if child.hasKey("children") and child["children"].kind == JArray:
                    child["children"].copy
                  else:
                    newJArray()
                domainPlan.add fallbackDomain
              else:
                discard

            if memoryName.len == 0:
              memoryName = planName(agentNode)

            let agent = newAgent(
              planName(agentNode),
              instanceName,
              purpose,
              application,
              properties
            )
            agent.memoryName = memoryName
            agent.okfPrincipalName = okfPrincipalName
            agent.okfPath =
              if okfPath.len > 0:
                okfPath
              else:
                application.okfValue.rootPath / instanceName
            agent.okfValue = newPlasticOkfRuntime(agent.okfPath)
            agent.okfValue.spaces =
              if application.okfValue.spaces.kind == JObject:
                application.okfValue.spaces.copy
              else:
                newJObject()
            if not dirExists(agent.okfPath):
              createDir(agent.okfPath)
            if agent.okfValue.spaces.kind == JObject:
              for spaceName, _ in agent.okfValue.spaces.pairs:
                if spaceName.len > 0:
                  createDir(agent.okfPath / spaceName)
            agent.okfValue.validate()
            agent.okfValue.saveSpaces()
            agent.metisSession =
              if metisSession.len > 0:
                metisSession
              else:
                instanceName
            agent.domainPlan = domainPlan
            agent.rlmConditions = rlmConditions
            agent.toolPlans = toolPlans
            application.agentsValue[instanceName] = agent
            if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.len > 0:
              plasticDebugTrace(
                "agent.derive instance=" & instanceName &
                " domain=" & $agent.domainPlan
              )
            # O poll pode existir desde o registro, porém o worker do
            # agente só nasce quando o primeiro hook é enfileirado. Criar uma
            # thread ORC ociosa durante o carregamento do CPython/CUDA causava
            # concorrência desnecessária no startup.
            when defined(linux):
              ensurePlasticAgentInferencePoll(application)
            registerAgentDomainHooks(application, agent)

        proc run*(agent: PlasticAgent; input: JsonNode): JsonNode =
          let application = agent.application
          let memoryQueryText =
            if input.kind == JObject:
              var compact = newJObject()
              for key in ["hook", "entity", "prompt", "event", "message", "query"]:
                if input.hasKey(key):
                  compact[key] = input[key].copy
              if input.hasKey("change") and input["change"].kind == JObject:
                var change = newJObject()
                for key in ["name", "path", "currentValue", "changedAt"]:
                  if input["change"].hasKey(key):
                    let value = input["change"][key]
                    if key != "currentValue" or value.kind in {JNull, JBool, JInt, JFloat, JString}:
                      change[key] = value.copy
                compact["change"] = change
              $compact
            else:
              $input
          let memoryContext =
            if application.metisMemoryValue.config.memoryMode == "immediate":
              application.metisMemoryValue.query(
                application.llamaValue,
                agent.metisSession,
                memoryQueryText
              )
            else:
              "SEM_MEMORIA_RELEVANTE"

          let recentSessionMessages =
            application.metisMemoryValue.loadSessionMessages(agent.metisSession)

          var promptInput = input.copy
          var promptStates = application.statesValue.snapshot()

          if input.kind == JObject:
            promptInput = newJObject()
            for key in [
              "hook",
              "entity",
              "prompt",
              "event",
              "message",
              "query",
              "into"
            ]:
              if input.hasKey(key):
                promptInput[key] = input[key].copy

            if input.hasKey("change") and
                input["change"].kind == JObject:
              var promptChange = newJObject()
              for key in [
                "name",
                "path",
                "previousValue",
                "changedAt"
              ]:
                if input["change"].hasKey(key):
                  promptChange[key] =
                    input["change"][key].copy
              promptInput["change"] = promptChange

            if input.hasKey("entity") and
                input["entity"].kind == JString and
                promptStates.kind == JObject:
              let promptEntity = input["entity"].getStr
              if promptStates.hasKey(promptEntity):
                let completeStates = promptStates
                promptStates = newJObject()
                promptStates[promptEntity] =
                  completeStates[promptEntity].copy

          for iteration in 0 ..< agent.maxIterations:
            var messages = newJArray()
            messages.add %*{"role": "system", "content": buildAgentSystemPrompt(agent)}
            if recentSessionMessages.kind == JArray:
              let firstRecent = max(
                0,
                recentSessionMessages.len -
                  application.metisMemoryValue.config.recentMessages
              )
              for index in firstRecent ..< recentSessionMessages.len:
                let message = recentSessionMessages[index]
                if message.kind == JObject and
                    message.hasKey("role") and message.hasKey("content"):
                  messages.add message.copy
            messages.add %*{
              "role": "user",
              "content": $(%*{
                "input": promptInput,
                "iteration": iteration,
                "states": promptStates,
                "metisMemory": memoryContext,
                "variables": agent.sessionVariables
              })
            }

            let llmDebug =
              getEnv("GLAUCOPLASTIC_LLM_DEBUG").strip.toLowerAscii in
              ["1", "true", "yes", "on", "enabled"]
            if llmDebug:
              let systemChars = messages[0]["content"].getStr.len
              let userChars = messages[1]["content"].getStr.len
              plasticDebugTrace(
                "rlm.iteration agent=" & agent.instanceName &
                " iteration=" & $iteration &
                " systemChars=" & $systemChars &
                " userChars=" & $userChars &
                " totalChars=" & $(systemChars + userChars)
              )
              if getEnv("GLAUCOPLASTIC_LLM_DEBUG_PAYLOAD").strip.toLowerAscii in
                  ["1", "true", "yes", "on", "enabled"]:
                plasticDebugTrace("rlm.messages payload=" & $messages)

            let baseRlmTokens =
              max(
                128,
                parseInt(
                  getEnv(
                    "GLAUCOPLASTIC_RLM_MAX_TOKENS",
                    "1024"
                  )
                )
              )
            let maxAttempts =
              max(
                1,
                parseInt(
                  getEnv(
                    "GLAUCOPLASTIC_RLM_RESPONSE_ATTEMPTS",
                    "3"
                  )
                )
              )
            let logRlmResponse =
              application.llamaValue.config.logResponseBody or
              getEnv("GLAUCOPLASTIC_LLM_DEBUG_RESPONSE").strip.toLowerAscii in
                ["1", "true", "yes", "on", "enabled"]

            var program = newJNull()
            var lastResponseError = ""
            var lastRawAssistantContent = ""

            for responseAttempt in 0 ..< maxAttempts:
              var requestMessages = messages.copy
              if responseAttempt > 0:
                let previousAssistantContent =
                  if lastRawAssistantContent.strip.len > 0:
                    lastRawAssistantContent
                  else:
                    "{}"
                requestMessages.add %*{
                  "role": "assistant",
                  "content": previousAssistantContent
                }
                requestMessages.add %*{
                  "role": "user",
                  "content":
                    "O programa anterior foi rejeitado: " &
                    lastResponseError & "\n" &
                    "Corrija-o. Primeiro avalie se alguma Tool é necessária. " &
                    "Quando não for, use instructions=[] e answer normal. " &
                    "Quando for, use somente capabilities literais da lista " &
                    "CAPABILITIES DISPONÍVEIS e nunca o campo name da Tool. " &
                    "Se nenhuma operação for necessária, devolva exatamente " &
                    "instructions=[] e responda em answer. Retorne somente o " &
                    "objeto JSON completo, sem markdown ou texto externo."
                }

              let response = application.llamaValue.chat(
                requestMessages,
                %*{"type": "json_object"},
                min(
                  2048,
                  baseRlmTokens * (responseAttempt + 1)
                ),
                if getEnv(
                    "GLAUCOPLASTIC_RLM_ENABLE_THINKING",
                    "0"
                  ).strip.toLowerAscii in
                    ["1", "true", "yes", "on", "enabled"]:
                  1
                else:
                  0
              )

              try:
                let content = assistantContent(response)
                lastRawAssistantContent = content
                if logRlmResponse:
                  plasticDebugTrace(
                    "rlm.content agent=" & agent.instanceName &
                    " iteration=" & $iteration &
                    " attempt=" & $responseAttempt &
                    " content=" & content
                  )

                let jsonPayload = extractRlmJsonPayload(content)
                if logRlmResponse and
                    jsonPayload != content.strip:
                  plasticDebugTrace(
                    "rlm.content.normalized agent=" &
                    agent.instanceName &
                    " iteration=" & $iteration &
                    " attempt=" & $responseAttempt &
                    " payload=" & jsonPayload
                  )

                if jsonPayload.strip.len == 0:
                  raise newException(
                    PlasticAgentError,
                    "RLM retornou conteúdo vazio."
                  )

                let candidateProgram = parseJson(jsonPayload)
                let validationError =
                  validateRlmProgramCapabilities(
                    agent,
                    candidateProgram
                  )
                if validationError.len > 0:
                  raise newException(
                    PlasticAgentError,
                    validationError
                  )

                program = candidateProgram
                break
              except CatchableError as error:
                lastResponseError = error.msg
                plasticDebugTrace(
                  "rlm.response.retry agent=" &
                  agent.instanceName &
                  " iteration=" & $iteration &
                  " attempt=" & $responseAttempt &
                  " message=" & error.msg
                )

            if program.kind == JNull:
              raise newException(
                PlasticAgentError,
                "RLM não produziu JSON válido após " &
                $maxAttempts & " tentativa(s): " &
                lastResponseError
              )

            let writesBeforeIteration =
              agent.stateWriteCount

            if program.hasKey("instructions") and program["instructions"].kind == JArray:
              for instruction in program["instructions"].items:
                let capabilityName = `jsonStringFieldSym`(instruction, "capability")
                let arguments = if instruction.hasKey("arguments"): instruction["arguments"] else: newJObject()
                if llmDebug:
                  plasticDebugTrace(
                    "rlm.invoke agent=" & agent.instanceName &
                    " capability=" & capabilityName &
                    " arguments=" & $arguments
                  )
                let value = application.rlmValue.invoke(agent, capabilityName, arguments)
                if llmDebug:
                  plasticDebugTrace(
                    "rlm.invoke.result agent=" & agent.instanceName &
                    " capability=" & capabilityName &
                    " value=" & $value
                  )
                let variableName = `jsonStringFieldSym`(instruction, "assign")
                if variableName.len > 0:
                  agent.sessionVariables[variableName] = value

            if program.hasKey("answer") and program["answer"].kind != JNull:
              let answer = program["answer"].copy
              application.metisMemoryValue.recordExchange(
                application.llamaValue,
                agent.metisSession,
                memoryQueryText,
                $answer
              )
              return answer

            let appliedWrites =
              agent.stateWriteCount - writesBeforeIteration
            if appliedWrites > 0:
              let applied = %*{
                "ok": true,
                "writes": appliedWrites
              }
              application.metisMemoryValue.recordExchange(
                application.llamaValue,
                agent.metisSession,
                memoryQueryText,
                $applied
              )
              return applied

          raise newException(PlasticAgentError, "Agente excedeu o limite de iterações RLM")

      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        if `applicationVariable`.llamaValue.isNil:
          `applicationVariable`.llamaValue = newLlamaRuntime()
        if `applicationVariable`.rlmValue.isNil:
          `applicationVariable`.rlmValue = newRlmRuntime()
        installDefaultCapabilities(`applicationVariable`)
        deriveAgents(`applicationVariable`)
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("assistant"):
      result.add quote do:
        proc parseAssistantConfig(
          plan: PlasticPlan;
          applicationName: string
        ): PlasticAssistantConfig =
          result = plasticDefaultAssistantConfig(applicationName)
          result.enabled = true
          let assistantSection = findPlanSection(plan, "assistant")
          if assistantSection.isNone:
            return
          for child in planChildren(assistantSection.get):
            case planName(child)
            of "enabled":
              result.enabled = firstLiteralBool(child, result.enabled)
            of "name", "assistantName":
              result.assistantName = firstLiteralString(
                child,
                result.assistantName
              )
            of "systemPrompt", "purpose":
              result.systemPrompt = firstLiteralString(
                child,
                result.systemPrompt
              )
            of "language":
              result.language = firstLiteralString(child, result.language)
            of "voice", "voiceName":
              result.voiceName = firstLiteralString(child, result.voiceName)
            of "voiceRecognition", "recognition":
              result.voiceRecognition = firstLiteralString(
                child,
                result.voiceRecognition
              )
            of "whisperBinary":
              result.whisperBinary = firstLiteralString(child, result.whisperBinary)
            of "whisperModel":
              result.whisperModel = firstLiteralString(child, result.whisperModel)
            of "ffmpegBinary":
              result.ffmpegBinary = firstLiteralString(child, result.ffmpegBinary)
            of "rlmAgent", "agent":
              result.rlmAgent = firstLiteralString(child, result.rlmAgent)
            of "autoSpeak":
              result.autoSpeak = firstLiteralBool(child, result.autoSpeak)
            of "autoSendVoice":
              result.autoSendVoice = firstLiteralBool(
                child,
                result.autoSendVoice
              )
            of "backgroundLearning", "learn":
              result.backgroundLearning = firstLiteralBool(
                child,
                result.backgroundLearning
              )
            of "maxRecentMessages":
              result.maxRecentMessages = firstLiteralInt(
                child,
                result.maxRecentMessages
              )
            of "maxMemoryItems":
              result.maxMemoryItems = firstLiteralInt(
                child,
                result.maxMemoryItems
              )
            of "responseMaxTokens":
              result.responseMaxTokens = firstLiteralInt(
                child,
                result.responseMaxTokens
              )
            of "learningMaxTokens":
              result.learningMaxTokens = firstLiteralInt(
                child,
                result.learningMaxTokens
              )
            else:
              discard
      result.add newCall(
        ident("appendPlasticPlanSection"),
        applicationVariable.copyNimTree,
        newLit($astToPlanJson(section))
      )
      result.add quote do:
        let assistantConfiguration = parseAssistantConfig(
          `applicationVariable`.planValue,
          `applicationNameLiteral`
        )
        if `applicationVariable`.assistantValue.isNil:
          `applicationVariable`.assistantValue = newPlasticAssistantRuntime(
            `applicationNameLiteral`,
            `applicationVariable`.installationValue.dataRoot,
            `applicationVariable`.llamaValue.endpoint,
            `applicationVariable`.llamaValue.config.modelAlias
          )
        `applicationVariable`.assistantValue.config = assistantConfiguration
        `applicationVariable`.assistantValue.agentRunner = nil
        if assistantConfiguration.rlmAgent.len > 0 and
            `applicationVariable`.agentsValue.hasKey(assistantConfiguration.rlmAgent):
          let assistantAgent =
            `applicationVariable`.agentsValue[assistantConfiguration.rlmAgent]
          `applicationVariable`.assistantValue.agentRunner =
            proc(input: JsonNode): JsonNode =
              assistantAgent.run(input)
        `applicationVariable`.assistantValue.endpoint =
          `applicationVariable`.llamaValue.endpoint
        `applicationVariable`.assistantValue.modelAlias =
          `applicationVariable`.llamaValue.config.modelAlias
        let assistantApplication = `applicationVariable`
        `applicationVariable`.uiHandlersValue[PlasticAssistantHandlerId] =
          proc(event: PlasticUiEvent) =
            assistantApplication.assistantValue.handleUiEvent(
              event.identityPath,
              event.value,
              event.checked
            )
        if assistantConfiguration.enabled:
          `applicationVariable`.assistantValue.prepare()
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("render"):
      result.add quote do:
        when defined(linux):
          const
            PlasticGtkLib = "libgtk-3.so(|.0)"
            PlasticGObjectLib = "libgobject-2.0.so(|.0)"
            PlasticGLibLib = "libglib-2.0.so(|.0)"
            PlasticWebKitLib = "libwebkit2gtk-4.1.so(|.0)"
            PlasticJavaScriptCoreLib = "libjavascriptcoregtk-4.1.so(|.0)"

          var plasticPendingJsRequests: seq[PlasticJsEvalRequest]

          proc plasticEnvEnabled(name: string; fallback = false): bool =
            let value = getEnv(name).strip.toLowerAscii
            if value.len == 0:
              return fallback
            result = value in ["1", "true", "yes", "on", "enabled"]

          proc plasticEnvInt(name: string; fallback: int): int =
            let value = getEnv(name).strip
            if value.len == 0:
              return fallback
            try:
              result = parseInt(value)
            except ValueError:
              result = fallback

          proc plasticGlobalTrace(message: string) =
            try:
              if getEnv("GLAUCOPLASTIC_UI_DEBUG").strip.toLowerAscii notin [
                "1", "true", "yes", "on", "enabled"
              ]:
                return

              let path = getEnv(
                "GLAUCOPLASTIC_UI_TRACE_FILE",
                "/tmp/glaucoplastic-ui-trace.log"
              )
              let line = "[" & $epochTime().int64 & "] " & message & "\n"
              if not fileExists(path):
                writeFile(path, line)
              else:
                var logFile: File
                if open(logFile, path, fmAppend):
                  defer:
                    close(logFile)
                  logFile.write(line)
            except CatchableError:
              discard

          proc plasticUiTrace(message: string) =
            try:
              let path = getEnv(
                "GLAUCOPLASTIC_UI_TRACE_FILE",
                "/tmp/glaucoplastic-ui-trace.log"
              )
              let line = "[" & $epochTime().int64 & "] " & message & "\n"
              if not fileExists(path):
                writeFile(path, line)
              else:
                var logFile: File
                if open(logFile, path, fmAppend):
                  defer:
                    close(logFile)
                  logFile.write(line)
            except CatchableError:
              discard

          proc isPlasticLinuxUiChild(): bool =
            plasticEnvEnabled("GLAUCOPLASTIC_UI_CHILD")

          proc linuxDesktopName(): string =
            result = getEnv("XDG_CURRENT_DESKTOP")
            if result.len == 0:
              result = getEnv("XDG_SESSION_DESKTOP")
            result = result.toLowerAscii

          proc isWlrootsDesktop(): bool =
            let desktop = linuxDesktopName()
            result =
              getEnv("SWAYSOCK").len > 0 or
              getEnv("HYPRLAND_INSTANCE_SIGNATURE").len > 0 or
              desktop.contains("sway") or
              desktop.contains("hyprland") or
              desktop.contains("wlroots")

          proc hasNvidiaDriver(): bool =
            if fileExists("/proc/driver/nvidia/version"):
              return true

            for cardIndex in 0 .. 31:
              let vendorPath = "/sys/class/drm/card" & $cardIndex & "/device/vendor"
              if fileExists(vendorPath):
                try:
                  if readFile(vendorPath).strip.toLowerAscii == "0x10de":
                    return true
                except CatchableError:
                  discard

            result = false

          proc addLinuxUiCandidate(
            candidates: var seq[PlasticLinuxUiCandidate];
            backend: string;
            disableDmabuf: bool;
            reason: string
          ) =
            let normalized = backend.strip.toLowerAscii
            if normalized.len == 0:
              return

            for candidate in candidates:
              if candidate.backend == normalized and
                  candidate.disableDmabuf == disableDmabuf:
                return

            candidates.add PlasticLinuxUiCandidate(
              backend: normalized,
              disableDmabuf: disableDmabuf,
              reason: reason
            )

          proc linuxUiCandidates(): seq[PlasticLinuxUiCandidate] =
            let hasWayland = getEnv("WAYLAND_DISPLAY").len > 0
            let hasX11 = getEnv("DISPLAY").len > 0
            let frameworkExplicit =
              getEnv("GLAUCOPLASTIC_GDK_BACKEND").strip
            let inheritedPreference =
              getEnv("GDK_BACKEND").strip
            let strictBackend =
              plasticEnvEnabled("GLAUCOPLASTIC_UI_STRICT_BACKEND")

            let inheritedSafeMode =
              plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_DMABUF") or
              plasticEnvEnabled("WEBKIT_DISABLE_DMABUF_RENDERER")

            let preferred =
              if frameworkExplicit.len > 0:
                frameworkExplicit
              else:
                inheritedPreference

            if preferred.len > 0:
              for backend in preferred.split(','):
                result.addLinuxUiCandidate(
                  backend,
                  inheritedSafeMode,
                  if frameworkExplicit.len > 0:
                    "backend definido pelo GlaucoPlastic"
                  else:
                    "preferência GDK herdada da sessão"
                )

              if strictBackend:
                return

            let problematicWaylandEnvironment =
              isWlrootsDesktop() or hasNvidiaDriver()

            if problematicWaylandEnvironment:
              if hasX11:
                result.addLinuxUiCandidate(
                  "x11",
                  true,
                  "XWayland preferido para compositor wlroots/NVIDIA"
                )
              if hasWayland:
                result.addLinuxUiCandidate(
                  "wayland",
                  true,
                  "Wayland em modo seguro sem renderer DMA-BUF"
                )
                result.addLinuxUiCandidate(
                  "wayland",
                  false,
                  "Wayland padrão como última alternativa"
                )
            else:
              if hasX11:
                result.addLinuxUiCandidate(
                  "x11",
                  inheritedSafeMode,
                  "display X11/XWayland disponível"
                )
                if not inheritedSafeMode:
                  result.addLinuxUiCandidate(
                    "x11",
                    true,
                    "X11/XWayland sem renderer DMA-BUF"
                  )
              if hasWayland:
                result.addLinuxUiCandidate(
                  "wayland",
                  inheritedSafeMode,
                  "sessão Wayland disponível"
                )
                if not inheritedSafeMode:
                  result.addLinuxUiCandidate(
                    "wayland",
                    true,
                    "Wayland sem renderer DMA-BUF"
                  )

          proc inheritedPlasticEnvironment(): StringTableRef =
            result = newStringTable(modeCaseSensitive)
            for key, value in envPairs():
              result[key] = value

          proc linuxUiCandidateDescription(
            candidate: PlasticLinuxUiCandidate
          ): string =
            result = candidate.backend
            if candidate.disableDmabuf:
              result.add " + DMABUF desativado"
            if candidate.reason.len > 0:
              result.add " (" & candidate.reason & ")"

          proc linuxUiReadyPath(attemptIndex: int): string =
            result = getTempDir() / (
              "glaucoplastic-ui-" &
              $epochTime().int64 &
              "-" &
              $attemptIndex &
              ".ready"
            )

          proc markLinuxUiReady() =
            let readyPath = getEnv("GLAUCOPLASTIC_UI_READY_FILE")
            if readyPath.len == 0:
              return
            try:
              writeFile(
                readyPath,
                getEnv("GDK_BACKEND", "automatic") & "\n"
              )
            except CatchableError:
              discard

          proc runLinuxUiCandidate(
            candidate: PlasticLinuxUiCandidate;
            attemptIndex: int
          ): tuple[startupSucceeded: bool, exitCode: int] =
            let readyPath = linuxUiReadyPath(attemptIndex)
            if fileExists(readyPath):
              removeFile(readyPath)

            let childEnvironment = inheritedPlasticEnvironment()
            childEnvironment["GLAUCOPLASTIC_UI_CHILD"] = "1"
            childEnvironment["GLAUCOPLASTIC_UI_READY_FILE"] = readyPath
            childEnvironment["GDK_BACKEND"] = candidate.backend
            childEnvironment["GLAUCOPLASTIC_GDK_BACKEND"] = candidate.backend

            if candidate.disableDmabuf:
              childEnvironment["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
              childEnvironment["GLAUCOPLASTIC_DISABLE_DMABUF"] = "1"

              # O erro WebLoaderStrategy + SIGSEGV é frequentemente acompanhado por
              # falhas do compositor/GPU no WebKitGTK. Este segundo bloqueio evita a
              # composição acelerada no candidato gráfico seguro.
              childEnvironment["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
            else:
              if childEnvironment.hasKey("WEBKIT_DISABLE_DMABUF_RENDERER"):
                childEnvironment.del("WEBKIT_DISABLE_DMABUF_RENDERER")
              if childEnvironment.hasKey("GLAUCOPLASTIC_DISABLE_DMABUF"):
                childEnvironment.del("GLAUCOPLASTIC_DISABLE_DMABUF")
              if childEnvironment.hasKey("WEBKIT_DISABLE_COMPOSITING_MODE"):
                childEnvironment.del("WEBKIT_DISABLE_COMPOSITING_MODE")

            if plasticEnvEnabled("GLAUCOPLASTIC_SOFTWARE_RENDERING"):
              childEnvironment["LIBGL_ALWAYS_SOFTWARE"] = "1"

            if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
              echo "[GlaucoPlastic] Tentando ",
                linuxUiCandidateDescription(candidate)

            var child: Process
            try:
              child = startProcess(
                command = getAppFilename(),
                workingDir = getCurrentDir(),
                args = commandLineParams(),
                env = childEnvironment,
                options = {poParentStreams}
              )
            except CatchableError as error:
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                echo "[GlaucoPlastic] Não foi possível iniciar o processo filho: ",
                  error.msg
              return (false, 127)

            let startupTimeoutMs = max(
              1_000,
              plasticEnvInt("GLAUCOPLASTIC_UI_STARTUP_TIMEOUT_MS", 12_000)
            )
            let startupDeadline =
              epochTime() + startupTimeoutMs.float / 1000.0

            while child.running and epochTime() < startupDeadline:
              if fileExists(readyPath):
                result.startupSucceeded = true
                if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                  echo "[GlaucoPlastic] Backend ativo: ",
                    linuxUiCandidateDescription(candidate)
                break
              sleep(25)

            if not result.startupSucceeded and child.running:
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                echo "[GlaucoPlastic] Timeout de inicialização para ",
                  linuxUiCandidateDescription(candidate)
              child.terminate()

            result.exitCode = child.waitForExit()
            child.close()

            if fileExists(readyPath):
              result.startupSucceeded = true
              try:
                removeFile(readyPath)
              except CatchableError:
                discard

            if result.exitCode == 0 and not result.startupSucceeded:
              # O processo pode terminar voluntariamente antes do handshake, por
              # exemplo quando o usuário fecha a janela durante a inicialização.
              result.startupSucceeded = true

          proc launchLinuxDesktopChild(): int =
            let candidates = linuxUiCandidates()
            if candidates.len == 0:
              raise newException(
                PlasticRuntimeError,
                "Nenhuma sessão gráfica Linux foi encontrada. " &
                "WAYLAND_DISPLAY e DISPLAY estão vazios."
              )

            var failures: seq[string]
            for index, candidate in candidates:
              let execution = runLinuxUiCandidate(candidate, index)
              if execution.startupSucceeded:
                if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                  echo "[GlaucoPlastic] Backend selecionado: ",
                    linuxUiCandidateDescription(candidate)
                return execution.exitCode

              failures.add(
                linuxUiCandidateDescription(candidate) &
                " terminou com código " &
                $execution.exitCode
              )

            raise newException(
              PlasticRuntimeError,
              "Nenhum backend GTK/WebKitGTK conseguiu iniciar.\n- " &
              failures.join("\n- ")
            )

          proc gtk_init_check(argc: pointer; argv: pointer): cint
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_window_new(windowType: cint): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_window_set_title(window: pointer; title: cstring)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_window_set_default_size(window: pointer; width, height: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_container_add(container, widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_overlay_new(): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_overlay_add_overlay(overlay, widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_fixed_new(): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_fixed_put(fixed, widget: pointer; x, y: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_fixed_move(fixed, widget: pointer; x, y: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_box_new(orientation: cint; spacing: cint): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_box_pack_start(
            box, child: pointer;
            expand, fill: cint;
            padding: cuint
          )
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_container_set_border_width(
            container: pointer;
            borderWidth: cuint
          )
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_size_request(widget: pointer; width, height: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_halign(widget: pointer; align: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_valign(widget: pointer; align: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_margin_start(widget: pointer; margin: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_margin_top(widget: pointer; margin: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_opacity(widget: pointer; opacity: cdouble)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_set_sensitive(widget: pointer; sensitive: cint)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_show_all(widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_show(widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_hide(widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_label_new(text: cstring): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_label_set_markup(label: pointer; markup: cstring)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_spinner_new(): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_spinner_start(spinner: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_progress_bar_new(): pointer
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_progress_bar_set_fraction(
            progressBar: pointer;
            fraction: cdouble
          )
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_progress_bar_set_text(
            progressBar: pointer;
            text: cstring
          )
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_progress_bar_set_show_text(
            progressBar: pointer;
            showText: cint
          )
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_progress_bar_pulse(progressBar: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_widget_destroy(widget: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_window_present(window: pointer)
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_main()
            {.cdecl, importc, dynlib: PlasticGtkLib.}
          proc gtk_main_quit()
            {.cdecl, importc, dynlib: PlasticGtkLib.}

          proc g_signal_connect_data(
            instance: pointer;
            detailedSignal: cstring;
            callback: pointer;
            data: pointer;
            destroyData: pointer;
            connectFlags: cint
          ): culong {.cdecl, importc, dynlib: PlasticGObjectLib.}

          proc g_timeout_add(
            interval: cuint;
            callback: PlasticGSourceFunc;
            data: pointer
          ): cuint {.cdecl, importc, dynlib: PlasticGLibLib.}
          proc g_main_context_iteration(context: pointer; mayBlock: cint): cint
            {.cdecl, importc, dynlib: PlasticGLibLib.}
          proc g_free(memory: pointer)
            {.cdecl, importc, dynlib: PlasticGLibLib.}
          proc g_object_unref(instance: pointer)
            {.cdecl, importc, dynlib: PlasticGObjectLib.}
          proc g_type_check_instance_is_a(
            instance: pointer;
            ifaceType: culong
          ): cint
            {.cdecl, importc, dynlib: PlasticGObjectLib.}

          proc webkit_website_data_manager_new(
            firstOptionName: cstring
          ): pointer
            {.cdecl, varargs, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_context_new_ephemeral(): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_context_new_with_website_data_manager(
            manager: pointer
          ): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_context_get_cookie_manager(
            context: pointer
          ): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_cookie_manager_set_accept_policy(
            manager: pointer;
            policy: cint
          )
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_cookie_manager_set_persistent_storage(
            manager: pointer;
            filename: cstring;
            storage: cint
          )
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_website_data_manager_set_itp_enabled(
            manager: pointer;
            enabled: cint
          )
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_new(): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_new_with_context(
            context: pointer
          ): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_new_with_user_content_manager(
            manager: pointer
          ): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_load_html(
            webView: pointer;
            content, baseUri: cstring
          ) {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_load_uri(webView: pointer; uri: cstring)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_get_uri(webView: pointer): cstring
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_get_user_content_manager(webView: pointer): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_get_settings(webView: pointer): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_settings_set_enable_developer_extras(
            settings: pointer;
            enabled: cint
          ) {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_permission_request_allow(
            request: pointer
          ) {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_media_permission_request_get_type(): culong
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_get_inspector(webView: pointer): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_inspector_show(inspector: pointer)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_inspector_close(inspector: pointer)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_script_new(
            source: cstring;
            injectedFrames: cint;
            injectionTime: cint;
            allowList: pointer;
            blockList: pointer
          ): pointer {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_content_manager_add_script(manager, script: pointer)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_script_unref(script: pointer)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_content_manager_new(): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_user_content_manager_register_script_message_handler(
            manager: pointer;
            name: cstring
          ): cint
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_evaluate_javascript(
            webView: pointer;
            script: cstring;
            length: clong;
            worldName: cstring;
            sourceUri: cstring;
            cancellable: pointer;
            callback: PlasticGAsyncReadyCallback;
            userData: pointer
          ) {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_web_view_evaluate_javascript_finish(
            webView, asyncResult: pointer;
            error: ptr pointer
          ): pointer {.cdecl, importc, dynlib: PlasticWebKitLib.}

          proc jsc_value_to_string(value: pointer): cstring
            {.cdecl, importc, dynlib: PlasticJavaScriptCoreLib.}
          proc webkit_javascript_result_get_js_value(
            result: pointer
          ): pointer
            {.cdecl, importc, dynlib: PlasticWebKitLib.}
          proc webkit_javascript_result_unref(result: pointer)
            {.cdecl, importc, dynlib: PlasticWebKitLib.}

          proc onPlasticJsEvaluated(
            sourceObject, asyncResult, userData: pointer
          ) {.cdecl.} =
            let request = cast[PlasticJsEvalRequest](userData)
            var error: pointer
            let value = webkit_web_view_evaluate_javascript_finish(
              sourceObject,
              asyncResult,
              addr error
            )

            if value.isNil:
              request.failed = true
            else:
              let text = jsc_value_to_string(value)
              if not text.isNil:
                request.text = $text
                g_free(cast[pointer](text))
              g_object_unref(value)

            request.completed = true
            for index, pending in plasticPendingJsRequests:
              if pending == request:
                plasticPendingJsRequests.delete(index)
                break

          proc evaluateNativeJs(
            webView: pointer;
            script: string;
            timeoutMs = 15_000
          ): JsonNode =
            if webView.isNil:
              return newJNull()

            let request = PlasticJsEvalRequest()
            plasticPendingJsRequests.add request
            webkit_web_view_evaluate_javascript(
              webView,
              script.cstring,
              -1,
              nil,
              nil,
              nil,
              onPlasticJsEvaluated,
              cast[pointer](request)
            )

            let deadline = epochTime() + timeoutMs.float / 1000.0
            while not request.completed and epochTime() < deadline:
              discard g_main_context_iteration(nil, 0)
              sleep(1)

            if not request.completed:
              raise newException(
                PlasticForeignBackendError,
                "Tempo excedido ao executar JavaScript"
              )

            if request.failed:
              return newJNull()

            try:
              result = parseJson(request.text)
            except CatchableError:
              result = %request.text

          proc executeNativeJsAsync(webView: pointer; script: string) =
            if webView.isNil:
              return
            webkit_web_view_evaluate_javascript(
              webView,
              script.cstring,
              -1,
              nil,
              nil,
              nil,
              nil,
              nil
            )

          proc openWebKitDeveloperTools(webView: pointer) =
            if webView.isNil:
              return
            let settings = webkit_web_view_get_settings(webView)
            if not settings.isNil:
              webkit_settings_set_enable_developer_extras(settings, 1)
            let inspector = webkit_web_view_get_inspector(webView)
            if not inspector.isNil:
              webkit_web_inspector_show(inspector)

          proc closeWebKitDeveloperTools(webView: pointer) =
            if webView.isNil:
              return
            let inspector = webkit_web_view_get_inspector(webView)
            if not inspector.isNil:
              webkit_web_inspector_close(inspector)

          proc runtimeSummary*(application: PlasticApplication): JsonNode
          proc close*(application: PlasticApplication)

          proc updateForeignHostStatus(
            desktop: PlasticLinuxDesktopRuntime;
            path, status: string
          ) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            let script = """
              (() => {
                const path = """ & $(%path) & """;
                const status = """ & $(%status) & """;
                const element = Array.from(
                  document.querySelectorAll('[data-glauco-foreign]')
                ).find(item => item.dataset.glaucoForeign === path);
                if (element) element.dataset.status = status;
                return true;
              })()
            """
            executeNativeJsAsync(desktop.mainWebView, script)

          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime)

          proc onPlasticForeignWebProcessTerminated(
            webView: pointer;
            reason: cint;
            userData: pointer
          ) {.cdecl.} =
            let element =
              cast[PlasticForeignElementRuntime](userData)

            if element.isNil:
              return

            element.status = pfsFailed
            element.lastError = %*{
              "kind": "web-process-terminated",
              "reason": reason
            }

            let desktop =
              cast[PlasticLinuxDesktopRuntime](
                element.desktopOwner
              )

            if not desktop.isNil:
              desktop.updateForeignHostStatus(
                element.path,
                "failed"
              )

            if not element.eventHandler.isNil:
              element.eventHandler(
                element.path,
                "failed"
              )

            stderr.writeLine(
              "[GlaucoPlastic] WebKit foreign terminou: " &
              element.path &
              ", reason=" &
              $reason
            )

          proc onPlasticMainPermissionRequest(
            webView, request, userData: pointer
          ): cint {.cdecl.} =
            if request.isNil:
              return 0

            let userMediaType =
              webkit_user_media_permission_request_get_type()

            if g_type_check_instance_is_a(
                request,
                userMediaType
              ) == 0:
              return 0

            webkit_permission_request_allow(request)
            plasticUiTrace(
              "WebKit main permission-request: user media allowed"
            )
            result = 1

          proc onPlasticMainWebProcessTerminated(
            webView: pointer;
            reason: cint;
            userData: pointer
          ) {.cdecl.} =
            plasticUiTrace("web-process-terminated")
            let desktop =
              cast[PlasticLinuxDesktopRuntime](userData)

            stderr.writeLine(
              "[GlaucoPlastic] WebKit principal terminou, reason=" &
              $reason
            )

            if not desktop.isNil and desktop.running:
              # A interface principal é HTML local e pode ser reconstruída sem perder
              # o perfil dos WebContents foreign.
              desktop.reloadLinuxDesktop()

          proc onPlasticForeignUriChanged(
            webView, parameterSpec, userData: pointer
          ) {.cdecl.} =
            let element = cast[PlasticForeignElementRuntime](userData)
            if element.isNil:
              return

            let currentUri = webkit_web_view_get_uri(webView)
            if currentUri.isNil:
              return

            let desktop = cast[PlasticLinuxDesktopRuntime](element.desktopOwner)
            if not desktop.isNil:
              desktop.application.foreignValue.notifyUrlChanged(
                element.path,
                $currentUri
              )

          proc onPlasticForeignLoadChanged(
            webView: pointer;
            loadEvent: cint;
            userData: pointer
          ) {.cdecl.} =
            let element = cast[PlasticForeignElementRuntime](userData)
            if element.isNil:
              return

            let desktop = cast[PlasticLinuxDesktopRuntime](element.desktopOwner)
            case loadEvent
            of 0:
              element.status = pfsLoading
              plasticDebugTrace(
                "foreign.loadChanged loading path=" & element.path &
                " uri=" & $webkit_web_view_get_uri(webView)
              )
              gtk_widget_set_opacity(webView, 0.55)
              gtk_widget_set_sensitive(webView, 0)
              if not desktop.isNil:
                desktop.updateForeignHostStatus(element.path, "loading")
              if not element.eventHandler.isNil:
                element.eventHandler(element.path, "loading")
            of 3:
              element.status = pfsReady
              plasticDebugTrace(
                "foreign.loadChanged ready path=" & element.path &
                " uri=" & $webkit_web_view_get_uri(webView)
              )
              gtk_widget_set_opacity(webView, 1.0)
              gtk_widget_set_sensitive(webView, 1)
              if not desktop.isNil:
                desktop.updateForeignHostStatus(element.path, "ready")
              if not element.eventHandler.isNil:
                element.eventHandler(element.path, "loaded")
            else:
              discard

          proc applyPlasticForeignLayoutSnapshot(
            desktop: PlasticLinuxDesktopRuntime;
            payload: string
          )

          proc drainPlasticUiEvents(desktop: PlasticLinuxDesktopRuntime)

          proc onPlasticForeignLayoutMessageReceived(
            manager, jsResult, userData: pointer
          ) {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](userData)
            if desktop.isNil or jsResult.isNil:
              return

            let jsValue = webkit_javascript_result_get_js_value(jsResult)
            var payload = ""
            if not jsValue.isNil:
              let text = jsc_value_to_string(jsValue)
              if not text.isNil:
                payload = $text
                g_free(cast[pointer](text))
            # `jsResult` é emprestado pelo sinal script-message-received.
            # Liberá-lo aqui causa double-unref dentro do WebKitGTK e pode
            # terminar o processo com SIGSEGV após mensagens do foreign.

            if payload.len == 0:
              return

            desktop.applyPlasticForeignLayoutSnapshot(payload)
            desktop.drainPlasticUiEvents()

          proc newLinuxWebKitForeignBackend(
            desktop: PlasticLinuxDesktopRuntime
          ): PlasticForeignBackend =
            result = PlasticForeignBackend(name: "webkitgtk-4.1")

            result.create = proc(element: PlasticForeignElementRuntime) =
              if not element.nativeHandle.isNil:
                return

              # Todo foreign usa o mesmo WebContext criado com o
              # WebsiteDataManager persistente. Assim cookies, localStorage,
              # IndexedDB, service workers e cache ficam no perfil da aplicação.
              let webView =
                if desktop.webContext.isNil:
                  webkit_web_view_new()
                else:
                  webkit_web_view_new_with_context(desktop.webContext)

              if webView.isNil:
                raise newException(
                  PlasticForeignBackendError,
                  "WebKitGTK não conseguiu criar o WebContents foreign"
                )

              let manager =
                webkit_web_view_get_user_content_manager(webView)
              if manager.isNil:
                raise newException(
                  PlasticForeignBackendError,
                  "WebKitGTK não forneceu o gerenciador de conteúdo do foreign"
                )

              discard g_signal_connect_data(
                manager,
                "script-message-received::glaucoplasticLayout",
                cast[pointer](onPlasticForeignLayoutMessageReceived),
                cast[pointer](desktop),
                nil,
                0
              )
              if webkit_user_content_manager_register_script_message_handler(
                manager,
                "glaucoplasticLayout"
              ) == 0:
                raise newException(
                  PlasticForeignBackendError,
                  "WebKitGTK não conseguiu registrar o canal de layout"
                )
              element.nativeHandle = webView
              element.desktopOwner = cast[pointer](desktop)
              element.status = pfsIdle
              gtk_widget_set_size_request(webView, 1, 1)
              gtk_widget_set_halign(webView, 1)
              gtk_widget_set_valign(webView, 1)
              gtk_overlay_add_overlay(desktop.overlay, webView)
              gtk_widget_hide(webView)
              discard g_signal_connect_data(
                webView,
                "load-changed",
                cast[pointer](onPlasticForeignLoadChanged),
                cast[pointer](element),
                nil,
                0
              )
              discard g_signal_connect_data(
                webView,
                "notify::uri",
                cast[pointer](onPlasticForeignUriChanged),
                cast[pointer](element),
                nil,
                0
              )
              discard g_signal_connect_data(
                webView,
                "web-process-terminated",
                cast[pointer](onPlasticForeignWebProcessTerminated),
                cast[pointer](element),
                nil,
                0
              )

            result.navigate = proc(element: PlasticForeignElementRuntime; url: string) =
              if element.nativeHandle.isNil:
                raise newException(PlasticForeignBackendError, "WebContents foreign ainda não foi criado")
              element.currentUrl = url
              element.status = pfsLoading
              webkit_web_view_load_uri(element.nativeHandle, url.cstring)

            result.evalJs = proc(
              element: PlasticForeignElementRuntime;
              script: string;
              timeoutMs: int
            ): JsonNode =
              evaluateNativeJs(element.nativeHandle, script, timeoutMs)

            result.injectDocumentStart = proc(
              element: PlasticForeignElementRuntime;
              script: string
            ) =
              if element.nativeHandle.isNil:
                return
              let manager = webkit_web_view_get_user_content_manager(element.nativeHandle)
              if manager.isNil:
                return
              let userScript = webkit_user_script_new(
                script.cstring,
                0,
                0,
                nil,
                nil
              )
              if not userScript.isNil:
                webkit_user_content_manager_add_script(manager, userScript)
                webkit_user_script_unref(userScript)

            result.applyLayoutSnapshot = proc(
              element: PlasticForeignElementRuntime;
              payload: string
            ) =
              if element.isNil:
                return
              let desktop =
                cast[PlasticLinuxDesktopRuntime](element.desktopOwner)
              if desktop.isNil:
                return
              desktop.applyPlasticForeignLayoutSnapshot(payload)
              desktop.drainPlasticUiEvents()

            result.close = proc(element: PlasticForeignElementRuntime) =
              if not element.nativeHandle.isNil:
                gtk_widget_destroy(element.nativeHandle)
                element.nativeHandle = nil
              element.status = pfsClosed

          proc jsonCoordinate(node: JsonNode; key: string): int =
            if node.kind != JObject or not node.hasKey(key):
              return 0
            case node[key].kind
            of JInt:
              result = node[key].getInt
            of JFloat:
              result = node[key].getFloat.int
            else:
              result = 0

          proc applyPlasticForeignLayoutSnapshot(
            desktop: PlasticLinuxDesktopRuntime;
            rectangles: JsonNode
          ) =
            if desktop.isNil or not desktop.running:
              return

            if rectangles.kind != JArray:
              return

            var visiblePaths = initHashSet[string]()
            for rectangle in rectangles.items:
              if rectangle.kind != JObject:
                continue

              let path = `jsonStringFieldSym`(rectangle, "path")
              if path.len == 0 or
                  not desktop.application.foreignValue.elements.hasKey(path):
                continue

              let element = desktop.application.foreignValue.elements[path]
              if element.nativeHandle.isNil:
                continue

              visiblePaths.incl path
              let x = jsonCoordinate(rectangle, "x")
              let y = jsonCoordinate(rectangle, "y")
              let width = max(1, jsonCoordinate(rectangle, "width"))
              let height = max(1, jsonCoordinate(rectangle, "height"))
              let geometryKey =
                $x & ":" & $y & ":" & $width & ":" & $height & ":" &
                (if rectangle.hasKey("visible") and
                    rectangle["visible"].kind == JBool and
                    rectangle["visible"].getBool:
                  "1"
                else:
                  "0")

              if geometryKey != element.lastGeometryKey:
                element.lastGeometryKey = geometryKey
                gtk_fixed_move(desktop.fixed, element.nativeHandle, x.cint, y.cint)
                gtk_widget_set_size_request(
                  element.nativeHandle,
                  width.cint,
                  height.cint
                )

              if rectangle.hasKey("visible") and
                  rectangle["visible"].kind == JBool and
                  rectangle["visible"].getBool:
                gtk_widget_show(element.nativeHandle)
              else:
                gtk_widget_hide(element.nativeHandle)

            for path, element in desktop.application.foreignValue.elements:
              if path notin visiblePaths and not element.nativeHandle.isNil:
                gtk_widget_hide(element.nativeHandle)

          proc applyPlasticForeignLayoutSnapshot(
            desktop: PlasticLinuxDesktopRuntime;
            payload: string
          ) =
            if payload.len == 0:
              return
            try:
              desktop.applyPlasticForeignLayoutSnapshot(parseJson(payload))
            except CatchableError as error:
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                echo "[GlaucoPlastic] layout snapshot inválido: ", error.msg

          proc drainPlasticUiEvents(desktop: PlasticLinuxDesktopRuntime) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return

            let script = """
              (() => {
                const queue = window.__glaucoplasticEvents ||
                  (window.__glaucoplasticEvents = []);
                const events = queue.splice(0, queue.length);
                return JSON.stringify(events);
              })()
            """

            try:
              let events = evaluateNativeJs(desktop.mainWebView, script, 500)
              if events.kind != JArray:
                return

              for event in events.items:
                if event.kind != JObject:
                  continue

                let eventValue =
                  if event.hasKey("value") and event["value"].kind != JNull:
                    event["value"].copy
                  elif event.hasKey("checked") and event["checked"].kind != JNull:
                    event["checked"].copy
                  else:
                    newJNull()

                let bindState = `jsonStringFieldSym`(event, "bindState")
                if bindState.len > 0 and
                    desktop.application.statesValue.exists(bindState):
                  `stateSetInternalSym`(
                    desktop.application.statesValue,
                    bindState,
                    eventValue
                  )

                # O navegador devolve somente dados do evento e um ID opaco.
                # A ação correspondente é uma closure Nim registrada pelo macro.
                desktop.application.dispatchUiEvent(event)
            except CatchableError as error:
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                echo "[GlaucoPlastic] Falha ao processar evento da interface: ",
                  error.msg

          proc consoleNodeBaseName(node: NimNode): string =
            if node.isNil or node.kind notin {nnkCall, nnkCommand} or node.len == 0:
              return ""
            let base = node[0]
            case base.kind
            of nnkIdent, nnkSym, nnkAccQuoted:
              result = base.repr
            else:
              result = base.repr

          proc consoleNodeArgs(node: NimNode): seq[NimNode] =
            if node.isNil or node.kind notin {nnkCall, nnkCommand}:
              return
            for index in 1 ..< node.len:
              result.add node[index]

          proc consoleValueFromNode(
            desktop: PlasticLinuxDesktopRuntime;
            node: NimNode
          ): JsonNode =
            if node.isNil:
              return newJNull()

            case node.kind
            of nnkStmtList:
              if node.len == 0:
                return newJNull()
              result = consoleValueFromNode(desktop, node[^1])
            of nnkPar:
              if node.len == 0:
                return newJNull()
              result = consoleValueFromNode(desktop, node[0])
            of nnkNilLit:
              result = newJNull()
            of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
              result = %node.strVal
            of nnkIntLit .. nnkUInt64Lit:
              result = %node.intVal
            of nnkFloatLit .. nnkFloat128Lit:
              result = %node.floatVal
            of nnkIdent, nnkSym:
              case node.strVal
              of "true":
                result = %true
              of "false":
                result = %false
              of "nil":
                result = newJNull()
              of "states":
                result = desktop.application.statesValue.snapshot()
              of "foreign":
                result = desktop.application.foreignValue.list()
              of "components":
                result = desktop.application.components()
              of "renderTree":
                result = desktop.application.renderTree()
              of "summary":
                result = desktop.application.runtimeSummary()
              of "orm":
                result = desktop.application.runtimeSummary()["orm"].copy
              of "okf":
                result = desktop.application.runtimeSummary()["okf"].copy
              of "llama":
                result = desktop.application.runtimeSummary()["llama"].copy
              of "webview":
                result = desktop.application.runtimeSummary()["webview"].copy
              of "agents":
                result = desktop.application.runtimeSummary()["agents"].copy
              else:
                let path = stateAccessPathAst(node)
                if path.len > 0 and
                    desktop.application.statesValue.exists(path[0]):
                  result = glaucoplasticStateGetPathInternal(
                    desktop.application.statesValue,
                    path
                  )
                else:
                  result = %node.repr
            of nnkDotExpr:
              let path = stateAccessPathAst(node)
              if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                result = glaucoplasticStateGetPathInternal(
                  desktop.application.statesValue,
                  path
                )
              else:
                result = %node.repr
            of nnkCall, nnkCommand:
              let baseName = consoleNodeBaseName(node).toLowerAscii()
              let args = consoleNodeArgs(node)
              case baseName
              of "state", "states":
                if args.len == 0:
                  result = desktop.application.statesValue.snapshot()
                else:
                  let path = stateAccessPathAst(args[0])
                  if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                    result = glaucoplasticStateGetPathInternal(
                      desktop.application.statesValue,
                      path
                    )
                  else:
                    result = newJNull()
              of "foreign":
                if args.len == 0:
                  result = desktop.application.foreignValue.list()
                else:
                  let actionName =
                    if args.len > 1 and args[1].kind in {nnkIdent, nnkSym}:
                      args[1].strVal.toLowerAscii()
                    else:
                      ""
                  case actionName
                  of "describe":
                    result = desktop.application.foreignValue.describe(
                      consoleValueFromNode(desktop, args[0]).getStr
                    )
                  of "list":
                    result = desktop.application.foreignValue.list()
                  else:
                    let path = consoleValueFromNode(desktop, args[0]).getStr
                    if path.len > 0 and desktop.application.foreignValue.elements.hasKey(path):
                      result = %*{
                        "path": path,
                        "description": desktop.application.foreignValue.describe(path),
                        "element": desktop.application.foreignValue.describe(path)
                      }
                    else:
                      result = newJNull()
              of "components":
                result = desktop.application.components()
              of "rendertree":
                result = desktop.application.renderTree()
              of "summary":
                result = desktop.application.runtimeSummary()
              else:
                let path = stateAccessPathAst(node)
                if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                  result = glaucoplasticStateGetPathInternal(
                    desktop.application.statesValue,
                    path
                  )
                else:
                  result = %node.repr
            of nnkBracket:
              result = newJArray()
              for index in 0 ..< node.len:
                let child = node[index]
                result.add consoleValueFromNode(desktop, child)
            of nnkTableConstr:
              result = newJObject()
              for index in 0 ..< node.len:
                let child = node[index]
                if child.kind == nnkExprColonExpr:
                  let key = child[0].repr
                  result[key] = consoleValueFromNode(desktop, child[1])
            of nnkPrefix:
              if node.len == 2 and node[0].repr in ["%", "%*"]:
                result = consoleValueFromNode(desktop, node[1])
              else:
                result = %node.repr
            of nnkInfix:
              if node.len == 3:
                let op = node[0].repr
                let left = consoleValueFromNode(desktop, node[1])
                let right = consoleValueFromNode(desktop, node[2])
                case op
                of "&":
                  result = %(left.pretty() & right.pretty())
                of "+":
                  if left.kind in {JInt, JFloat} or right.kind in {JInt, JFloat}:
                    result = %(left.getFloat + right.getFloat)
                  else:
                    result = %(left.pretty() & right.pretty())
                else:
                  result = %node.repr
              else:
                result = %node.repr
            else:
              result = %node.repr

          proc consoleAssignNode(
            desktop: PlasticLinuxDesktopRuntime;
            targetNode, valueNode: NimNode
          ): bool =
            let path = stateAccessPathAst(targetNode)
            if path.len == 0 or not desktop.application.statesValue.exists(path[0]):
              return false

            let value = consoleValueFromNode(desktop, valueNode)
            glaucoplasticStateSetPathInternal(
              desktop.application.statesValue,
              path,
              value
            )
            true

          proc executePlasticConsoleAst(
            desktop: PlasticLinuxDesktopRuntime;
            node: NimNode
          ): JsonNode =
            if node.isNil:
              return newJNull()

            case node.kind
            of nnkStmtList:
              result = newJNull()
              for index in 0 ..< node.len:
                let child = node[index]
                result = executePlasticConsoleAst(desktop, child)
            of nnkAsgn, nnkExprEqExpr:
              if node.len == 2 and consoleAssignNode(desktop, node[0], node[1]):
                result = consoleValueFromNode(desktop, node[1])
              else:
                result = newJNull()
            of nnkCall, nnkCommand:
              let baseName = consoleNodeBaseName(node).toLowerAscii()
              let args = consoleNodeArgs(node)
              case baseName
              of "state", "states":
                if args.len == 0:
                  result = desktop.application.statesValue.snapshot()
                else:
                  let path = stateAccessPathAst(args[0])
                  if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                    result = glaucoplasticStateGetPathInternal(
                      desktop.application.statesValue,
                      path
                    )
                  else:
                    result = newJNull()
              of "foreign":
                if args.len == 0:
                  result = desktop.application.foreignValue.list()
                elif args.len >= 2:
                  let foreignPath = consoleValueFromNode(desktop, args[0]).getStr
                  let actionName =
                    if args[1].kind in {nnkIdent, nnkSym}:
                      args[1].strVal.toLowerAscii()
                    else:
                      consoleValueFromNode(desktop, args[1]).getStr.toLowerAscii()
                  case actionName
                  of "navigate":
                    if args.len >= 3:
                      let urlValue = consoleValueFromNode(desktop, args[2]).getStr
                      desktop.application.foreignValue.navigate(
                        foreignPath,
                        urlValue
                      )
                      result = %"ok"
                  of "reload":
                    desktop.application.foreignValue.reload(foreignPath)
                    result = %"ok"
                  of "goBack", "back":
                    desktop.application.foreignValue.goBack(foreignPath)
                    result = %"ok"
                  of "goForward", "forward":
                    desktop.application.foreignValue.goForward(foreignPath)
                    result = %"ok"
                  of "describe":
                    result = desktop.application.foreignValue.describe(foreignPath)
                  else:
                    result = newJNull()
                else:
                  result = newJNull()
              of "ui", "dispatch":
                if args.len >= 2:
                  let identity = consoleValueFromNode(desktop, args[0]).getStr
                  let eventName =
                    if args[1].kind in {nnkIdent, nnkSym}:
                      args[1].strVal
                    else:
                      consoleValueFromNode(desktop, args[1]).getStr
                  let handlerId =
                    desktop.application.uiHandlerId(identity, eventName)
                  if handlerId.len > 0:
                    desktop.application.dispatchUiEvent(
                      %*{
                        "handlerId": handlerId,
                        "event": eventName,
                        "identity": identity,
                        "bindState": ""
                      }
                    )
                    result = %"ok"
                else:
                  result = newJNull()
              of "click":
                if args.len >= 1:
                  let identity = consoleValueFromNode(desktop, args[0]).getStr
                  let handlerId =
                    desktop.application.uiHandlerId(identity, "click")
                  if handlerId.len > 0:
                    desktop.application.dispatchUiEvent(
                      %*{
                        "handlerId": handlerId,
                        "event": "click",
                        "identity": identity,
                        "bindState": ""
                      }
                    )
                    result = %"ok"
                else:
                  result = newJNull()
              of "summary":
                result = desktop.application.runtimeSummary()
              of "components":
                result = desktop.application.components()
              of "renderTree":
                result = desktop.application.renderTree()
              of "foreigns", "foreignlist":
                result = desktop.application.foreignValue.list()
              of "reload":
                desktop.reloadLinuxDesktop()
                result = %"ok"
              of "quit", "exit":
                desktop.application.close()
                result = %"bye"
              else:
                result = consoleValueFromNode(desktop, node)
            of nnkIdent, nnkSym, nnkDotExpr:
              result = consoleValueFromNode(desktop, node)
            else:
              result = consoleValueFromNode(desktop, node)

          proc consoleReplWrite(message: string) =
            stderr.writeLine("[GlaucoPlastic][repl] " & message)

          proc consoleStatePath(text: string): seq[string] =
            var cleaned = text.strip
            let lowered = cleaned.toLowerAscii()
            if lowered.startsWith("states."):
              cleaned = cleaned[7 .. ^1]
            elif lowered.startsWith("state."):
              cleaned = cleaned[6 .. ^1]
            elif lowered.startsWith("states "):
              cleaned = cleaned[7 .. ^1].strip
            elif lowered.startsWith("state "):
              cleaned = cleaned[6 .. ^1].strip

            for part in cleaned.split('.'):
              let trimmed = part.strip
              if trimmed.len > 0:
                result.add trimmed

          proc consoleResolveTextValue(
            desktop: PlasticLinuxDesktopRuntime;
            text: string
          ): JsonNode =
            let trimmed = text.strip
            if trimmed.len == 0:
              return newJNull()

            let lowered = trimmed.toLowerAscii()
            if lowered.startsWith("state ") or lowered.startsWith("states ") or
                lowered.startsWith("state.") or lowered.startsWith("states."):
              let path = consoleStatePath(trimmed)
              if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                return glaucoplasticStateGetPathInternal(
                  desktop.application.statesValue,
                  path
                )

            case lowered
            of "states":
              result = desktop.application.statesValue.snapshot()
            of "foreign":
              result = desktop.application.foreignValue.list()
            of "components":
              result = desktop.application.components()
            of "rendertree":
              result = desktop.application.renderTree()
            of "summary":
              result = desktop.application.runtimeSummary()
            of "orm":
              result = desktop.application.runtimeSummary()["orm"].copy
            of "okf":
              result = desktop.application.runtimeSummary()["okf"].copy
            of "llama":
              result = desktop.application.runtimeSummary()["llama"].copy
            of "webview":
              result = desktop.application.runtimeSummary()["webview"].copy
            of "agents":
              result = desktop.application.runtimeSummary()["agents"].copy
            else:
              try:
                result = parseJson(trimmed)
              except CatchableError:
                result = %trimmed

          proc executePlasticConsoleLine(
            desktop: PlasticLinuxDesktopRuntime;
            rawLine: string
          ): JsonNode =
            let line = rawLine.strip
            if line.len == 0:
              return newJNull()

            let parts = line.splitWhitespace()
            if parts.len == 0:
              return newJNull()

            let command = parts[0].toLowerAscii()
            case command
            of "help", "?":
              consoleReplWrite(
                "comandos: state get/set, foreign list/describe/navigate/reload, click, ui, summary, components, renderTree, orm, okf, llama, webview, agents, reload, quit"
              )
              result = %"ok"
            of "summary":
              result = desktop.application.runtimeSummary()
            of "components":
              result = desktop.application.components()
            of "rendertree":
              result = desktop.application.renderTree()
            of "orm":
              result = desktop.application.runtimeSummary()["orm"].copy
            of "okf":
              result = desktop.application.runtimeSummary()["okf"].copy
            of "llama":
              result = desktop.application.runtimeSummary()["llama"].copy
            of "webview":
              result = desktop.application.runtimeSummary()["webview"].copy
            of "agents":
              result = desktop.application.runtimeSummary()["agents"].copy
            of "states":
              if parts.len >= 3 and parts[1].toLowerAscii() in ["get", "show"]:
                let path = consoleStatePath(parts[2 .. ^1].join(" "))
                if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                  result = glaucoplasticStateGetPathInternal(
                    desktop.application.statesValue,
                    path
                  )
                else:
                  result = newJNull()
              else:
                result = desktop.application.statesValue.snapshot()
            of "state":
              if line.contains("="):
                let eqPos = line.find('=')
                let lhs = line[0 ..< eqPos].strip
                let rhs = line[eqPos + 1 .. ^1].strip
                let path = consoleStatePath(lhs)
                if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                  glaucoplasticStateSetPathInternal(
                    desktop.application.statesValue,
                    path,
                    consoleResolveTextValue(desktop, rhs)
                  )
                  result = consoleResolveTextValue(desktop, rhs)
                else:
                  result = newJNull()
              elif parts.len >= 2:
                let pathText =
                  if parts[1].toLowerAscii() in ["get", "show"] and parts.len >= 3:
                    parts[2 .. ^1].join(" ")
                  else:
                    parts[1 .. ^1].join(" ")
                let path = consoleStatePath(pathText)
                if path.len > 0 and desktop.application.statesValue.exists(path[0]):
                  result = glaucoplasticStateGetPathInternal(
                    desktop.application.statesValue,
                    path
                  )
                else:
                  result = newJNull()
              else:
                result = desktop.application.statesValue.snapshot()
            of "foreign":
              if parts.len == 1 or (parts.len == 2 and parts[1].toLowerAscii() == "list"):
                result = desktop.application.foreignValue.list()
              elif parts.len >= 3 and parts[1].toLowerAscii() in ["describe", "inspect"]:
                result = desktop.application.foreignValue.describe(parts[2])
              elif parts.len >= 3 and parts[2].toLowerAscii() in ["navigate", "reload", "goback", "back", "goforward", "forward"]:
                let path = parts[1]
                let action = parts[2].toLowerAscii()
                let argumentText =
                  if parts.len > 3:
                    parts[3 .. ^1].join(" ")
                  else:
                    ""
                case action
                of "navigate":
                  desktop.application.foreignValue.navigate(
                    path,
                    consoleResolveTextValue(desktop, argumentText).getStr
                  )
                  result = %"ok"
                of "reload":
                  desktop.application.foreignValue.reload(path)
                  result = %"ok"
                of "goback", "back":
                  desktop.application.foreignValue.goBack(path)
                  result = %"ok"
                of "goforward", "forward":
                  desktop.application.foreignValue.goForward(path)
                  result = %"ok"
                else:
                  result = newJNull()
              elif parts.len >= 2:
                result = desktop.application.foreignValue.describe(parts[1])
              else:
                result = desktop.application.foreignValue.list()
            of "click":
              if parts.len >= 2:
                let identity = parts[1]
                let handlerId = desktop.application.uiHandlerId(identity, "click")
                if handlerId.len > 0:
                  desktop.application.dispatchUiEvent(
                    %*{
                      "handlerId": handlerId,
                      "event": "click",
                      "identity": identity,
                      "bindState": ""
                    }
                  )
                  result = %"ok"
                else:
                  result = newJNull()
              else:
                result = newJNull()
            of "ui", "dispatch":
              if parts.len >= 3:
                let identity = parts[1]
                let eventName = parts[2]
                let handlerId = desktop.application.uiHandlerId(identity, eventName)
                if handlerId.len > 0:
                  desktop.application.dispatchUiEvent(
                    %*{
                      "handlerId": handlerId,
                      "event": eventName,
                      "identity": identity,
                      "bindState": ""
                    }
                  )
                  result = %"ok"
                else:
                  result = newJNull()
              else:
                result = newJNull()
            of "reload":
              desktop.reloadLinuxDesktop()
              result = %"ok"
            of "quit", "exit":
              desktop.application.close()
              result = %"bye"
            else:
              result = consoleResolveTextValue(desktop, line)

          proc newPlasticConsoleReplState(
            desktop: PlasticLinuxDesktopRuntime
          ): PlasticConsoleReplState =
            result = PlasticConsoleReplState(
              desktop: desktop,
              running: true
            )
            initLock(result.lock)

          proc runPlasticConsoleReplWorker(
            replState: PlasticConsoleReplState
          ) {.thread.} =
            if replState.isNil:
              return

            consoleReplWrite(
              "repl pronto. Ex.: state Search.url = \"https://...\" | click Home.Buscar | foreign Home.Portal navigate \"https://...\""
            )

            while replState.running:
              try:
                let line = stdin.readLine()
                acquire(replState.lock)
                replState.pendingLines.add line
                release(replState.lock)
              except EOFError:
                break
              except CatchableError as error:
                consoleReplWrite("erro lendo stdin: " & error.msg)
                break

          proc drainPlasticConsoleRepl(data: pointer): cint {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](data)
            if desktop.isNil or not desktop.running or desktop.consoleReplState.isNil:
              return 0

            var pending: seq[string]
            acquire(desktop.consoleReplState.lock)
            if desktop.consoleReplState.pendingLines.len > 0:
              pending = desktop.consoleReplState.pendingLines
              desktop.consoleReplState.pendingLines = @[]
            release(desktop.consoleReplState.lock)

            for line in pending:
              let trimmed = line.strip
              if trimmed.len == 0:
                continue

              try:
                let result = desktop.executePlasticConsoleLine(trimmed)
                if result.kind != JNull:
                  consoleReplWrite(result.pretty())
              except CatchableError as error:
                consoleReplWrite(
                  "erro ao executar `" & trimmed & "`: " & error.msg
                )

            return 1

          proc publishPlasticAssistantSnapshot(
            desktop: PlasticLinuxDesktopRuntime
          ) =
            if desktop.isNil or desktop.mainWebView.isNil or
                desktop.application.assistantValue.isNil or
                not desktop.application.assistantValue.config.enabled:
              return
            let runtime = desktop.application.assistantValue
            acquire(runtime.dataLock)
            let shouldPublish = runtime.revision != runtime.publishedRevision
            release(runtime.dataLock)
            if not shouldPublish:
              return
            let snapshot = plasticAssistantSnapshot(runtime)
            let script = """
              (() => {
                if (window.__glaucoplasticAssistantApply) {
                  window.__glaucoplasticAssistantApply(""" & $snapshot & """);
                  return true;
                }
                return false;
              })()
            """
            try:
              let applied = evaluateNativeJs(
                desktop.mainWebView,
                script,
                500
              )
              if applied.kind == JBool and applied.getBool:
                acquire(runtime.dataLock)
                runtime.publishedRevision = runtime.revision
                release(runtime.dataLock)
            except CatchableError:
              discard

          proc syncPlasticForeignGeometry(data: pointer): cint {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](data)
            if desktop.isNil or not desktop.running or desktop.mainWebView.isNil:
              return 0

            let script = """
              JSON.stringify(
                window.__glaucoplasticForeignLayoutSnapshot || []
              )
            """

            try:
              let rectangles = evaluateNativeJs(desktop.mainWebView, script, 800)
              if rectangles.kind != JArray:
                return 1

              var visiblePaths = initHashSet[string]()
              for rectangle in rectangles.items:
                let path = `jsonStringFieldSym`(rectangle, "path")
                if path.len == 0 or not desktop.application.foreignValue.elements.hasKey(path):
                  continue
                let element = desktop.application.foreignValue.elements[path]
                if element.nativeHandle.isNil:
                  continue

                visiblePaths.incl path
                let x = jsonCoordinate(rectangle, "x")
                let y = jsonCoordinate(rectangle, "y")
                let width = max(1, jsonCoordinate(rectangle, "width"))
                let height = max(1, jsonCoordinate(rectangle, "height"))
                if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                  plasticUiTrace(
                    "foreign.geometry path=" & path &
                    " x=" & $x &
                    " y=" & $y &
                    " width=" & $width &
                    " height=" & $height &
                    " visible=" & $(
                      rectangle.hasKey("visible") and
                      rectangle["visible"].kind == JBool and
                      rectangle["visible"].getBool
                    )
                  )
                let geometryKey =
                  $x & ":" & $y & ":" & $width & ":" & $height & ":" &
                  (if rectangle.hasKey("visible") and
                      rectangle["visible"].kind == JBool and
                      rectangle["visible"].getBool:
                    "1"
                  else:
                    "0")

                if geometryKey != element.lastGeometryKey:
                  element.lastGeometryKey = geometryKey
                  gtk_widget_set_margin_start(element.nativeHandle, x.cint)
                  gtk_widget_set_margin_top(element.nativeHandle, y.cint)
                  gtk_widget_set_size_request(
                    element.nativeHandle,
                    width.cint,
                    height.cint
                  )

                if rectangle.hasKey("visible") and rectangle["visible"].kind == JBool and
                    rectangle["visible"].getBool:
                  gtk_widget_show(element.nativeHandle)
                else:
                  gtk_widget_hide(element.nativeHandle)

              for path, element in desktop.application.foreignValue.elements:
                if path notin visiblePaths and not element.nativeHandle.isNil:
                  gtk_widget_hide(element.nativeHandle)
            except CatchableError:
              discard

            desktop.drainPlasticUiEvents()
            desktop.publishPlasticAssistantSnapshot()

            return 1

          proc onPlasticWindowDestroyed(widget, userData: pointer) {.cdecl.} =
            plasticUiTrace("window-destroyed")
            let desktop = cast[PlasticLinuxDesktopRuntime](userData)
            if not desktop.isNil:
              closeWebKitDeveloperTools(desktop.mainWebView)
              desktop.running = false
              if not desktop.consoleReplState.isNil:
                desktop.consoleReplState.running = false
              desktop.application.uiPropertyWriterValue = nil
              for _, element in desktop.application.foreignValue.elements:
                element.nativeHandle = nil
                element.status = pfsClosed
            gtk_main_quit()

          proc onPlasticWindowDeleteEvent(
            widget: pointer;
            event: pointer;
            userData: pointer
          ): cint {.cdecl.} =
            plasticUiTrace("window-delete-event")
            return 0

          proc onPlasticWindowUnmapped(widget, userData: pointer) {.cdecl.} =
            plasticUiTrace("window-unmapped")

          proc onPlasticInitialRender(data: pointer): cint {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](data)
            if desktop.isNil or not desktop.running:
              return 0
            plasticUiTrace("initial-render")
            desktop.reloadLinuxDesktop()
            if not desktop.bootWidget.isNil:
              gtk_widget_hide(desktop.bootWidget)
            if not desktop.mainWebView.isNil:
              gtk_widget_show(desktop.mainWebView)
            return 0

          proc setDesktopIdentityProperty(
            desktop: PlasticLinuxDesktopRuntime;
            path, propertyName: string;
            value: JsonNode
          )

          proc onPlasticBootFinalizeActivateDesktop(data: pointer): cint {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](data)
            if desktop.isNil or not desktop.running:
              return 0

            plasticUiTrace("boot finalize: activate desktop")
            if not desktop.bootWidget.isNil:
              gtk_widget_destroy(desktop.bootWidget)
              desktop.bootWidget = nil

            desktop.reloadLinuxDesktop()
            executeNativeJsAsync(
              desktop.mainWebView,
              """
              (() => {
                const items = Array.from(
                  document.querySelectorAll('[data-glauco-identity]')
                );
                const bootOverlay = items.find(item => {
                  const value = item.dataset.glaucoIdentity || '';
                  return value.includes('BootOverlay') || value.includes('BootScreen');
                });
                const appShell = items.find(item => {
                  const value = item.dataset.glaucoIdentity || '';
                  return value.includes('AppShell');
                });
                if (bootOverlay) {
                  bootOverlay.hidden = true;
                  bootOverlay.style.display = 'none';
                  bootOverlay.style.pointerEvents = 'none';
                }
                if (appShell) {
                  appShell.hidden = false;
                  appShell.style.display = 'flex';
                  appShell.style.flexDirection = 'column';
                  appShell.style.gap = '16px';
                }
                return true;
              })()
              """
            )
            desktop.setDesktopIdentityProperty(
              "BootScreen.BootOverlay",
              "style",
              %"display:none"
            )
            desktop.setDesktopIdentityProperty(
              "AppShell",
              "style",
              %"display:flex;flex-direction:column;gap:16px"
            )

            if not desktop.mainWebView.isNil:
              gtk_widget_show(desktop.mainWebView)

            return 0

          proc onPlasticWindowSizeAllocated(
            widget: pointer;
            allocation: ptr PlasticGtkAllocation;
            userData: pointer
          ) {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](userData)
            if desktop.isNil or allocation.isNil:
              return
            desktop.width = allocation.width.int
            desktop.height = allocation.height.int
            gtk_widget_set_size_request(
              desktop.mainWebView,
              allocation.width,
              allocation.height
            )


          proc setDesktopIdentityProperty(
            desktop: PlasticLinuxDesktopRuntime;
            path, propertyName: string;
            value: JsonNode
          ) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            let script = """
              (() => {
                const path = """ & $(%path) & """;
                const propertyName = """ & $(%propertyName) & """;
                const value = """ & $value & """;
                const element = Array.from(
                  document.querySelectorAll('[data-glauco-identity]')
                ).find(item => item.dataset.glaucoIdentity === path);
                if (!element) return false;
                if (propertyName === 'textContent' || propertyName === 'innerHTML') {
                  element[propertyName] = typeof value === 'string'
                    ? value
                    : JSON.stringify(value);
                } else {
                  element[propertyName] = value;
                }
                return true;
              })()
            """
            executeNativeJsAsync(desktop.mainWebView, script)

          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            if not desktop.application.assistantValue.isNil:
              acquire(desktop.application.assistantValue.dataLock)
              desktop.application.assistantValue.publishedRevision = -1
              release(desktop.application.assistantValue.dataLock)
            let html = desktop.application.renderApplicationHtml()
            if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
              plasticUiTrace(
                "reloadLinuxDesktop htmlLen=" & $html.len &
                " hasBootCard=" & $(html.contains("GlaucoPlastic / boot")) &
                " hasAppTitle=" & $(html.contains("Consumer YouTube Search")) &
                " hasBootPhasePronto=" & $(html.contains("Pronto")) &
                " hasBootPhaseLoading=" & $(html.contains("Carregando llama-server e modelo"))
              )
            let baseUri = "file://" & getCurrentDir().replace(" ", "%20") & "/"
            webkit_web_view_load_html(
              desktop.mainWebView,
              html.cstring,
              baseUri.cstring
            )

          proc openLinuxDesktop(
            application: PlasticApplication;
            startModel: bool
          ) =
            application.webViewValue.prepareStorage()
            plasticUiTrace(
              "openLinuxDesktop: webview profile=" &
              application.webViewValue.userFolder
            )
            plasticUiTrace("openLinuxDesktop: init gtk")
            if gtk_init_check(nil, nil) == 0:
              plasticUiTrace("gtk_init_check falhou")
              raise newException(
                PlasticRuntimeError,
                "GTK não conseguiu inicializar a sessão gráfica. " &
                "Confirme WAYLAND_DISPLAY/DISPLAY e o pacote webkit2gtk-4.1."
              )
            plasticUiTrace("gtk_init_check ok")

            let desktop = PlasticLinuxDesktopRuntime(
              application: application,
              running: true,
              width: 1180,
              height: 760,
              autoStartModel: startModel
            )
            application.desktopValue = desktop

            # Liga atualizações visuais geradas pelas closures Nim ao WebView.
            # O writer transporta somente path/propriedade/valor serializável.
            let desktopForProperties = desktop
            application.uiPropertyWriterValue =
              proc(path, propertyName: string; value: JsonNode) =
                desktopForProperties.setDesktopIdentityProperty(
                  path,
                  propertyName,
                  value
                )

            if application.webViewValue.persistent:
              desktop.websiteDataManager =
                webkit_website_data_manager_new(
                  "base-data-directory".cstring,
                  application.webViewValue.dataFolder.cstring,
                  "base-cache-directory".cstring,
                  application.webViewValue.cacheFolder.cstring,
                  nil
                )

              if desktop.websiteDataManager.isNil:
                raise newException(
                  PlasticRuntimeError,
                  "WebKitGTK não conseguiu criar o WebsiteDataManager para " &
                  application.webViewValue.userFolder
                )
              plasticUiTrace("websiteDataManager ok")
              desktop.webContext =
                webkit_web_context_new_with_website_data_manager(
                  desktop.websiteDataManager
                )
            else:
              desktop.webContext =
                webkit_web_context_new_ephemeral()

            if desktop.webContext.isNil:
              raise newException(
                PlasticRuntimeError,
                "WebKitGTK não conseguiu criar o WebContext."
              )
            plasticUiTrace("webContext ok")

            if not desktop.websiteDataManager.isNil:
              # Mantém ITP desativado para o perfil de aplicação. O bloqueio de
              # terceiros é controlado explicitamente pelo CookieManager.
              webkit_website_data_manager_set_itp_enabled(
                desktop.websiteDataManager,
                0
              )

            let cookieManager =
              webkit_web_context_get_cookie_manager(
                desktop.webContext
              )

            if not cookieManager.isNil:
              webkit_cookie_manager_set_accept_policy(
                cookieManager,
                if application.webViewValue.acceptThirdPartyCookies:
                  0  # WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS
                else:
                  2  # WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY
              )

              if application.webViewValue.persistent and
                  application.webViewValue.persistentCookies:
                webkit_cookie_manager_set_persistent_storage(
                  cookieManager,
                  application.webViewValue.cookiesPath.cstring,
                  1  # WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE
                )

            desktop.window = gtk_window_new(0)
            desktop.overlay = gtk_overlay_new()
            desktop.fixed = gtk_fixed_new()
            desktop.mainWebView =
              webkit_web_view_new_with_context(
                desktop.webContext
              )

            if desktop.window.isNil or desktop.overlay.isNil or
                desktop.fixed.isNil or desktop.mainWebView.isNil:
              raise newException(
                PlasticRuntimeError,
                "Falha ao criar a janela GTK/WebKitGTK"
              )
            application.webViewValue.initialized = true
            plasticUiTrace("widgets GTK/WebKit criados")

            desktop.bootWidget = gtk_box_new(1, 12)
            desktop.bootTitle = gtk_label_new(nil)
            desktop.bootSpinner = gtk_spinner_new()
            desktop.bootProgress = gtk_progress_bar_new()
            desktop.bootStatus = gtk_label_new(nil)

            if desktop.bootWidget.isNil or desktop.bootTitle.isNil or
                desktop.bootSpinner.isNil or desktop.bootProgress.isNil or
                desktop.bootStatus.isNil:
              raise newException(
                PlasticRuntimeError,
                "Falha ao criar o splash GTK"
              )
            gtk_container_set_border_width(desktop.bootWidget, 24)
            gtk_label_set_markup(
              desktop.bootTitle,
              "<span size='x-large' weight='bold'>Verificando llama-server</span>"
            )
            gtk_label_set_markup(
              desktop.bootStatus,
              "<span foreground='#dde1e6'>Aguardando backend e modelo...</span>"
            )
            gtk_spinner_start(desktop.bootSpinner)
            gtk_progress_bar_set_show_text(desktop.bootProgress, 1)
            gtk_progress_bar_set_fraction(desktop.bootProgress, 0.0)
            gtk_progress_bar_set_text(desktop.bootProgress, "0%")
            desktop.bootVisualProgress = 0
            desktop.bootTraceProgress = -1
            desktop.bootTracePhase = ""
            gtk_box_pack_start(desktop.bootWidget, desktop.bootTitle, 0, 0, 0)
            gtk_box_pack_start(desktop.bootWidget, desktop.bootSpinner, 0, 0, 0)
            gtk_box_pack_start(desktop.bootWidget, desktop.bootProgress, 0, 0, 0)
            gtk_box_pack_start(desktop.bootWidget, desktop.bootStatus, 0, 0, 0)

            gtk_window_set_title(desktop.window, application.productValue.title.cstring)
            gtk_window_set_default_size(desktop.window, desktop.width.cint, desktop.height.cint)
            gtk_container_add(desktop.window, desktop.overlay)
            gtk_container_add(desktop.overlay, desktop.fixed)
            gtk_fixed_put(desktop.fixed, desktop.mainWebView, 0, 0)
            gtk_widget_set_size_request(desktop.mainWebView, desktop.width.cint, desktop.height.cint)
            gtk_fixed_put(desktop.fixed, desktop.bootWidget, 24, 24)
            gtk_widget_show_all(desktop.bootWidget)
            gtk_widget_hide(desktop.mainWebView)
            desktop.geometryTimer = g_timeout_add(
              50,
              syncPlasticForeignGeometry,
              cast[pointer](desktop)
            )

            discard g_signal_connect_data(
              desktop.window,
              "delete-event",
              cast[pointer](onPlasticWindowDeleteEvent),
              cast[pointer](desktop),
              nil,
              0
            )
            discard g_signal_connect_data(
              desktop.window,
              "destroy",
              cast[pointer](onPlasticWindowDestroyed),
              cast[pointer](desktop),
              nil,
              0
            )
            discard g_signal_connect_data(
              desktop.window,
              "unmap",
              cast[pointer](onPlasticWindowUnmapped),
              cast[pointer](desktop),
              nil,
              0
            )
            discard g_signal_connect_data(
              desktop.window,
              "size-allocate",
              cast[pointer](onPlasticWindowSizeAllocated),
              cast[pointer](desktop),
              nil,
              0
            )
            discard g_signal_connect_data(
              desktop.mainWebView,
              "web-process-terminated",
              cast[pointer](onPlasticMainWebProcessTerminated),
              cast[pointer](desktop),
              nil,
              0
            )
            discard g_signal_connect_data(
              desktop.mainWebView,
              "permission-request",
              cast[pointer](onPlasticMainPermissionRequest),
              cast[pointer](desktop),
              nil,
              0
            )

            application.foreignValue.registerBackend(
              newLinuxWebKitForeignBackend(desktop)
            )

            gtk_widget_show_all(desktop.window)
            gtk_window_present(desktop.window)
            openWebKitDeveloperTools(desktop.mainWebView)
            plasticUiTrace("janela apresentada")

            proc onPlasticDesktopStartup(data: pointer): cint {.cdecl.} =
              let desktop = cast[PlasticLinuxDesktopRuntime](data)
              if desktop.isNil or not desktop.running:
                return 0

              let app = desktop.application
              plasticUiTrace("startup callback disparado")
              markLinuxUiReady()
              
              proc onPlasticDesktopModelBootPoll(data: pointer): cint {.cdecl.} =
                let desktop = cast[PlasticLinuxDesktopRuntime](data)
                if desktop.isNil or not desktop.running:
                  return 0

                let state = desktop.llamaBootState
                if state.isNil:
                  return 0

                acquire(state.lock)
                let bootDone = state.done
                let bootFailed = state.failed
                let bootMessage = state.message
                let bootPhase = state.phase
                let bootConnection = state.connection
                let bootModel = state.model
                let bootDetail = state.detail
                let bootProgress = state.progress
                release(state.lock)

                let normalizedBootPhase = bootPhase.toLowerAscii
                let bootTransferActive =
                  normalizedBootPhase.startsWith("baixando ") or
                  normalizedBootPhase.startsWith("download do ")
                let bootReady =
                  bootDone or bootPhase == "Pronto" or
                  (bootProgress >= 100 and not bootTransferActive)

                if not bootReady:
                  if bootTransferActive:
                    desktop.bootVisualProgress = clamp(bootProgress, 0, 100)
                  elif desktop.bootVisualProgress < bootProgress:
                    desktop.bootVisualProgress = bootProgress
                  elif desktop.bootVisualProgress < 96:
                    desktop.bootVisualProgress = min(96, desktop.bootVisualProgress + 2)

                  if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG") and
                      (bootProgress != desktop.bootTraceProgress or
                      bootPhase != desktop.bootTracePhase):
                    desktop.bootTraceProgress = bootProgress
                    desktop.bootTracePhase = bootPhase
                    plasticUiTrace(
                      "boot poll phase=" & bootPhase &
                      " connection=" & bootConnection &
                      " model=" & bootModel &
                      " detail=" & bootDetail &
                      " real=" & $bootProgress &
                      " visual=" & $desktop.bootVisualProgress
                    )

                  if not desktop.bootProgress.isNil:
                    let bootProgressText =
                      (if bootTransferActive: "Download " else: "") &
                      $desktop.bootVisualProgress & "%"
                    gtk_progress_bar_set_fraction(
                      desktop.bootProgress,
                      desktop.bootVisualProgress.float / 100.0
                    )
                    gtk_progress_bar_set_text(desktop.bootProgress, bootProgressText)
                  if not desktop.bootStatus.isNil:
                    let bootStatusText =
                      "<span foreground='#dde1e6'>" &
                      htmlEscape(bootConnection) &
                      " (" &
                      (if bootTransferActive: "download " else: "") &
                      $desktop.bootVisualProgress & "%)</span>"
                    gtk_label_set_markup(
                      desktop.bootStatus,
                      bootStatusText
                    )

                  desktop.application.statesValue.values["BootPhase"] = %(bootPhase)
                  desktop.application.statesValue.values["BootConnection"] = %(bootConnection)
                  desktop.application.statesValue.values["BootModel"] = %(bootModel)
                  desktop.application.statesValue.values["BootDetail"] = %(bootDetail)
                  desktop.application.statesValue.values["BootProgress"] = %($desktop.bootVisualProgress & "%")
                  desktop.application.statesValue.values["BootProgressNumber"] = %(desktop.bootVisualProgress)
                  desktop.application.statesValue.values["BootDownloadActive"] = %(bootTransferActive)

                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootTitle",
                    "textContent",
                    %(bootPhase)
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootStatusValue",
                    "textContent",
                    %(bootConnection)
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootModelValue",
                    "textContent",
                    %(bootModel)
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootHint",
                    "textContent",
                    %(bootDetail)
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootProgressValue",
                    "textContent",
                    %(
                      (if bootTransferActive: "Download " else: "") &
                      $desktop.bootVisualProgress & "%"
                    )
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootFill",
                    "style",
                    %(
                      "height:100%;width:100%;transform-origin:left center;" &
                      "transform:scaleX(" &
                      formatFloat(desktop.bootVisualProgress.float / 100.0, ffDecimal, 2) &
                      ");background:linear-gradient(90deg,#0f62fe 0%,#7aa6ff 100%);" &
                      "border-radius:999px"
                    )
                  )
                  return 1

                plasticUiTrace(
                  "boot poll finalize bootDone=" & $bootDone &
                  " phase=" & bootPhase &
                  " progress=" & $bootProgress
                )
                desktop.bootVisualProgress = 100
                if not desktop.bootProgress.isNil:
                  gtk_progress_bar_set_fraction(desktop.bootProgress, 1.0)
                  gtk_progress_bar_set_text(desktop.bootProgress, "100%")
                if not desktop.bootStatus.isNil:
                  gtk_label_set_markup(
                    desktop.bootStatus,
                    "<span foreground='#dde1e6'>Runtimes prontos. Abrindo a interface.</span>"
                  )

                joinThread(desktop.llamaBootThread)
                desktop.llamaBootState = nil
                desktop.autoStartModel = false
                desktop.bootTraceProgress = 100
                desktop.bootTracePhase = "Pronto"

                let app = desktop.application
                if bootFailed or not app.llamaValue.health():
                  if not desktop.bootTitle.isNil:
                    gtk_label_set_markup(
                      desktop.bootTitle,
                      "<span size='x-large' weight='bold'>Falha ao iniciar os runtimes locais</span>"
                    )
                  if not desktop.bootStatus.isNil:
                    gtk_label_set_markup(
                      desktop.bootStatus,
                      "<span foreground='#ffb3b8'>Falha ao iniciar os runtimes locais.</span>"
                    )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootStatusValue",
                    "textContent",
                    %(
                      if bootMessage.len > 0:
                        "Falha ao iniciar os runtimes locais: " & bootMessage
                      else:
                        "Falha ao iniciar os runtimes locais."
                    )
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootModelValue",
                    "textContent",
                    %(bootModel)
                  )
                  desktop.setDesktopIdentityProperty(
                    "BootScreen.BootHint",
                    "textContent",
                    %(
                      if bootMessage.len > 0:
                        bootMessage
                      else:
                        "O backend não respondeu dentro do tempo limite."
                    )
                  )
                  plasticUiTrace(
                    "startup model falhou: " &
                    (if bootMessage.len > 0: bootMessage else: "erro sem mensagem")
                  )
                  return 0

                desktop.application.statesValue.values["BootPhase"] = %"Pronto"
                desktop.application.statesValue.values["BootConnection"] = %(bootConnection)
                desktop.application.statesValue.values["BootModel"] = %(bootModel)
                desktop.application.statesValue.values["BootDetail"] = %"Backend e memória validados. A interface principal será exibida agora."
                desktop.application.statesValue.values["BootProgress"] = %"100%"
                desktop.application.statesValue.values["BootProgressNumber"] = %100
                desktop.application.statesValue.values["BootDownloadActive"] = %false

                desktop.setDesktopIdentityProperty(
                  "BootScreen.BootStatusValue",
                  "textContent",
                  %"Runtimes prontos. Abrindo a interface."
                )
                desktop.setDesktopIdentityProperty(
                  "BootScreen.BootModelValue",
                  "textContent",
                  %(bootModel)
                )
                desktop.setDesktopIdentityProperty(
                  "BootScreen.BootHint",
                  "textContent",
                  %"Backend e memória validados. A interface principal será exibida agora."
                )
                if not desktop.bootStatus.isNil:
                  desktop.bootVisualProgress = 100
                  gtk_progress_bar_set_fraction(desktop.bootProgress, 1.0)
                  gtk_progress_bar_set_text(desktop.bootProgress, "100%")
                  gtk_label_set_markup(
                    desktop.bootStatus,
                    "<span foreground='#dde1e6'>Runtimes prontos. Abrindo a interface.</span>"
                  )
                discard g_timeout_add(
                  0,
                  onPlasticBootFinalizeActivateDesktop,
                  cast[pointer](desktop)
                )
                return 0

              proc startDesktopLlamaBoot(desktop: PlasticLinuxDesktopRuntime) =
                if desktop.isNil or not desktop.running:
                  return

                let app = desktop.application
                plasticUiTrace(
                  "startup: boot gate autoStart=" & $desktop.autoStartModel &
                  " agents=" & $app.agentsValue.len &
                  " bootStateNil=" & $(desktop.llamaBootState.isNil)
                )
                let assistantRequired =
                  not app.assistantValue.isNil and
                  app.assistantValue.config.enabled
                if desktop.autoStartModel and
                    (app.agentsValue.len > 0 or assistantRequired) and
                    desktop.llamaBootState.isNil:
                  desktop.llamaBootState = newLlamaBootState(
                    "Carregando runtimes locais..."
                  )
                  desktop.llamaBootState.llama = app.llamaValue
                  desktop.llamaBootState.metis = app.metisMemoryValue
                  desktop.llamaBootState.setLlamaBootProgress(
                    "Carregando runtimes locais...",
                    0
                  )
                  desktop.bootVisualProgress = 0
                  desktop.bootTraceProgress = 0
                  desktop.bootTracePhase = "Carregando runtimes locais..."
                  desktop.application.statesValue.values["BootPhase"] = %"Carregando runtimes locais..."
                  desktop.application.statesValue.values["BootConnection"] = %"Verificando llama-server..."
                  desktop.application.statesValue.values["BootModel"] = %"Validando Gemma GGUF e Metis..."
                  desktop.application.statesValue.values["BootDetail"] = %"Checando llama.cpp, Python 3.10 e modelos locais..."
                  desktop.application.statesValue.values["BootProgress"] = %"0%"
                  desktop.application.statesValue.values["BootProgressNumber"] = %0
                  desktop.application.statesValue.values["BootDownloadActive"] = %false
                  if not desktop.bootStatus.isNil:
                    gtk_label_set_markup(
                      desktop.bootStatus,
                      "<span foreground='#dde1e6'>Carregando runtimes locais...</span>"
                    )
                  if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                    plasticUiTrace("boot start phase=Carregando runtimes locais... real=0 visual=0")
                  createThread(
                    desktop.llamaBootThread,
                    runLlamaBootWorker,
                    desktop.llamaBootState
                  )
                  desktop.llamaBootTimer = g_timeout_add(
                    50,
                    onPlasticDesktopModelBootPoll,
                    cast[pointer](desktop)
                  )
                  discard onPlasticDesktopModelBootPoll(cast[pointer](desktop))
                elif not desktop.mainWebView.isNil:
                  plasticUiTrace("startup: boot gate skipped, showing mainWebView")
                  if not desktop.bootWidget.isNil:
                    gtk_widget_hide(desktop.bootWidget)
                  gtk_widget_show(desktop.mainWebView)

              if plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_STARTUP_PROGRAM"):
                plasticUiTrace("startup program desativado")
                plasticUiTrace(
                  "startup: before reload/start boot autoStart=" &
                  $desktop.autoStartModel &
                  " agents=" & $app.agentsValue.len
                )
                desktop.reloadLinuxDesktop()
                startDesktopLlamaBoot(desktop)
                plasticUiTrace("startup: after start boot")
              else:
                plasticUiTrace(
                  "startup: before executeProgram autoStart=" &
                  $desktop.autoStartModel &
                  " agents=" & $app.agentsValue.len
                )
                let previousUiWriter = app.uiPropertyWriterValue
                app.uiPropertyWriterValue = nil
                try:
                  app.executeProgram()
                finally:
                  app.uiPropertyWriterValue = previousUiWriter
                plasticUiTrace("startup: after executeProgram")
                desktop.reloadLinuxDesktop()
                plasticUiTrace("startup: after reload")

                for path in app.foreignValue.elements.keys.toSeq.sorted:
                  app.foreignValue.create(path)
                plasticUiTrace("startup: after foreign create")
                startDesktopLlamaBoot(desktop)
                plasticUiTrace("startup: after start boot")
              plasticUiTrace("startup callback concluido")
              return 0

            discard g_timeout_add(
              1,
              onPlasticDesktopStartup,
              cast[pointer](desktop)
            )

            discard g_timeout_add(
              50,
              onPlasticInitialRender,
              cast[pointer](desktop)
            )

            if plasticEnvEnabled("GLAUCOPLASTIC_CONSOLE_REPL") or
                plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
              desktop.consoleReplState = newPlasticConsoleReplState(desktop)
              createThread(
                desktop.consoleReplThread,
                runPlasticConsoleReplWorker,
                desktop.consoleReplState
              )
              desktop.consoleReplTimer = g_timeout_add(
                80,
                drainPlasticConsoleRepl,
                cast[pointer](desktop)
              )

            for stateName in application.statesValue.values.keys.toSeq:
              application.statesValue.onChanged(
                stateName,
                proc(change: PlasticStateChange) =
                  if desktop.running:
                    desktop.reloadLinuxDesktop()
              )

            plasticUiTrace("gtk_main: entering")
            gtk_main()
            plasticUiTrace("gtk_main: exited")
            desktop.running = false

            if not desktop.webContext.isNil:
              g_object_unref(desktop.webContext)
              desktop.webContext = nil

            if not desktop.websiteDataManager.isNil:
              g_object_unref(desktop.websiteDataManager)
              desktop.websiteDataManager = nil

            application.webViewValue.initialized = false

        proc runtimeSummary*(application: PlasticApplication): JsonNode =
          result = newJObject()

          result["application"] = %*{
            "name": application.nameValue,
            "title": application.productValue.title,
            "version": application.productValue.version,
            "running": application.runningValue,
            "programExecuted": application.startupExecutedValue,
            "programBlocks": application.startupActionsValue.len
          }

          result["states"] = application.statesValue.snapshot()

          result["orm"] = %*{
            "path": application.ormValue.path,
            "schema": application.ormValue.schema,
            "entities": application.ormValue.data
          }

          result["okf"] = %*{
            "rootPath": application.okfValue.rootPath,
            "indexPath": application.okfValue.indexPath,
            "spaces": application.okfValue.spaces,
            "items": application.okfValue.list()
          }

          result["metisMemory"] = application.metisMemoryValue.statusJson()
          result["assistant"] =
            if application.assistantValue.isNil:
              newJNull()
            else:
              plasticAssistantSnapshot(application.assistantValue)

          result["foreign"] = application.foreignValue.list()
          result["webview"] = application.webViewValue.describe()

          result["llama"] = %*{
            "endpoint": application.llamaValue.endpoint,
            "executablePath": application.llamaValue.executablePath,
            "modelPath": application.llamaValue.modelPath,
            "contextSize": application.llamaValue.config.contextSize,
            "maxTokens": application.llamaValue.config.maxTokens,
            "logResponseBody": application.llamaValue.config.logResponseBody,
            "running": application.llamaValue.running()
          }

          result["rlmCapabilities"] = newJArray()
          for capabilityName in application.rlmValue.capabilities.keys.toSeq.sorted:
            result["rlmCapabilities"].add %capabilityName

          result["agents"] = newJArray()
          for agentName in application.agentsValue.keys.toSeq.sorted:
            let agent = application.agentsValue[agentName]
            result["agents"].add %*{
              "name": agentName,
              "constructor": agent.constructorName,
              "purpose": agent.purpose
            }

          result["frontend"] = %*{
            "components": application.componentsValue.len,
            "renderNodes": application.renderTreeValue.len,
            "htmlLength": application.renderApplicationHtml().len
          }

        proc ensurePersistentLayout(application: PlasticApplication) =
          var paths = initHashSet[string]()

          for relativePath in application.installationValue.config.dataDirectories:
            let path = application.installationValue.dataRoot / relativePath
            if path.len > 0:
              paths.incl path

          if application.okfValue.spaces.kind == JObject:
            for spaceName, _ in application.okfValue.spaces.pairs:
              if spaceName.len > 0:
                paths.incl application.okfValue.rootPath / spaceName

          if application.webViewValue.persistent:
            paths.incl application.webViewValue.userFolder
            paths.incl application.webViewValue.dataFolder
            paths.incl application.webViewValue.cacheFolder

          for path in paths.items:
            createDir(path)

        proc validateInstallation*(application: PlasticApplication) =
          application.ensurePersistentLayout()
          application.metisMemoryValue.ensureMetisPaths()
          application.okfValue.validate()
          application.okfValue.saveSpaces()

        proc prepareExecutionEnvironment(application: PlasticApplication) =
          let hasWayland = getEnv("WAYLAND_DISPLAY").len > 0
          let hasX11 = getEnv("DISPLAY").len > 0
          let explicitBackend =
            getEnv("GLAUCOPLASTIC_GDK_BACKEND").strip
          let inheritedBackend =
            getEnv("GDK_BACKEND").strip
          let problematicWaylandEnvironment =
            isWlrootsDesktop() or hasNvidiaDriver()

          proc applySafeLinuxGraphicsEnvironment(backend: string) =
            if backend.len == 0:
              return

            putEnv("GLAUCOPLASTIC_GDK_BACKEND", backend)
            putEnv("GDK_BACKEND", backend)

            if backend == "x11":
              if getEnv("DISPLAY").len == 0:
                putEnv("DISPLAY", ":0")
              delEnv("WAYLAND_DISPLAY")
              putEnv("XDG_SESSION_TYPE", "x11")
            elif backend == "wayland":
              putEnv("XDG_SESSION_TYPE", "wayland")

            if application.webViewValue.safeGraphics or
                backend == "x11" or problematicWaylandEnvironment:
              putEnv("GLAUCOPLASTIC_DISABLE_DMABUF", "1")
              putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
              putEnv("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
              putEnv("LIBGL_ALWAYS_SOFTWARE", "1")

          if explicitBackend.len > 0:
            applySafeLinuxGraphicsEnvironment(explicitBackend)
          elif inheritedBackend.len > 0:
            applySafeLinuxGraphicsEnvironment(inheritedBackend)
          else:
            var selectedBackend = ""
            if hasX11:
              selectedBackend = "x11"
            elif hasWayland:
              selectedBackend = "wayland"

            if selectedBackend.len > 0:
              applySafeLinuxGraphicsEnvironment(selectedBackend)

          if application.webViewValue.safeGraphics:
            putEnv("GLAUCOPLASTIC_DISABLE_DMABUF", "1")
            putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
            putEnv("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
            putEnv("LIBGL_ALWAYS_SOFTWARE", "1")

        proc prepareDevelopmentLayout*(application: PlasticApplication) =
          ## Compatibilidade com projetos antigos. O framework prepara o layout
          ## automaticamente durante validateInstallation() e run().
          application.ensurePersistentLayout()

        proc registerForeignBackend*(application: PlasticApplication; backend: PlasticForeignBackend) =
          application.foreignValue.registerBackend(backend)

        proc initializeTechnologies*(
          application: PlasticApplication;
          startModel = false
        ): JsonNode =
          ## Todas as tecnologias já foram instanciadas por newPlasticApplication.
          ## A programação livre declarada no corpo do macro é aplicada uma única vez.
          application.executeProgram()
          application.webViewValue.prepareStorage()

          discard application.statesValue.snapshot()
          discard application.ormValue.schema
          discard application.okfValue.spaces
          discard application.foreignValue.list()
          discard application.componentsValue
          discard application.renderTreeValue

          if startModel and
              (application.agentsValue.len > 0 or
               (not application.assistantValue.isNil and
                application.assistantValue.config.enabled)):
            application.llamaValue.start()
            if application.metisMemoryValue.config.enabled and
                application.metisMemoryValue.config.startup:
              application.metisMemoryValue.ensureInitialized(
                application.llamaValue
              )

          result = application.runtimeSummary()

        proc serveNetworkWeb*(
          application: PlasticApplication;
          startModel: bool;
          host: string;
          port: int
        ) =
          application.webViewValue.prepareStorage()

          if not plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_STARTUP_PROGRAM"):
            application.executeProgram()

          let assistantModelRequired =
            not application.assistantValue.isNil and
            application.assistantValue.config.enabled

          if startModel and
              (application.agentsValue.len > 0 or assistantModelRequired):
            application.llamaValue.start()
            if application.metisMemoryValue.config.enabled and
                application.metisMemoryValue.config.startup:
              application.metisMemoryValue.ensureInitialized(application.llamaValue)

          if application.foreignValue.backend.isNil:
            application.foreignValue.registerBackend(newMockForeignBackend())

          for path in application.foreignValue.elements.keys:
            application.foreignValue.create(path)

          if not application.assistantValue.isNil and
              application.assistantValue.config.enabled and
              not application.assistantValue.started:
            application.assistantValue.start()

          var propertyLock: Lock
          initLock(propertyLock)
          var propertyUpdates: seq[JsonNode] = @[]
          let webApplication = application

          application.uiPropertyWriterValue =
            proc(path, propertyName: string; value: JsonNode) =
              let update = %*{
                "path": path,
                "property": propertyName,
                "value": if value.isNil: newJNull() else: value.copy
              }
              acquire(propertyLock)
              propertyUpdates.add update
              release(propertyLock)

          let renderHtml: PlasticNetworkWebRenderProc =
            proc(): string =
              webApplication.renderApplicationHtml()

          let dispatchEvent: PlasticNetworkWebEventProc =
            proc(event: JsonNode) =
              if event.kind != JObject:
                return

              let eventValue =
                if event.hasKey("value") and event["value"].kind != JNull:
                  event["value"].copy
                elif event.hasKey("checked") and event["checked"].kind != JNull:
                  event["checked"].copy
                else:
                  newJNull()

              let bindState = `jsonStringFieldSym`(event, "bindState")
              if bindState.len > 0 and webApplication.statesValue.exists(bindState):
                `stateSetInternalSym`(
                  webApplication.statesValue,
                  bindState,
                  eventValue
                )

              webApplication.dispatchUiEvent(event)

          let pollState: PlasticNetworkWebPollProc =
            proc(): JsonNode =
              result = %*{"ok": true, "properties": newJArray()}

              acquire(propertyLock)
              for update in propertyUpdates:
                result["properties"].add update.copy
              propertyUpdates.setLen(0)
              release(propertyLock)

              if not webApplication.assistantValue.isNil and
                  webApplication.assistantValue.config.enabled:
                result["assistant"] =
                  plasticAssistantSnapshot(webApplication.assistantValue)

          try:
            runPlasticNetworkWebServer(
              host,
              port,
              renderHtml,
              dispatchEvent,
              pollState
            )
          finally:
            application.uiPropertyWriterValue = nil
            deinitLock(propertyLock)
            application.assistantValue.stop()
            application.metisMemoryValue.stop()
            application.llamaValue.stop()
            application.runningValue = false

        proc run*(application: PlasticApplication; startModel = true) =
          plasticUiTrace("run: begin")
          application.validateInstallation()
          plasticUiTrace("run: validateInstallation ok")
          application.prepareExecutionEnvironment()
          var headlessFallback = plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_UI_LAUNCHER")
          let useUiLauncher = plasticEnvEnabled("GLAUCOPLASTIC_USE_UI_LAUNCHER")
          let modelStartupDisabled =
            plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_MODEL_STARTUP")
          let assistantModelRequired =
            not application.assistantValue.isNil and
            application.assistantValue.config.enabled
          let autoStartModel =
            (startModel or application.agentsValue.len > 0 or
             assistantModelRequired) and
            not modelStartupDisabled

          let networkWeb = plasticNetworkWebOptions(commandLineParams())
          if networkWeb.enabled:
            application.runningValue = true
            application.serveNetworkWeb(
              autoStartModel,
              networkWeb.host,
              networkWeb.port
            )
            return

          when defined(linux) and not defined(glaucoplasticHeadless):
            if useUiLauncher and not isPlasticLinuxUiChild() and not headlessFallback:
              try:
                let exitCode = launchLinuxDesktopChild()
                if exitCode == 0:
                  return
                headlessFallback = true
              except PlasticRuntimeError:
                headlessFallback = true

          application.runningValue = true


          when defined(linux) and not defined(glaucoplasticHeadless):
            if headlessFallback:
              plasticUiTrace("run: headlessFallback")
              if not plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_STARTUP_PROGRAM"):
                application.executeProgram()
              if autoStartModel and
                  (application.agentsValue.len > 0 or assistantModelRequired):
                application.llamaValue.start()
                if application.metisMemoryValue.config.enabled and
                    application.metisMemoryValue.config.startup:
                  application.metisMemoryValue.ensureInitialized(
                    application.llamaValue
                  )
              if application.foreignValue.backend.isNil:
                application.foreignValue.registerBackend(newMockForeignBackend())
              for path in application.foreignValue.elements.keys:
                application.foreignValue.create(path)
                application.llamaValue.stop()
                application.runningValue = false
            else:
              try:
                plasticUiTrace("run: openLinuxDesktop")
                application.openLinuxDesktop(autoStartModel)
              except PlasticRuntimeError:
                if autoStartModel and
                  (application.agentsValue.len > 0 or assistantModelRequired):
                  application.llamaValue.start()
                  if application.metisMemoryValue.config.enabled and
                      application.metisMemoryValue.config.startup:
                    application.metisMemoryValue.ensureInitialized(
                      application.llamaValue
                    )
                if application.foreignValue.backend.isNil:
                  application.foreignValue.registerBackend(newMockForeignBackend())
                for path in application.foreignValue.elements.keys:
                  application.foreignValue.create(path)
              finally:
                application.assistantValue.stop()
                application.metisMemoryValue.stop()
                application.llamaValue.stop()
                application.runningValue = false
          else:
            plasticUiTrace("run: no linux UI branch")
            if not plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_STARTUP_PROGRAM"):
              application.executeProgram()
            if autoStartModel and
                  (application.agentsValue.len > 0 or assistantModelRequired):
              application.llamaValue.start()
              if application.metisMemoryValue.config.enabled and
                  application.metisMemoryValue.config.startup:
                application.metisMemoryValue.ensureInitialized(
                  application.llamaValue
                )
            if application.foreignValue.backend.isNil:
              application.foreignValue.registerBackend(newMockForeignBackend())
            for path in application.foreignValue.elements.keys:
              application.foreignValue.create(path)

        proc close*(application: PlasticApplication) =
          if application.isNil:
            return
          when defined(linux):
            if not application.desktopValue.isNil and application.desktopValue.running:
              let desktop = cast[PlasticLinuxDesktopRuntime](application.desktopValue)
              closeWebKitDeveloperTools(desktop.mainWebView)
              application.desktopValue.running = false
              gtk_main_quit()
          for path in application.foreignValue.elements.keys.toSeq:
            try:
              application.foreignValue.close(path)
            except PlasticForeignBackendError:
              discard
          application.assistantValue.stop()
          application.metisMemoryValue.stop()
          application.llamaValue.stop()
          application.runningValue = false

        proc destroy*(application: PlasticApplication) =
          application.close()
          discard

        proc installerManifest*(application: PlasticApplication): JsonNode =
          let config = application.installationValue.config
          result = %*{
            "product_name": config.productName,
            "manufacturer": config.manufacturer,
            "version": config.version,
            "upgrade_code": config.upgradeCode,
            "scope": if config.scope == pisPerUser: "perUser" else: "perMachine",
            "executable": config.executableName,
            "icon": config.iconPath,
            "install_directory": {
              "root": config.installRootName,
              "path": config.installRelativePath
            },
            "application_data": {
              "root": config.dataRootName,
              "path": config.dataRelativePath,
              "directories": config.dataDirectories
            },
            "assets": newJArray(),
            "shortcuts": {
              "desktop": config.desktopShortcut,
              "start_menu": config.startMenuShortcut
            }
          }

          let okfSection = findPlanSection(application.planValue, "okfs")
          if okfSection.isSome:
            for spaceNode in planChildren(okfSection.get):
              let spaceName = planName(spaceNode)
              if spaceName.len > 0:
                let relativePath = "okf" / spaceName
                var found = false
                for existing in result["application_data"]["directories"].items:
                  if existing.kind == JString and existing.getStr == relativePath:
                    found = true
                    break
                if not found:
                  result["application_data"]["directories"].add %relativePath

          for assetNode in config.assets:
            let arguments = planArguments(assetNode)
            if arguments.len == 0:
              continue
            let sourceValue = literalOrNull(arguments[0])
            if sourceValue.kind != JString:
              continue

            let destinationArgument =
              if planName(assetNode) in ["glob", "includeGlob"]:
                let preferred = callNamedArgument(assetNode, "destination")
                if preferred.isSome: preferred else: callNamedArgument(assetNode, "into")
              else:
                let preferred = callNamedArgument(assetNode, "destination")
                if preferred.isSome: preferred else: callNamedArgument(assetNode, "as")

            let destination =
              if destinationArgument.isSome:
                let value = literalOrNull(destinationArgument.get)
                if value.kind == JString: value.getStr else: ""
              else:
                ""

            result["assets"].add %*{
              "kind": if planName(assetNode) in ["glob", "includeGlob"]: "glob" else: "file",
              "source": sourceValue.getStr,
              "destination": destination
            }

        proc writeInstallerManifest*(application: PlasticApplication; outputPath: string) =
          writeJsonFile(outputPath, application.installerManifest())
      result.add newCall(ident("appendPlasticPlanSection"), applicationVariable.copyNimTree, newLit($astToPlanJson(section)))
      result.add quote do:
        `applicationVariable`.renderTreeValue =
          deriveRenderTree(`applicationVariable`.planValue)
      continue

    if section.kind in {nnkCall, nnkCommand} and section[0].eqIdent("startup"):
      for statement in section[^1]:
        program.add statement.copyNimTree
      continue

    program.add section.copyNimTree

  if program.len > 0:
    for statement in program:
      result.add quote do:
        `applicationVariable`.registerProgram(
          proc() =
            `statement`
        )
