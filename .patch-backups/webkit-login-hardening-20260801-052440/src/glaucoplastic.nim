## GlaucoPlastic
## Framework monolítico funcional: parser da DSL, planos, runtimes,
## frontend WebKitGTK/WebView, ORM, OKF, memória Git, llama.cpp, RLM,
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

import std/[
  algorithm,
  httpclient,
  json,
  macros,
  options,
  os,
  osproc,
  sequtils,
  sets,
  strformat,
  strutils,
  tables,
  times
]

# -----------------------------------------------------------------------------
# Erros e utilidades gerais
# -----------------------------------------------------------------------------

type
  PlasticError* = object of CatchableError
  PlasticInstallationError* = object of PlasticError
  PlasticRuntimeError* = object of PlasticError
  PlasticForeignBackendError* = object of PlasticError
  PlasticAgentError* = object of PlasticError

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

proc jsonString(node: JsonNode; key: string; fallback = ""): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else:
    fallback

proc jsonBool(node: JsonNode; key: string; fallback = false): bool =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
    node[key].getBool
  else:
    fallback

proc jsonInt(node: JsonNode; key: string; fallback = 0): int =
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

# -----------------------------------------------------------------------------
# Plano serializado produzido pelo macro
# -----------------------------------------------------------------------------

type
  PlasticPlan* = ref object
    root*: JsonNode

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
  jsonString(node, "name")

proc planKind(node: JsonNode): string =
  jsonString(node, "kind")

proc planSource(node: JsonNode): string =
  jsonString(node, "source")

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

# -----------------------------------------------------------------------------
# Produto e instalação
# -----------------------------------------------------------------------------

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
    gitMemoryPath*: string
    sessionPath*: string
    ormPath*: string

proc defaultProductConfig(applicationName: string): PlasticProductConfig =
  PlasticProductConfig(
    title: applicationName,
    description: "",
    version: "0.1.0"
  )

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
      "webview/Default",
      "webview/Default/data",
      "webview/Default/cache"
    ],
    desktopShortcut: true,
    startMenuShortcut: true
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

proc callNamedArgument(node: JsonNode; argumentName: string): Option[JsonNode] =
  for argument in planArguments(node):
    if planKind(argument) == "namedArgument" and planName(argument) == argumentName:
      if argument.hasKey("value"):
        return some(argument["value"])
  none(JsonNode)

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
    gitMemoryPath: dataRoot / ".glauco" / "memory",
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

# -----------------------------------------------------------------------------
# Runtime de estados
# -----------------------------------------------------------------------------

type
  PlasticStateChange* = object
    name*: string
    previousValue*: JsonNode
    currentValue*: JsonNode
    changedAt*: DateTime

  PlasticStateListener* = proc(change: PlasticStateChange) {.closure.}

  PlasticStateRuntime* = ref object
    values*: Table[string, JsonNode]
    listeners*: Table[string, seq[PlasticStateListener]]
    descriptors*: JsonNode

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
  if not states.values.hasKey(name):
    raise newException(PlasticRuntimeError, "Estado inexistente: " & name)
  states.values[name]

proc set*(states: PlasticStateRuntime; name: string; value: JsonNode) =
  let previous =
    if states.values.hasKey(name): states.values[name].copy
    else: newJNull()

  states.values[name] = value.copy
  if previous == value:
    return

  let change = PlasticStateChange(
    name: name,
    previousValue: previous,
    currentValue: value.copy,
    changedAt: now()
  )

  if states.listeners.hasKey(name):
    for listener in states.listeners[name]:
      listener(change)

proc onChanged*(states: PlasticStateRuntime; name: string; listener: PlasticStateListener) =
  states.listeners.mgetOrPut(name, @[]).add listener

proc snapshot*(states: PlasticStateRuntime): JsonNode =
  result = newJObject()
  for key, value in states.values:
    result[key] = value.copy

proc literalOrNull(node: JsonNode): JsonNode =
  if node.kind == JObject and node.hasKey("literal"):
    return node["literal"].copy
  newJNull()

proc planValueOrName(node: JsonNode): JsonNode =
  ## Converte argumentos simples da DSL em valores de runtime. Literais são
  ## preservados; identificadores como `part = Documentacao` tornam-se strings.
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

proc constructorValue(node: JsonNode): JsonNode =
  result = newJObject()
  for child in planChildren(node):
    if planKind(child) == "call":
      let arguments = planArguments(child)
      if arguments.len > 0:
        result[planName(child)] = literalOrNull(arguments[0])

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
          states.define(stateName, literalOrNull(value))
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

      states.define(stateName, initial)

# -----------------------------------------------------------------------------
# ORM persistente em JSON
# -----------------------------------------------------------------------------

type
  PlasticOrmRuntime* = ref object
    path*: string
    data*: JsonNode
    schema*: JsonNode

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

proc all*(orm: PlasticOrmRuntime; entity: string): JsonNode =
  ensureEntity(orm, entity).copy

proc count*(orm: PlasticOrmRuntime; entity: string): int =
  ensureEntity(orm, entity).len

proc nextId(rows: JsonNode): int =
  result = 1
  for row in rows.items:
    if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt:
      result = max(result, row["id"].getInt + 1)

proc insert*(orm: PlasticOrmRuntime; entity: string; value: JsonNode): JsonNode =
  if value.kind != JObject:
    raise newException(PlasticRuntimeError, "ORM insert espera objeto JSON")

  let rows = ensureEntity(orm, entity)
  result = value.copy
  if not result.hasKey("id") or result["id"].kind == JNull:
    result["id"] = %nextId(rows)
  rows.add result.copy
  orm.save()

proc find*(orm: PlasticOrmRuntime; entity: string; id: int): JsonNode =
  for row in ensureEntity(orm, entity).items:
    if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
      return row.copy
  newJNull()

proc whereEq*(orm: PlasticOrmRuntime; entity, field: string; expected: JsonNode): JsonNode =
  result = newJArray()
  for row in ensureEntity(orm, entity).items:
    if row.kind == JObject and row.hasKey(field) and row[field] == expected:
      result.add row.copy

proc update*(orm: PlasticOrmRuntime; entity: string; id: int; patch: JsonNode): JsonNode =
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

proc delete*(orm: PlasticOrmRuntime; entity: string; id: int): bool =
  let rows = ensureEntity(orm, entity)
  for index in 0 ..< rows.len:
    let row = rows[index]
    if row.kind == JObject and row.hasKey("id") and row["id"].kind == JInt and row["id"].getInt == id:
      rows.elems.delete(index)
      orm.save()
      return true
  false

# -----------------------------------------------------------------------------
# OKF
# -----------------------------------------------------------------------------

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

type
  PlasticOkfRuntime* = ref object
    rootPath*: string
    indexPath*: string
    index*: JsonNode
    spaces*: JsonNode

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

proc list*(okf: PlasticOkfRuntime; space = ""): JsonNode =
  result = newJArray()
  if okf.index.kind != JObject or not okf.index.hasKey("items"):
    return

  for item in okf.index["items"].items:
    if space.len == 0 or jsonString(item, "space") == space:
      result.add item.copy

proc get*(okf: PlasticOkfRuntime; id: string): JsonNode =
  for item in okf.list().items:
    if jsonString(item, "id") == id:
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
    if jsonString(items[index], "id") == jsonString(result, "id"):
      items.elems[index] = result.copy
      replaced = true
      break

  if not replaced:
    items.add result.copy

  okf.save()

  let spaceName = jsonString(result, "space", "default")
  let spacePath = okf.rootPath / spaceName
  if not dirExists(spacePath):
    raise newException(
      PlasticInstallationError,
      "Espaço OKF ausente. Ele deve ser criado pelo MSI: " & spacePath
    )
  writeJsonFile(spacePath / (jsonString(result, "id") & ".json"), result)

proc tree*(okf: PlasticOkfRuntime): JsonNode =
  result = newJObject()
  for item in okf.list().items:
    let space = jsonString(item, "space", "default")
    if not result.hasKey(space):
      result[space] = newJArray()
    result[space].add %*{
      "id": jsonString(item, "id"),
      "title": jsonString(item, "title")
    }

# -----------------------------------------------------------------------------
# Memória Git
# -----------------------------------------------------------------------------

type
  PlasticGitSnapshot* = object
    head*: string
    branch*: string
    status*: string
    workingDiff*: string
    stagedDiff*: string
    capturedAt*: DateTime

  PlasticGitMemory* = ref object
    repositoryPath*: string
    memoryPath*: string
    lastSnapshot*: PlasticGitSnapshot

proc gitOutput(repositoryPath, arguments: string): string =
  let command = "git -C " & quoteShellArgument(repositoryPath) & " " & arguments
  let execution = commandResult(command)
  if execution.exitCode == 0:
    execution.output.strip
  else:
    ""

proc capture*(memory: PlasticGitMemory): PlasticGitSnapshot =
  result = PlasticGitSnapshot(
    head: gitOutput(memory.repositoryPath, "rev-parse HEAD"),
    branch: gitOutput(memory.repositoryPath, "branch --show-current"),
    status: gitOutput(memory.repositoryPath, "status --short"),
    workingDiff: gitOutput(memory.repositoryPath, "diff --no-ext-diff"),
    stagedDiff: gitOutput(memory.repositoryPath, "diff --cached --no-ext-diff"),
    capturedAt: now()
  )
  memory.lastSnapshot = result

proc snapshotJson*(snapshot: PlasticGitSnapshot): JsonNode =
  %*{
    "head": snapshot.head,
    "branch": snapshot.branch,
    "status": snapshot.status,
    "workingDiff": snapshot.workingDiff,
    "stagedDiff": snapshot.stagedDiff,
    "capturedAt": snapshot.capturedAt.format("yyyy-MM-dd'T'HH:mm:sszzz")
  }

proc writeMemo*(memory: PlasticGitMemory; name: string; content: JsonNode): string =
  if not dirExists(memory.memoryPath):
    raise newException(
      PlasticInstallationError,
      "Pasta de memória Git ausente: " & memory.memoryPath
    )
  result = memory.memoryPath / (name & ".json")
  writeJsonFile(result, content)

# -----------------------------------------------------------------------------
# WebContentsView foreign
# -----------------------------------------------------------------------------

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
    partName*: string
    url*: string
    urlStateName*: string
    status*: PlasticForeignStatus
    statusCss*: Table[string, string]
    documentStartScripts*: seq[string]
    eventPlans*: JsonNode
    currentUrl*: string
    lastMessage*: JsonNode
    lastError*: JsonNode
    nativeHandle*: pointer
    desktopOwner*: pointer
    eventHandler*: PlasticForeignEventProc
  PlasticForeignCreateProc* = proc(element: PlasticForeignElementRuntime) 
  PlasticForeignNavigateProc* = proc(element: PlasticForeignElementRuntime; url: string) 
  PlasticForeignEvalJsProc* = proc(element: PlasticForeignElementRuntime; script: string; timeoutMs: int): JsonNode 
  PlasticForeignInjectProc* = proc(element: PlasticForeignElementRuntime; script: string) 
  PlasticForeignCloseProc* = proc(element: PlasticForeignElementRuntime) 

  PlasticForeignBackend* = ref object
    name*: string
    create*: PlasticForeignCreateProc
    navigate*: PlasticForeignNavigateProc
    evalJs*: PlasticForeignEvalJsProc
    injectDocumentStart*: PlasticForeignInjectProc
    close*: PlasticForeignCloseProc

  PlasticForeignRuntime* = ref object
    backend*: PlasticForeignBackend
    elements*: Table[string, PlasticForeignElementRuntime]
    onUrlChanged*: PlasticForeignUrlChangedProc
    onEvent*: PlasticForeignEventProc

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
    partName: "",
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
    "partName": element.partName,
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
  result.close = proc(element: PlasticForeignElementRuntime) =
    element.status = pfsClosed

# -----------------------------------------------------------------------------
# llama.cpp local
# -----------------------------------------------------------------------------

type
  PlasticLlamaConfig* = object
    host*: string
    port*: int
    modelAlias*: string
    contextSize*: int
    gpuLayers*: int
    temperature*: float
    maxTokens*: int

  PlasticLlamaRuntime* = ref object
    config*: PlasticLlamaConfig
    executablePath*: string
    modelPath*: string
    process*: Process
    endpoint*: string

proc defaultLlamaConfig*(): PlasticLlamaConfig =
  PlasticLlamaConfig(
    host: getEnv("GLAUCOPLASTIC_LLAMA_HOST", "127.0.0.1"),
    port: parseInt(getEnv("GLAUCOPLASTIC_LLAMA_PORT", "1223")),
    modelAlias: getEnv("GLAUCOPLASTIC_MODEL_ALIAS", "qwen3-4b"),
    contextSize: parseInt(getEnv("GLAUCOPLASTIC_CONTEXT_SIZE", "8192")),
    gpuLayers: parseInt(getEnv("GLAUCOPLASTIC_GPU_LAYERS", "-1")),
    temperature: parseFloat(getEnv("GLAUCOPLASTIC_TEMPERATURE", "0.1")),
    maxTokens: parseInt(getEnv("GLAUCOPLASTIC_MAX_TOKENS", "2048"))
  )

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
    getHomeDir() / "models" / "Qwen3-4B" / "Qwen3-4B-Q4_K_M.gguf",
    getAppDir() / "models" / "Qwen3-4B-Q4_K_M.gguf",
    getCurrentDir() / "models" / "Qwen3-4B-Q4_K_M.gguf",
    getAppDir() / "models" / "gemma-4-E4B-it-Q4_K_M.gguf",
    getCurrentDir() / "models" / "gemma-4-E4B-it-Q4_K_M.gguf"
  ]

proc firstExistingFile(candidates: seq[string]): string =
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  ""

proc newLlamaRuntime*(config = defaultLlamaConfig()): PlasticLlamaRuntime =
  PlasticLlamaRuntime(
    config: config,
    executablePath: firstExistingFile(platformLlamaCandidates()),
    modelPath: firstExistingFile(defaultModelCandidates()),
    endpoint: "http://" & config.host & ":" & $config.port & "/v1"
  )

proc validateAssets*(llama: PlasticLlamaRuntime) =
  if llama.executablePath.len == 0 or not fileExists(llama.executablePath):
    raise newException(
      PlasticInstallationError,
      "llama-server ausente. Execute o instalador de runtime da plataforma."
    )
  if llama.modelPath.len == 0 or not fileExists(llama.modelPath):
    raise newException(
      PlasticInstallationError,
      "Modelo GGUF ausente. Defina GLAUCOPLASTIC_MODEL_PATH ou execute scripts/configure-qwen3-model.sh."
    )

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
  let arguments = @[
    "--model", llama.modelPath,
    "--host", llama.config.host,
    "--port", $llama.config.port,
    "--alias", llama.config.modelAlias,
    "--ctx-size", $llama.config.contextSize,
    "--n-gpu-layers", $llama.config.gpuLayers
  ]

  llama.process = startProcess(
    command = llama.executablePath,
    workingDir = getAppDir(),
    args = arguments,
    options = {poStdErrToStdOut}
  )

  for _ in 0 ..< waitSeconds * 2:
    if llama.health():
      return
    sleep(500)

  raise newException(
    PlasticRuntimeError,
    "llama-server não respondeu em " & llama.endpoint
  )

proc stop*(llama: PlasticLlamaRuntime) =
  if not llama.process.isNil:
    if llama.process.running:
      llama.process.terminate()
    llama.process.close()
    llama.process = nil

proc chat*(llama: PlasticLlamaRuntime; messages: JsonNode; responseFormat = newJNull()): JsonNode =
  if not llama.health():
    llama.start()

  var payload = %*{
    "model": llama.config.modelAlias,
    "messages": messages,
    "temperature": llama.config.temperature,
    "max_tokens": llama.config.maxTokens
  }
  if responseFormat.kind != JNull:
    payload["response_format"] = responseFormat

  var client = newHttpClient(timeout = 180_000)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let response = client.request(
      llama.endpoint & "/chat/completions",
      httpMethod = HttpPost,
      body = $payload
    )
    if not response.status.startsWith("200"):
      raise newException(
        PlasticAgentError,
        "llama-server retornou " & response.status & ": " & response.body
      )
    result = parseJson(response.body)
  finally:
    client.close()

proc assistantContent(response: JsonNode): string =
  try:
    response["choices"][0]["message"]["content"].getStr
  except CatchableError:
    raise newException(PlasticAgentError, "Resposta do modelo sem choices[0].message.content")

# -----------------------------------------------------------------------------
# RLM e agentes
# -----------------------------------------------------------------------------

type
  PlasticAgentProperty* = object
    name*: string
    value*: JsonNode

  PlasticDesktopRuntime* = ref object of RootObj
    running*: bool

  PlasticWebViewRuntime* = ref object
    ## Perfil persistente compartilhado pelo frontend e por todos os foreign.
    userFolder*: string
    dataFolder*: string
    cacheFolder*: string
    persistent*: bool
    configured*: bool
    initialized*: bool

  PlasticApplication* = ref object
    nameValue: string
    productValue: PlasticProductConfig
    installationValue: PlasticInstallationRuntime
    planValue: PlasticPlan
    planJsonValue: string
    statesValue: PlasticStateRuntime
    ormValue: PlasticOrmRuntime
    okfValue: PlasticOkfRuntime
    gitMemoryValue: PlasticGitMemory
    foreignValue: PlasticForeignRuntime
    llamaValue: PlasticLlamaRuntime
    rlmValue: PlasticRlmRuntime
    agentsValue: Table[string, PlasticAgent]
    componentsValue: JsonNode
    renderTreeValue: JsonNode
    desktopValue: PlasticDesktopRuntime
    webViewValue: PlasticWebViewRuntime
    startupActionsValue: seq[proc() {.closure.}]
    startupExecutedValue: bool
    runningValue: bool

  PlasticAgent* = ref object
    constructorName*: string
    instanceName*: string
    properties*: Table[string, JsonNode]
    purpose*: string
    application*: PlasticApplication
    sessionVariables*: Table[string, JsonNode]
    maxIterations*: int
    maxRecursionDepth*: int

  PlasticCapability* = proc(
    agent: PlasticAgent;
    arguments: JsonNode
  ): JsonNode {.closure.}

  PlasticRlmRuntime* = ref object
    capabilities*: Table[string, PlasticCapability]

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
    applicationDataRoot /
    "webview" /
    "Default"

  PlasticWebViewRuntime(
    userFolder: userFolder,
    dataFolder: userFolder / "data",
    cacheFolder: userFolder / "cache",
    persistent: true,
    configured: false,
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

  runtime.persistent = persistent
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

proc prepareStorage*(
  runtime: PlasticWebViewRuntime
) =
  if runtime.isNil or not runtime.persistent:
    return

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

  if not dirExists(runtime.dataFolder) or
      not dirExists(runtime.cacheFolder):
    raise newException(
      PlasticInstallationError,
      "User folder WebView incompleto: " &
      runtime.userFolder
    )

  when defined(windows):
    putEnv(
      "WEBVIEW2_USER_DATA_FOLDER",
      runtime.userFolder
    )

proc describe*(
  runtime: PlasticWebViewRuntime
): JsonNode =
  if runtime.isNil:
    return newJNull()

  %*{
    "userFolder": runtime.userFolder,
    "dataFolder": runtime.dataFolder,
    "cacheFolder": runtime.cacheFolder,
    "persistent": runtime.persistent,
    "configured": runtime.configured,
    "initialized": runtime.initialized
  }

proc newRlmRuntime*(): PlasticRlmRuntime =
  PlasticRlmRuntime(capabilities: initTable[string, PlasticCapability]())

proc register*(runtime: PlasticRlmRuntime; name: string; capability: PlasticCapability) =
  runtime.capabilities[name] = capability

proc invoke(runtime: PlasticRlmRuntime; agent: PlasticAgent; name: string; arguments: JsonNode): JsonNode =
  if not runtime.capabilities.hasKey(name):
    raise newException(PlasticAgentError, "Capability RLM inexistente: " & name)
  runtime.capabilities[name](agent, arguments)

const PlasticRlmBasePrompt* = """
Você é um agente RLM local do GlaucoPlastic.
Responda exclusivamente com JSON válido neste formato:
{
  "instructions": [
    {"capability": "nome", "arguments": {}, "assign": "variavel-opcional"}
  ],
  "answer": null
}
Use capabilities para observar ou modificar a aplicação. Quando concluir,
preencha answer. Não produza código Nim arbitrário.
"""

proc agentPropertiesJson(agent: PlasticAgent): JsonNode =
  result = newJObject()
  for key, value in agent.properties:
    result[key] = value.copy

proc buildAgentSystemPrompt(agent: PlasticAgent): string =
  PlasticRlmBasePrompt & "\n\n" &
  PlasticOkfConsultationSkill & "\n\n" &
  PlasticOkfGenerationSkill & "\n\n" &
  "CONSTRUTOR: " & agent.constructorName & "\n" &
  "INSTÂNCIA: " & agent.instanceName & "\n" &
  "PROPRIEDADES: " & $agent.agentPropertiesJson() & "\n" &
  "ESPAÇOS OKF: " & $agent.application.okfValue.spaces & "\n" &
  "WEBCONTENTS: " & $agent.application.foreignValue.list() & "\n" &
  "PURPOSE:\n" & agent.purpose

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
    application: application,
    properties: properties,
    sessionVariables: initTable[string, JsonNode](),
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

proc installDefaultCapabilities(application: PlasticApplication) =
  application.rlmValue.register("state.get", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.statesValue.get(jsonString(arguments, "name"))
  )

  application.rlmValue.register("state.set", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    let name = jsonString(arguments, "name")
    let value = if arguments.hasKey("value"): arguments["value"] else: newJNull()
    agent.application.statesValue.set(name, value)
    %*{"ok": true}
  )

  application.rlmValue.register("orm.all", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.ormValue.all(jsonString(arguments, "entity"))
  )

  application.rlmValue.register("orm.find", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.ormValue.find(jsonString(arguments, "entity"), jsonInt(arguments, "id"))
  )

  application.rlmValue.register("orm.insert", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.ormValue.insert(jsonString(arguments, "entity"), arguments{"value"})
  )

  application.rlmValue.register("okf.list", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.okfValue.list(jsonString(arguments, "space"))
  )

  application.rlmValue.register("okf.search", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.okfValue.search(jsonString(arguments, "query"), jsonString(arguments, "space"))
  )

  application.rlmValue.register("okf.get", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.okfValue.get(jsonString(arguments, "id"))
  )

  application.rlmValue.register("okf.persist", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.okfValue.persist(arguments{"document"})
  )

  application.rlmValue.register("git.snapshot", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    snapshotJson(agent.application.gitMemoryValue.capture())
  )

  application.rlmValue.register("okf.tree", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.okfValue.tree()
  )

  application.rlmValue.register("webcontents.list", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.foreignValue.list()
  )

  application.rlmValue.register("webcontents.describe", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.foreignValue.describe(jsonString(arguments, "path"))
  )

  application.rlmValue.register("webcontents.eval_js", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.foreignValue.evalJs(
      jsonString(arguments, "path"),
      jsonString(arguments, "script"),
      jsonInt(arguments, "timeoutMs", 15_000)
    )
  )

  application.rlmValue.register("webcontents.navigate", proc(agent: PlasticAgent; arguments: JsonNode): JsonNode =
    agent.application.foreignValue.navigate(
      jsonString(arguments, "path"),
      jsonString(arguments, "url")
    )
    %*{"ok": true}
  )

proc run*(agent: PlasticAgent; input: JsonNode): JsonNode =
  let application = agent.application
  var memorySnapshot = snapshotJson(application.gitMemoryValue.capture())

  for iteration in 0 ..< agent.maxIterations:
    var messages = newJArray()
    messages.add %*{"role": "system", "content": buildAgentSystemPrompt(agent)}
    messages.add %*{
      "role": "user",
      "content": $(%*{
        "input": input,
        "iteration": iteration,
        "states": application.statesValue.snapshot(),
        "gitMemory": memorySnapshot,
        "variables": agent.sessionVariables
      })
    }

    let response = application.llamaValue.chat(
      messages,
      %*{"type": "json_object"}
    )

    let content = assistantContent(response)
    var program: JsonNode
    try:
      program = parseJson(content)
    except CatchableError as error:
      raise newException(PlasticAgentError, "RLM retornou JSON inválido: " & error.msg & "\n" & content)

    if program.hasKey("instructions") and program["instructions"].kind == JArray:
      for instruction in program["instructions"].items:
        let capabilityName = jsonString(instruction, "capability")
        let arguments = if instruction.hasKey("arguments"): instruction["arguments"] else: newJObject()
        let value = application.rlmValue.invoke(agent, capabilityName, arguments)
        let variableName = jsonString(instruction, "assign")
        if variableName.len > 0:
          agent.sessionVariables[variableName] = value

    if program.hasKey("answer") and program["answer"].kind != JNull:
      let answer = program["answer"].copy
      discard application.gitMemoryValue.writeMemo(
        agent.instanceName & "-" & $epochTime().int64,
        %*{
          "input": input,
          "answer": answer,
          "variables": agent.sessionVariables,
          "capturedAt": now().format("yyyy-MM-dd'T'HH:mm:sszzz")
        }
      )
      return answer

  raise newException(PlasticAgentError, "Agente excedeu o limite de iterações RLM")

# -----------------------------------------------------------------------------
# Derivação de componentes, foreign e agentes a partir do plano
# -----------------------------------------------------------------------------

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
  if node.isNil or planKind(node) != "call" or planName(node) != "binds":
    return ""

  let source = planSource(node).strip
  if not source.startsWith("binds "):
    return ""

  let arguments = planArguments(node)
  if arguments.len != 1:
    return ""

  let path = planName(arguments[0]).split('.')
  if path.len == 2 and path[0] == "states" and path[1].len > 0:
    return path[1]

  result = ""

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
  let partValue = namedArgumentValue(node, "part")
  let urlArgument = callNamedArgument(node, "url")

  let partName =
    if partValue.kind == JString and partValue.getStr.len > 0:
      partValue.getStr
    elif variableName.len > 0:
      variableName
    else:
      "Foreign" & $application.foreignValue.elements.len

  let localName =
    if variableName.len > 0:
      variableName
    else:
      partName

  let path =
    if componentName.len > 0:
      componentName & "." & localName
    else:
      localName

  var url = "about:blank"
  var urlStateName = ""

  if urlArgument.isSome:
    urlStateName = boundStateName(urlArgument.get)
    if urlStateName.len > 0 and application.statesValue.exists(urlStateName):
      let stateValue = application.statesValue.get(urlStateName)
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

  result = application.foreignValue.define(path, url)
  result.componentName = componentName
  result.variableName = variableName
  result.partName = partName
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

proc deriveOkfSpaces(plan: PlasticPlan): JsonNode =
  result = newJObject()
  let section = findPlanSection(plan, "okfs")
  if section.isNone:
    return

  for spaceNode in planChildren(section.get):
    let spaceName = planName(spaceNode)
    if spaceName.len == 0:
      continue
    var description = ""
    for child in planChildren(spaceNode):
      if planKind(child) == "call" and planName(child) == "purpose":
        description = firstLiteralString(child)
    result[spaceName] = %*{
      "name": spaceName,
      "purpose": description
    }

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
    #   portal = foreign(...)
    #
    # A variável passa a ser a identidade operacional do elemento.
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
    #   when portal loaded:
    #     portal.evalJs "..."
    for declaration in planChildren(component):
      if planKind(declaration) != "when":
        continue

      for variableName, element in variables:
        if foreignEventName(declaration, variableName).len > 0:
          element.eventPlans.add declaration.copy

    # Continua aceitando foreign escrito diretamente dentro de render.
    for declaration in planChildren(component):
      if planKind(declaration) == "assignment" and
          declaration.hasKey("value") and
          planKind(declaration["value"]) == "call" and
          planName(declaration["value"]) == "foreign":
        continue
      visitInlineForeign(declaration, componentName)

proc extractPurpose(agentNode: JsonNode): string =
  for child in planChildren(agentNode):
    if planKind(child) == "call" and planName(child) == "purpose":
      return firstLiteralString(child)
  ""

proc deriveAgents(application: PlasticApplication) =
  let section = findPlanSection(application.planValue, "agents")
  if section.isNone:
    return

  for agentNode in planChildren(section.get):
    let arguments = planArguments(agentNode)
    var instanceName = planName(agentNode)
    var properties = initTable[string, JsonNode]()

    if arguments.len > 0:
      let first = literalOrNull(arguments[0])
      if first.kind == JString:
        instanceName = first.getStr

    for argument in arguments:
      if planKind(argument) == "namedArgument":
        properties[planName(argument)] = planValueOrName(argument{"value"})

    let agent = newAgent(
      planName(agentNode),
      instanceName,
      extractPurpose(agentNode),
      application,
      properties
    )
    application.agentsValue[instanceName] = agent

# -----------------------------------------------------------------------------
# Materialização visual da DSL
# -----------------------------------------------------------------------------

type
  PlasticRenderEnvironment = Table[string, JsonNode]

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
        not applicationRef.statesValue.exists(element.urlStateName):
      return

    let current = jsonText(
      applicationRef.statesValue.get(element.urlStateName)
    )
    if current != url:
      applicationRef.statesValue.set(element.urlStateName, %url)

  for path, element in application.foreignValue.elements:
    if element.urlStateName.len == 0 or
        not application.statesValue.exists(element.urlStateName):
      continue

    let boundPath = path
    let boundState = element.urlStateName
    application.statesValue.onChanged(
      boundState,
      proc(change: PlasticStateChange) =
        let targetUrl = normalizedForeignUrl(jsonText(change.currentValue))
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
  for part in path:
    case current.kind
    of JObject:
      if not current.hasKey(part):
        return newJNull()
      current = current[part]
    of JArray:
      try:
        let index = parseInt(part)
        if index < 0 or index >= current.len:
          return newJNull()
        current = current[index]
      except ValueError:
        return newJNull()
    else:
      return newJNull()
  result = current.copy

proc evaluatePlanValue(
  application: PlasticApplication;
  node: JsonNode;
  environment: PlasticRenderEnvironment
): JsonNode

proc evaluatePlanMap(
  application: PlasticApplication;
  node: JsonNode;
  environment: PlasticRenderEnvironment
): JsonNode =
  result = newJObject()
  for entry in planChildren(node):
    if planKind(entry) == "mapEntry" and entry.hasKey("value"):
      result[planName(entry)] = application.evaluatePlanValue(
        entry["value"],
        environment
      )

proc evaluatePlanExpression(
  application: PlasticApplication;
  node: JsonNode;
  environment: PlasticRenderEnvironment
): JsonNode =
  let children = planChildren(node)
  if children.len == 0:
    return newJNull()

  let operatorName = planName(children[0])
  if children.len < 3:
    return newJNull()

  let left = application.evaluatePlanValue(children[1], environment)
  let right = application.evaluatePlanValue(children[2], environment)

  case operatorName
  of "+":
    if left.kind == JInt and right.kind == JInt:
      return %(left.getInt + right.getInt)
    if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
      let leftNumber = if left.kind == JInt: left.getInt.float else: left.getFloat
      let rightNumber = if right.kind == JInt: right.getInt.float else: right.getFloat
      return %(leftNumber + rightNumber)
    return %(jsonText(left) & jsonText(right))
  of "-":
    if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
      let leftNumber = if left.kind == JInt: left.getInt.float else: left.getFloat
      let rightNumber = if right.kind == JInt: right.getInt.float else: right.getFloat
      return %(leftNumber - rightNumber)
  of "*":
    if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
      let leftNumber = if left.kind == JInt: left.getInt.float else: left.getFloat
      let rightNumber = if right.kind == JInt: right.getInt.float else: right.getFloat
      return %(leftNumber * rightNumber)
  of "/":
    if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
      let leftNumber = if left.kind == JInt: left.getInt.float else: left.getFloat
      let rightNumber = if right.kind == JInt: right.getInt.float else: right.getFloat
      if rightNumber != 0:
        return %(leftNumber / rightNumber)
  else:
    discard

  result = newJNull()

proc evaluatePlanValue(
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
    if environment.hasKey(identifier):
      return environment[identifier].copy
    return %identifier

  of "path":
    let parts = planName(node).split('.')
    if parts.len == 0:
      return newJNull()

    if parts[0] == "states" and parts.len >= 2:
      if not application.statesValue.exists(parts[1]):
        return newJNull()
      let root = application.statesValue.get(parts[1])
      if parts.len == 2:
        return root.copy
      return jsonPathValue(root, parts[2 .. ^1])

    if environment.hasKey(parts[0]):
      let root = environment[parts[0]]
      if parts.len == 1:
        return root.copy
      return jsonPathValue(root, parts[1 .. ^1])

    return newJNull()

  of "call":
    # Somente a forma de comando `binds states.X` recebe significado na DSL.
    # `binds(states.X)` permanece uma chamada comum e não cria binding.
    if planName(node) == "binds" and planSource(node).strip.startsWith("binds "):
      let arguments = planArguments(node)
      if arguments.len == 1:
        return application.evaluatePlanValue(arguments[0], environment)
    return newJNull()

  of "map":
    return application.evaluatePlanMap(node, environment)

  of "expression":
    return application.evaluatePlanExpression(node, environment)

  of "namedArgument":
    if node.hasKey("value"):
      return application.evaluatePlanValue(node["value"], environment)
    return newJNull()

  of "assignment":
    if node.hasKey("value"):
      return application.evaluatePlanValue(node["value"], environment)
    return newJNull()

  else:
    let literal = literalOrNull(node)
    if literal.kind != JNull:
      return literal
    return newJNull()

proc executeForeignElementEffect(
  application: PlasticApplication;
  element: PlasticForeignElementRuntime;
  effect: JsonNode
) =
  if application.isNil or element.isNil:
    return

  if planKind(effect) == "assignment" and
      effect.hasKey("left") and effect.hasKey("value"):
    let leftPath = planName(effect["left"]).split('.')
    if leftPath.len >= 2 and leftPath[0] == "states" and
        application.statesValue.exists(leftPath[1]):
      let environment = initTable[string, JsonNode]()
      let value = application.evaluatePlanValue(
        effect["value"],
        environment
      )
      application.statesValue.set(leftPath[1], value)
    return

  if planKind(effect) != "call":
    return

  let operationPath = planName(effect).split('.')
  if operationPath.len < 2:
    return

  let operation = operationPath[^1]
  var foreignPath = ""

  if operationPath.len == 2 and
      element.variableName.len > 0 and
      operationPath[0] == element.variableName:
    foreignPath = element.path
  elif operationPath.len >= 3:
    let candidate = operationPath[0 .. ^2].join(".")
    if application.foreignValue.elements.hasKey(candidate):
      foreignPath = candidate

  if foreignPath.len == 0 or
      not application.foreignValue.elements.hasKey(foreignPath):
    return

  case operation
  of "evalJs", "javascript", "executeScript":
    let arguments = planArguments(effect)
    if arguments.len > 0:
      let environment = initTable[string, JsonNode]()
      let scriptValue = application.evaluatePlanValue(
        arguments[0],
        environment
      )
      discard application.foreignValue.evalJs(
        foreignPath,
        jsonText(scriptValue)
      )

  of "navigate", "open", "go":
    let arguments = planArguments(effect)
    if arguments.len > 0:
      let environment = initTable[string, JsonNode]()
      let target = application.evaluatePlanValue(
        arguments[0],
        environment
      )
      application.foreignValue.navigate(
        foreignPath,
        jsonText(target)
      )

  of "goBack", "back":
    application.foreignValue.goBack(foreignPath)

  of "goForward", "forward":
    application.foreignValue.goForward(foreignPath)

  of "reload", "refresh":
    application.foreignValue.reload(foreignPath)

  else:
    discard

proc installForeignComponentEventBindings(
  application: PlasticApplication
) =
  let applicationRef = application

  application.foreignValue.onEvent = proc(
    path, eventName: string
  ) =
    if not applicationRef.foreignValue.elements.hasKey(path):
      return

    let element = applicationRef.foreignValue.elements[path]
    for listener in element.eventPlans.items:
      if foreignEventName(listener, element.variableName) != eventName:
        continue

      for effect in planChildren(listener):
        applicationRef.executeForeignElementEffect(
          element,
          effect
        )

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
        value = application.evaluatePlanValue(argument, parentEnvironment)
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
        environment[localName] = application.evaluatePlanValue(
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
  let partNode = callNamedArgument(node, "part")
  let urlNode = callNamedArgument(node, "url")
  let classNode = callNamedArgument(node, "class")
  let styleNode = callNamedArgument(node, "style")
  let titleNode = callNamedArgument(node, "title")

  let partName =
    if partNode.isSome:
      jsonText(application.evaluatePlanValue(partNode.get, environment))
    else:
      "Foreign"

  let localName =
    if variableName.len > 0:
      variableName
    else:
      partName

  let path =
    if componentName.len > 0:
      componentName & "." & localName
    else:
      localName

  let urlStateName =
    if urlNode.isSome:
      boundStateName(urlNode.get)
    else:
      ""

  let url = normalizedForeignUrl(
    if urlNode.isSome:
      jsonText(application.evaluatePlanValue(urlNode.get, environment))
    else:
      "about:blank"
  )

  if application.foreignValue.elements.hasKey(path):
    let element = application.foreignValue.elements[path]
    element.componentName = componentName
    element.variableName = variableName
    element.partName = partName
    element.url = url
    element.urlStateName = urlStateName
    if element.status == pfsIdle:
      element.currentUrl = url

  let className =
    if classNode.isSome:
      jsonText(application.evaluatePlanValue(classNode.get, environment))
    else:
      ""

  let styleValue =
    if styleNode.isSome:
      jsonText(application.evaluatePlanValue(styleNode.get, environment))
    else:
      ""

  let titleValue =
    if titleNode.isSome:
      jsonText(application.evaluatePlanValue(titleNode.get, environment))
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
          jsonString(reference, "__glaucoElementReference") == "foreign" and
          reference.hasKey("node"):
        return application.renderForeignPlaceholder(
          reference["node"],
          environment,
          jsonString(reference, "componentName", componentName),
          jsonString(reference, "variableName", localName)
        )
    return ""

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

  let tagName = sanitizeTagName(name)
  var attributes = ""
  var content = ""
  var partName = ""

  for argument in planArguments(node):
    if planKind(argument) == "namedArgument":
      let attributeName = planName(argument)
      let value = application.evaluatePlanValue(argument, environment)
      let text = jsonText(value)

      case attributeName
      of "part":
        partName = text
      of "bind":
        let statePath = planName(argument{"value"}).split('.')
        if statePath.len >= 2 and statePath[0] == "states":
          attributes.add " data-glauco-bind-state=\"" &
            htmlAttribute(statePath[1]) & "\""
      of "onClick", "onclick":
        if argument.hasKey("value"):
          attributes.add " data-glauco-on-click=\"" &
            htmlAttribute($argument["value"]) & "\""
      of "onChange", "onchange":
        if argument.hasKey("value"):
          attributes.add " data-glauco-on-change=\"" &
            htmlAttribute($argument["value"]) & "\""
      of "onInput", "oninput":
        if argument.hasKey("value"):
          attributes.add " data-glauco-on-input=\"" &
            htmlAttribute($argument["value"]) & "\""
      of "onBlur", "onblur":
        if argument.hasKey("value"):
          attributes.add " data-glauco-on-blur=\"" &
            htmlAttribute($argument["value"]) & "\""
      of "onEnter", "onenter":
        if argument.hasKey("value"):
          attributes.add " data-glauco-on-enter=\"" &
            htmlAttribute($argument["value"]) & "\""
      of "class", "id", "style", "title", "role", "name", "value", "type",
         "placeholder", "autocomplete", "spellcheck", "aria-label":
        attributes.add " " & attributeName & "=\"" & htmlAttribute(text) & "\""
      else:
        if attributeName.startsWith("data"):
          attributes.add " " & attributeName & "=\"" & htmlAttribute(text) & "\""
    else:
      content.add htmlEscape(jsonText(
        application.evaluatePlanValue(argument, environment)
      ))

  if partName.len > 0:
    let path =
      if componentName.len > 0:
        componentName & "." & partName
      else:
        partName
    attributes.add " data-glauco-part=\"" & htmlAttribute(path) & "\""

  for child in planChildren(node):
    content.add application.renderPlanNodeHtml(
      child,
      environment,
      componentName
    )

  const voidTags = [
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr"
  ]

  if tagName in voidTags:
    result = "<" & tagName & attributes & ">"
  else:
    result = "<" & tagName & attributes & ">" & content & "</" & tagName & ">"

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

  if rootRender.isSome:
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
      width: 100%;
      min-height: 460px;
      margin-top: 16px;
      overflow: hidden;
      border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
      border-radius: 12px;
      background: color-mix(in srgb, Canvas 92%, CanvasText 8%);
    }
    .glauco-foreign::before {
      content: "Carregando conteúdo externo…";
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      opacity: .65;
    }
    .glauco-foreign[data-status="ready"]::before { display: none; }
""" & statusStyles & """
  </style>
</head>
<body>
  <div id="glaucoplastic-application">""" & body & """</div>
  <script>
    (() => {
      window.__glaucoplasticEvents =
        window.__glaucoplasticEvents || [];

      function eventQueue() {
        return window.__glaucoplasticEvents ||
          (window.__glaucoplasticEvents = []);
      }

      function parseEffect(value) {
        if (!value) return null;
        try { return JSON.parse(value); }
        catch (_) { return null; }
      }

      function emit(eventName, element, event, effectText) {
        eventQueue().push({
          event: eventName,
          part: element && element.dataset
            ? (element.dataset.glaucoPart || "")
            : "",
          bindState: element && element.dataset
            ? (element.dataset.glaucoBindState || "")
            : "",
          value: element && "value" in element ? element.value : null,
          checked: element && "checked" in element
            ? !!element.checked
            : null,
          key: event && event.key ? event.key : "",
          effect: parseEffect(effectText)
        });
      }

      document.addEventListener("click", event => {
        const element = event.target.closest("[data-glauco-on-click]");
        if (!element) return;
        emit("click", element, event, element.dataset.glaucoOnClick);
      }, true);

      document.addEventListener("change", event => {
        const element = event.target.closest(
          "[data-glauco-bind-state],[data-glauco-on-change]"
        );
        if (!element) return;
        emit("change", element, event, element.dataset.glaucoOnChange);
      }, true);

      document.addEventListener("input", event => {
        const element = event.target.closest(
          "[data-glauco-bind-state],[data-glauco-on-input]"
        );
        if (!element) return;
        emit("input", element, event, element.dataset.glaucoOnInput);
      }, true);

      document.addEventListener("blur", event => {
        const element = event.target && event.target.closest
          ? event.target.closest("[data-glauco-on-blur]")
          : null;
        if (!element) return;
        emit("blur", element, event, element.dataset.glaucoOnBlur);
      }, true);

      document.addEventListener("keydown", event => {
        if (event.key !== "Enter") return;
        const element = event.target.closest("[data-glauco-on-enter]");
        if (!element) return;
        event.preventDefault();
        if (element.dataset.glaucoBindState) {
          emit("change", element, event, null);
        }
        emit("enter", element, event, element.dataset.glaucoOnEnter);
      }, true);
    })();
  </script>
</body>
</html>"""

# -----------------------------------------------------------------------------
# Host desktop Linux: GTK 3 + WebKitGTK 4.1
# -----------------------------------------------------------------------------

when defined(linux):
  const
    PlasticGtkLib = "libgtk-3.so(|.0)"
    PlasticGObjectLib = "libgobject-2.0.so(|.0)"
    PlasticGLibLib = "libglib-2.0.so(|.0)"
    PlasticWebKitLib = "libwebkit2gtk-4.1.so(|.0)"
    PlasticJavaScriptCoreLib = "libjavascriptcoregtk-4.1.so(|.0)"

  type
    PlasticGtkAllocation {.bycopy.} = object
      x, y, width, height: cint

    PlasticGSourceFunc = proc(data: pointer): cint {.cdecl.}
    PlasticGAsyncReadyCallback = proc(
      sourceObject: pointer;
      result: pointer;
      userData: pointer
    ) {.cdecl.}

    PlasticJsEvalRequest = ref object
      completed: bool
      failed: bool
      text: string

    PlasticLinuxDesktopRuntime = ref object of PlasticDesktopRuntime
      application: PlasticApplication
      window: pointer
      fixed: pointer
      websiteDataManager: pointer
      webContext: pointer
      mainWebView: pointer
      width: int
      height: int
      geometryTimer: cuint

  var plasticPendingJsRequests: seq[PlasticJsEvalRequest]


  type
    PlasticLinuxUiCandidate = object
      backend: string
      disableDmabuf: bool
      reason: string

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
    else:
      if childEnvironment.hasKey("WEBKIT_DISABLE_DMABUF_RENDERER"):
        childEnvironment.del("WEBKIT_DISABLE_DMABUF_RENDERER")
      if childEnvironment.hasKey("GLAUCOPLASTIC_DISABLE_DMABUF"):
        childEnvironment.del("GLAUCOPLASTIC_DISABLE_DMABUF")

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
  proc gtk_fixed_new(): pointer
    {.cdecl, importc, dynlib: PlasticGtkLib.}
  proc gtk_fixed_put(fixed, widget: pointer; x, y: cint)
    {.cdecl, importc, dynlib: PlasticGtkLib.}
  proc gtk_fixed_move(fixed, widget: pointer; x, y: cint)
    {.cdecl, importc, dynlib: PlasticGtkLib.}
  proc gtk_widget_set_size_request(widget: pointer; width, height: cint)
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
  proc webkit_web_view_new(): pointer
    {.cdecl, importc, dynlib: PlasticWebKitLib.}
  proc webkit_web_view_new_with_context(
    context: pointer
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
      gtk_widget_set_opacity(webView, 0.55)
      gtk_widget_set_sensitive(webView, 0)
      if not desktop.isNil:
        desktop.updateForeignHostStatus(element.path, "loading")
      if not element.eventHandler.isNil:
        element.eventHandler(element.path, "loading")
    of 3:
      element.status = pfsReady
      gtk_widget_set_opacity(webView, 1.0)
      gtk_widget_set_sensitive(webView, 1)
      if not desktop.isNil:
        desktop.updateForeignHostStatus(element.path, "ready")
      if not element.eventHandler.isNil:
        element.eventHandler(element.path, "loaded")
    else:
      discard

  proc newLinuxWebKitForeignBackend(
    desktop: PlasticLinuxDesktopRuntime
  ): PlasticForeignBackend =
    result = PlasticForeignBackend(name: "webkitgtk-4.1")

    result.create = proc(element: PlasticForeignElementRuntime) =
      if not element.nativeHandle.isNil:
        return
      let webView =
        if desktop.webContext.isNil:
          webkit_web_view_new()
        else:
          webkit_web_view_new_with_context(
            desktop.webContext
          )

      if webView.isNil:
        raise newException(
          PlasticForeignBackendError,
          "WebKitGTK não conseguiu criar o WebContents foreign"
        )
      element.nativeHandle = webView
      element.desktopOwner = cast[pointer](desktop)
      element.status = pfsIdle
      gtk_widget_set_size_request(webView, 1, 1)
      gtk_fixed_put(desktop.fixed, webView, 0, 0)
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

  proc executeDesktopEffect(
    desktop: PlasticLinuxDesktopRuntime;
    effect: JsonNode
  )

  proc executeDesktopEffectWithValue(
    desktop: PlasticLinuxDesktopRuntime;
    effect: JsonNode;
    eventValue: JsonNode
  )

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

        let bindState = jsonString(event, "bindState")
        if bindState.len > 0 and
            desktop.application.statesValue.exists(bindState):
          desktop.application.statesValue.set(
            bindState,
            eventValue
          )

        if event.hasKey("effect") and event["effect"].kind == JObject:
          desktop.executeDesktopEffectWithValue(
            event["effect"],
            eventValue
          )
    except CatchableError as error:
      if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
        echo "[GlaucoPlastic] Falha ao processar evento da interface: ",
          error.msg

  proc syncPlasticForeignGeometry(data: pointer): cint {.cdecl.} =
    let desktop = cast[PlasticLinuxDesktopRuntime](data)
    if desktop.isNil or not desktop.running or desktop.mainWebView.isNil:
      return 0

    desktop.drainPlasticUiEvents()

    let script = """
      JSON.stringify(
        Array.from(document.querySelectorAll('[data-glauco-foreign]')).map(
          element => {
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
                rectangle.width > 0 && rectangle.height > 0
            };
          }
        )
      )
    """

    try:
      let rectangles = evaluateNativeJs(desktop.mainWebView, script, 800)
      if rectangles.kind != JArray:
        return 1

      var visiblePaths = initHashSet[string]()
      for rectangle in rectangles.items:
        let path = jsonString(rectangle, "path")
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

        gtk_fixed_move(desktop.fixed, element.nativeHandle, x.cint, y.cint)
        gtk_widget_set_size_request(element.nativeHandle, width.cint, height.cint)

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

    return 1

  proc onPlasticWindowDestroyed(widget, userData: pointer) {.cdecl.} =
    let desktop = cast[PlasticLinuxDesktopRuntime](userData)
    if not desktop.isNil:
      desktop.running = false
      for _, element in desktop.application.foreignValue.elements:
        element.nativeHandle = nil
        element.status = pfsClosed
    gtk_main_quit()

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

  proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime)

  proc setDesktopPartProperty(
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
          document.querySelectorAll('[data-glauco-part]')
        ).find(item => item.dataset.glaucoPart === path);
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

  proc executeDesktopEffectWithValue(
    desktop: PlasticLinuxDesktopRuntime;
    effect: JsonNode;
    eventValue: JsonNode
  ) =
    if desktop.isNil:
      return


    let changesSource = planSource(effect).strip
    let changesMarker = " changes "
    let changesIndex = changesSource.find(changesMarker)

    if changesIndex > 0:
      let sourceText =
        changesSource[0 ..< changesIndex].strip
      let targetText =
        changesSource[
          changesIndex + changesMarker.len .. ^1
        ].strip

      var transferredValue = newJNull()
      var hasTransferredValue = false

      if sourceText == "eventValue":
        transferredValue =
          if eventValue.isNil:
            newJNull()
          else:
            eventValue.copy
        hasTransferredValue = true

      elif sourceText.startsWith("states."):
        let sourcePath = sourceText.split('.')
        if sourcePath.len == 2 and
            desktop.application.statesValue.exists(
              sourcePath[1]
            ):
          transferredValue =
            desktop.application.statesValue
              .get(sourcePath[1])
              .copy
          hasTransferredValue = true

      if hasTransferredValue and
          targetText.startsWith("states."):
        let targetPath = targetText.split('.')
        if targetPath.len == 2 and
            desktop.application.statesValue.exists(
              targetPath[1]
            ):
          desktop.application.statesValue.set(
            targetPath[1],
            transferredValue
          )
          return

    if planKind(effect) == "assignment" and
        effect.hasKey("left") and effect.hasKey("value"):
      let leftPath = planName(effect["left"]).split('.')
      let environment = initTable[string, JsonNode]()
      let value = desktop.application.evaluatePlanValue(
        effect["value"],
        environment
      )

      if leftPath.len >= 2 and leftPath[0] == "states":
        desktop.application.statesValue.set(leftPath[1], value)
        return

      if leftPath.len >= 3:
        let visualPath = leftPath[0 .. ^2].join(".")
        desktop.setDesktopPartProperty(
          visualPath,
          leftPath[^1],
          value
        )
        return

    if planKind(effect) == "call":
      let operationPath = planName(effect).split('.')

      if operationPath.len >= 3:
        let operation = operationPath[^1]
        let foreignPath = operationPath[0 .. ^2].join(".")

        if desktop.application.foreignValue.elements.hasKey(foreignPath):
          case operation
          of "navigate", "open", "go":
            let arguments = planArguments(effect)
            if arguments.len > 0:
              let environment = initTable[string, JsonNode]()
              let value = desktop.application.evaluatePlanValue(
                arguments[0],
                environment
              )
              let url = normalizedForeignUrl(jsonText(value))
              desktop.application.foreignValue.navigate(
                foreignPath,
                url
              )
            return

          of "goBack", "back":
            desktop.application.foreignValue.goBack(foreignPath)
            return

          of "goForward", "forward":
            desktop.application.foreignValue.goForward(foreignPath)
            return

          of "reload", "refresh":
            desktop.application.foreignValue.reload(foreignPath)
            return

          of "evalJs", "javascript", "executeScript":
            let arguments = planArguments(effect)
            if arguments.len > 0:
              let environment = initTable[string, JsonNode]()
              let scriptValue = desktop.application.evaluatePlanValue(
                arguments[0],
                environment
              )
              executeNativeJsAsync(
                desktop.application.foreignValue
                  .elements[foreignPath]
                  .nativeHandle,
                jsonText(scriptValue)
              )
            return

          else:
            discard

      if planName(effect) == "render":
        desktop.reloadLinuxDesktop()

  proc executeDesktopEffect(
    desktop: PlasticLinuxDesktopRuntime;
    effect: JsonNode
  ) =
    desktop.executeDesktopEffectWithValue(
      effect,
      nil
    )

  proc registerDesktopStateListeners(
    desktop: PlasticLinuxDesktopRuntime
  ) =
    let statesSection = findPlanSection(
      desktop.application.planValue,
      "states"
    )
    if statesSection.isNone:
      return

    for listenerNode in planChildren(statesSection.get):
      if planKind(listenerNode) != "when" or not listenerNode.hasKey("condition"):
        continue

      let condition = listenerNode["condition"]
      if planKind(condition) != "call":
        continue

      let conditionPath = planName(condition).split('.')
      if conditionPath.len < 2 or conditionPath[0] != "states":
        continue

      var isChangedEvent = false
      for argument in planArguments(condition):
        if planName(argument) == "changed":
          isChangedEvent = true
          break
      if not isChangedEvent:
        continue

      let stateName = conditionPath[1]
      if not desktop.application.statesValue.exists(stateName):
        continue

      let listenerPlan = listenerNode.copy
      desktop.application.statesValue.onChanged(
        stateName,
        proc(change: PlasticStateChange) =
          if not desktop.running:
            return
          for effect in planChildren(listenerPlan):
            desktop.executeDesktopEffect(effect)
      )

  proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime) =
    if desktop.isNil or desktop.mainWebView.isNil:
      return
    let html = desktop.application.renderApplicationHtml()
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
    if gtk_init_check(nil, nil) == 0:
      raise newException(
        PlasticRuntimeError,
        "GTK não conseguiu inicializar a sessão gráfica. " &
        "Confirme WAYLAND_DISPLAY/DISPLAY e o pacote webkit2gtk-4.1."
      )

    let desktop = PlasticLinuxDesktopRuntime(
      application: application,
      running: true,
      width: 1180,
      height: 760
    )
    application.desktopValue = desktop

    application.webViewValue.prepareStorage()

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

    application.webViewValue.initialized = true

    desktop.window = gtk_window_new(0)
    desktop.fixed = gtk_fixed_new()
    desktop.mainWebView =
      webkit_web_view_new_with_context(
        desktop.webContext
      )

    if desktop.window.isNil or desktop.fixed.isNil or desktop.mainWebView.isNil:
      raise newException(
        PlasticRuntimeError,
        "Falha ao criar a janela GTK/WebKitGTK"
      )

    gtk_window_set_title(desktop.window, application.productValue.title.cstring)
    gtk_window_set_default_size(desktop.window, desktop.width.cint, desktop.height.cint)
    gtk_container_add(desktop.window, desktop.fixed)
    gtk_fixed_put(desktop.fixed, desktop.mainWebView, 0, 0)
    gtk_widget_set_size_request(desktop.mainWebView, desktop.width.cint, desktop.height.cint)

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
      "size-allocate",
      cast[pointer](onPlasticWindowSizeAllocated),
      cast[pointer](desktop),
      nil,
      0
    )

    application.foreignValue.registerBackend(
      newLinuxWebKitForeignBackend(desktop)
    )

    desktop.reloadLinuxDesktop()
    gtk_widget_show_all(desktop.window)
    gtk_window_present(desktop.window)

    for path in application.foreignValue.elements.keys.toSeq.sorted:
      application.foreignValue.create(path)

    # Processa a criação inicial das superfícies GTK/WebKitGTK antes de
    # confirmar ao processo iniciador que este backend é funcional. Falhas
    # fatais do protocolo Wayland encerram o filho antes deste handshake.
    for _ in 0 ..< 80:
      discard g_main_context_iteration(nil, 0)
      sleep(10)

    markLinuxUiReady()

    # O handshake gráfico ocorre antes do início do modelo. Assim, uma falha
    # do llama.cpp não é interpretada pelo processo pai como falha de
    # Wayland/X11 e não dispara uma troca incorreta de backend.
    if startModel and application.agentsValue.len > 0:
      application.llamaValue.start()

    desktop.geometryTimer = g_timeout_add(
      120,
      syncPlasticForeignGeometry,
      cast[pointer](desktop)
    )

    desktop.registerDesktopStateListeners()

    for stateName in application.statesValue.values.keys.toSeq:
      application.statesValue.onChanged(
        stateName,
        proc(change: PlasticStateChange) =
          if desktop.running:
            desktop.reloadLinuxDesktop()
      )

    gtk_main()
    desktop.running = false

    if not desktop.webContext.isNil:
      g_object_unref(desktop.webContext)
      desktop.webContext = nil

    if not desktop.websiteDataManager.isNil:
      g_object_unref(desktop.websiteDataManager)
      desktop.websiteDataManager = nil

    application.webViewValue.initialized = false


# -----------------------------------------------------------------------------
# PlasticApplication API
# -----------------------------------------------------------------------------

proc newPlasticApplication*(applicationName, serializedPlan: string): PlasticApplication =
  let plan = parsePlasticPlan(serializedPlan)
  let product = parseProductConfig(plan, applicationName)
  let installationConfig = parseInstallationConfig(plan, applicationName)
  let installation = newInstallationRuntime(installationConfig)

  result = PlasticApplication(
    nameValue: applicationName,
    productValue: product,
    installationValue: installation,
    planValue: plan,
    planJsonValue: serializedPlan,
    statesValue: newStateRuntime(),
    ormValue: newOrmRuntime(installation.ormPath),
    okfValue: newOkfRuntime(installation.okfPath),
    gitMemoryValue: PlasticGitMemory(
      repositoryPath: getCurrentDir(),
      memoryPath: installation.gitMemoryPath
    ),
    foreignValue: newForeignRuntime(),
    llamaValue: newLlamaRuntime(),
    rlmValue: newRlmRuntime(),
    agentsValue: initTable[string, PlasticAgent](),
    componentsValue: deriveComponents(plan),
    renderTreeValue: deriveRenderTree(plan),
    desktopValue: PlasticDesktopRuntime(running: false),
    webViewValue: newWebViewRuntime(installation.dataRoot),
    startupActionsValue: @[],
    startupExecutedValue: false,
    runningValue: false
  )

  result.ormValue.initializeOrmFromPlan(plan)
  result.okfValue.spaces = deriveOkfSpaces(plan)
  initializeStatesFromPlan(result.statesValue, plan)
  result.installDefaultCapabilities()
  result.deriveForeignElements()
  result.installForeignComponentEventBindings()
  result.installForeignUrlBindings()
  result.deriveAgents()

proc name*(application: PlasticApplication): string = application.nameValue
proc product*(application: PlasticApplication): PlasticProductConfig = application.productValue
proc installation*(application: PlasticApplication): PlasticInstallationRuntime = application.installationValue
proc states*(application: PlasticApplication): PlasticStateRuntime = application.statesValue
proc orm*(application: PlasticApplication): PlasticOrmRuntime = application.ormValue
proc okf*(application: PlasticApplication): PlasticOkfRuntime = application.okfValue
proc foreign*(application: PlasticApplication): PlasticForeignRuntime = application.foreignValue
proc llama*(application: PlasticApplication): PlasticLlamaRuntime = application.llamaValue
proc rlm*(application: PlasticApplication): PlasticRlmRuntime = application.rlmValue
proc gitMemory*(application: PlasticApplication): PlasticGitMemory = application.gitMemoryValue
proc desktop*(application: PlasticApplication): PlasticDesktopRuntime = application.desktopValue
proc webview*(application: PlasticApplication): PlasticWebViewRuntime = application.webViewValue
proc agents*(application: PlasticApplication): Table[string, PlasticAgent] = application.agentsValue
proc planJson*(application: PlasticApplication): string = application.planJsonValue
proc components*(application: PlasticApplication): JsonNode = application.componentsValue.copy
proc renderTree*(application: PlasticApplication): JsonNode = application.renderTreeValue.copy
proc ormSchema*(application: PlasticApplication): JsonNode = application.ormValue.schema.copy

proc registerProgram*(
  application: PlasticApplication;
  action: proc() {.closure.}
) =
  ## Registra o código Nim livre encontrado diretamente no corpo do macro.
  ## O bloco é executado uma única vez quando a aplicação é inicializada.
  if application.isNil or action.isNil:
    return
  application.startupActionsValue.add action

proc executeProgram*(
  application: PlasticApplication
) =
  ## Executa uma única vez a programação livre entregue pelo macro.
  if application.isNil or application.startupExecutedValue:
    return

  application.startupExecutedValue = true
  try:
    for action in application.startupActionsValue:
      action()
  except:
    application.startupExecutedValue = false
    raise

proc programExecuted*(application: PlasticApplication): bool =
  not application.isNil and application.startupExecutedValue

# Compatibilidade temporária com a versão que usava `startup:`.
proc registerStartup*(
  application: PlasticApplication;
  action: proc() {.closure.}
) =
  application.registerProgram(action)

proc initializeDeclaredApplication*(
  application: PlasticApplication
) =
  application.executeProgram()

proc startupExecuted*(application: PlasticApplication): bool =
  application.programExecuted()

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

  result["gitMemory"] = %*{
    "repositoryPath": application.gitMemoryValue.repositoryPath,
    "memoryPath": application.gitMemoryValue.memoryPath
  }

  result["foreign"] = application.foreignValue.list()
  result["webview"] = application.webViewValue.describe()

  result["llama"] = %*{
    "endpoint": application.llamaValue.endpoint,
    "executablePath": application.llamaValue.executablePath,
    "modelPath": application.llamaValue.modelPath,
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

proc validateInstallation*(application: PlasticApplication) =
  application.installationValue.validate()
  application.okfValue.validate()

proc prepareDevelopmentLayout*(application: PlasticApplication) =
  ## Preparação explícita para desenvolvimento e testes. A execução normal
  ## continua exigindo que o MSI tenha criado os diretórios.
  application.installationValue.prepareDevelopmentLayout()
  if application.okfValue.spaces.kind == JObject:
    for spaceName, _ in application.okfValue.spaces.pairs:
      createDir(application.okfValue.rootPath / spaceName)

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

  if startModel and application.agentsValue.len > 0:
    application.llamaValue.start()

  result = application.runtimeSummary()

proc run*(application: PlasticApplication; startModel = true) =
  application.validateInstallation()

  when defined(linux) and not defined(glaucoplasticHeadless):
    # GTK escolhe Wayland/X11 antes de gtk_init_check e não permite trocar o
    # display no mesmo processo. O processo principal atua como iniciador:
    # cada candidato é executado em um filho isolado e o primeiro que conclui
    # o handshake GTK/WebKitGTK permanece como aplicação visível.
    if not isPlasticLinuxUiChild() and
        not plasticEnvEnabled("GLAUCOPLASTIC_DISABLE_UI_LAUNCHER"):
      let exitCode = launchLinuxDesktopChild()
      if exitCode != 0:
        raise newException(
          PlasticRuntimeError,
          "A interface desktop terminou com código " & $exitCode
        )
      return

  application.executeProgram()
  application.runningValue = true

  when defined(linux) and not defined(glaucoplasticHeadless):
    application.openLinuxDesktop(startModel)
    application.llamaValue.stop()
    application.runningValue = false
  else:
    if startModel and application.agentsValue.len > 0:
      application.llamaValue.start()
    if application.foreignValue.backend.isNil:
      application.foreignValue.registerBackend(newMockForeignBackend())
    for path in application.foreignValue.elements.keys:
      application.foreignValue.create(path)

proc close*(application: PlasticApplication) =
  if application.isNil:
    return
  when defined(linux):
    if not application.desktopValue.isNil and application.desktopValue.running:
      application.desktopValue.running = false
      gtk_main_quit()
  for path in application.foreignValue.elements.keys.toSeq:
    try:
      application.foreignValue.close(path)
    except PlasticForeignBackendError:
      discard
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

# -----------------------------------------------------------------------------
# Compile-time AST -> JSON
# -----------------------------------------------------------------------------

proc astLiteral(node: NimNode): JsonNode {.compileTime.} =
  case node.kind
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

proc astDslName(node: NimNode): string {.compileTime.} =
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

proc astToPlanJson(node: NimNode): JsonNode {.compileTime.}

proc astChildrenJson(node: NimNode; startIndex, endIndex: int): JsonNode {.compileTime.} =
  result = newJArray()
  if endIndex <= startIndex:
    return
  for index in startIndex ..< endIndex:
    result.add astToPlanJson(node[index])

proc astToPlanJson(node: NimNode): JsonNode {.compileTime.} =
  result = newJObject()
  result["source"] = %node.repr
  result["astKind"] = %($node.kind)

  case node.kind
  of nnkStmtList:
    result["kind"] = %"root"
    result["children"] = astChildrenJson(node, 0, node.len)

  of nnkCall, nnkCommand:
    result["kind"] = %"call"
    let hasBody = node.len > 1 and node[^1].kind == nnkStmtList
    let argumentEnd = if hasBody: node.len - 1 else: node.len

    var callName: string
    var arguments = newJArray()

    # A command syntax `h1(part = Titulo) valor` produz um nnkCommand
    # cujo callee é outro nnkCall. O plano deve fundir os dois níveis:
    # nome `h1`, argumento nomeado `part` e argumento de conteúdo `valor`.
    if node[0].kind in {nnkCall, nnkCommand}:
      let nested = node[0]
      let nestedHasBody = nested.len > 1 and nested[^1].kind == nnkStmtList
      let nestedEnd = if nestedHasBody: nested.len - 1 else: nested.len

      callName = astDslName(nested[0])
      for index in 1 ..< nestedEnd:
        arguments.add astToPlanJson(nested[index])

      for index in 1 ..< argumentEnd:
        arguments.add astToPlanJson(node[index])
    else:
      callName = astDslName(node[0])
      for index in 1 ..< argumentEnd:
        arguments.add astToPlanJson(node[index])

    # `div` é palavra reservada do Nim. A DSL usa `divi(...)` e o
    # plano recebe o nome HTML semântico `div`.
    if callName == "divi":
      callName = "div"

    result["name"] = %callName
    result["arguments"] = arguments
    result["children"] = if hasBody: astChildrenJson(node[^1], 0, node[^1].len) else: newJArray()

  of nnkExprEqExpr:
    let argumentName = astDslName(node[0])
    result["kind"] = %"namedArgument"
    result["name"] = %argumentName
    result["value"] = astToPlanJson(node[1])

  of nnkAsgn:
    result["kind"] = %"assignment"
    result["left"] = astToPlanJson(node[0])
    result["value"] = astToPlanJson(node[1])
    result["name"] = %node[0].repr.splitWhitespace()[0]

  of nnkWhenStmt:
    result["kind"] = %"when"
    result["branches"] = astChildrenJson(node, 0, node.len)
    if node.len > 0 and node[0].kind == nnkElifBranch:
      result["condition"] = astToPlanJson(node[0][0])
      result["children"] = astChildrenJson(node[0][1], 0, node[0][1].len)

  of nnkElifBranch:
    result["kind"] = %"whenBranch"
    result["condition"] = astToPlanJson(node[0])
    result["children"] = astChildrenJson(node[1], 0, node[1].len)

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

const PlasticDslTopLevelSections = [
  "product",
  "installation",
  "orm",
  "okfs",
  "components",
  "states",
  "agents",
  "render"
]

proc isPlasticDslTopLevelSection(
  declaration: NimNode
): bool {.compileTime.} =
  if declaration.kind notin {nnkCall, nnkCommand} or
      declaration.len == 0:
    return false

  astDslName(declaration[0]) in
    PlasticDslTopLevelSections

proc splitApplicationBody(
  body: NimNode;
  planBody: var NimNode;
  programBody: var NimNode
) {.compileTime.} =
  ## O corpo depois de `glaucoplastic Nome, application:` é uma área Nim
  ## livre. Somente as seções declarativas conhecidas entram no plano JSON.
  ## Todo o restante é preservado como programação executável da aplicação.
  planBody = newStmtList()
  programBody = newStmtList()

  for declaration in body:
    if declaration.isPlasticDslTopLevelSection():
      planBody.add declaration.copyNimTree

    # Compatibilidade com a versão intermediária:
    #
    #   startup:
    #     ...
    #
    # O conteúdo passa a ser tratado como programação livre.
    elif declaration.kind in {nnkCall, nnkCommand} and
        declaration.len > 0 and
        astDslName(declaration[0]) == "startup":
      if declaration.len < 2 or
          declaration[^1].kind != nnkStmtList:
        error(
          "startup exige um bloco de instruções.",
          declaration
        )

      for statement in declaration[^1]:
        programBody.add statement.copyNimTree

    else:
      programBody.add declaration.copyNimTree

macro glaucoplastic*(
  applicationName: untyped;
  body: untyped
): untyped =
  var planBody: NimNode
  var programBody: NimNode
  splitApplicationBody(
    body,
    planBody,
    programBody
  )

  if programBody.len > 0:
    error(
      "A programação livre exige a forma " &
      "`glaucoplastic Nome, application:`.",
      programBody[0]
    )

  let applicationNameText =
    applicationName.repr

  let serialized =
    $astToPlanJson(planBody)

  let nameLiteral =
    newLit(applicationNameText)

  let planLiteral =
    newLit(serialized)

  result = quote do:
    newPlasticApplication(
      `nameLiteral`,
      `planLiteral`
    )

macro glaucoplastic*(
  applicationName: untyped;
  applicationVariable: untyped;
  body: untyped
): untyped =
  if applicationName.kind notin {
      nnkIdent,
      nnkSym
    }:
    error(
      "O nome da aplicação deve ser um identificador.",
      applicationName
    )

  if applicationVariable.kind notin {
      nnkIdent,
      nnkSym
    }:
    error(
      "A variável da aplicação deve ser um identificador.",
      applicationVariable
    )

  var planBody: NimNode
  var programBody: NimNode
  splitApplicationBody(
    body,
    planBody,
    programBody
  )

  let applicationNameText =
    applicationName.repr

  let serialized =
    $astToPlanJson(planBody)

  let nameLiteral =
    newLit(applicationNameText)

  let planLiteral =
    newLit(serialized)

  let exportedApplicationType =
    postfix(
      applicationName.copyNimTree,
      "*"
    )

  let exportedApplicationVariable =
    postfix(
      applicationVariable.copyNimTree,
      "*"
    )

  let constructor =
    newCall(
      ident("newPlasticApplication"),
      nameLiteral,
      planLiteral
    )

  result = newStmtList()

  result.add newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      exportedApplicationType,
      newEmptyNode(),
      ident("PlasticApplication")
    )
  )

  result.add newTree(
    nnkLetSection,
    newTree(
      nnkIdentDefs,
      exportedApplicationVariable,
      applicationName.copyNimTree,
      constructor
    )
  )

  if programBody.len > 0:
    let applicationReference =
      applicationVariable.copyNimTree

    result.add quote do:
      `applicationReference`.registerProgram(
        proc() =
          `programBody`
      )

macro plasticTree*(body: untyped): untyped =
  ## Ferramenta de diagnóstico para confirmar a AST da DSL, incluindo a forma
  ## `when states.X changed:` na versão de Nim usada pelo projeto.
  echo body.treeRepr
  result = newStmtList()
