import std/[
  base64,
  httpclient,
  json,
  math,
  os,
  osproc,
  streams,
  strformat,
  strutils,
  times
]

type
  TestMode = enum
    modeSystem,
    modePhoneApi,
    modeFile

  Config = object
    mode: TestMode
    durationSeconds: int
    device: string
    inputPath: string
    ffmpegBinary: string
    whisperBinary: string
    whisperModel: string
    language: string
    phoneApi: string
    workDir: string

  WavStats = object
    channels: int
    sampleRate: int
    bitsPerSample: int
    dataBytes: int
    samples: int
    durationSeconds: float
    rms: float
    peak: float
    nonZeroRatio: float
    dcOffset: float

proc usage() =
  echo """
Teste isolado GlaucoPlastic + whisper.cpp

Modos:
  --mode=system
      Captura a fonte Pulse/PipeWire, por padrão glauco_phone_mic.

  --mode=phone-api
      Captura diretamente pela API do audio-phone-speaker em 127.0.0.1:5003.

  --mode=file --input=/caminho/audio.wav
      Testa um arquivo já existente.

Opções:
  --duration=6
  --device=glauco_phone_mic
  --ffmpeg=ffmpeg
  --whisper=/caminho/whisper-cli
  --model=/caminho/ggml-base.bin
  --language=pt
  --phone-api=http://127.0.0.1:5003
  --workdir=/tmp/glaucoplastic-whisper-test
"""

proc envOr(name, fallback: string): string =
  let value = getEnv(name, "").strip
  if value.len > 0: value else: fallback

proc firstExisting(candidates: openArray[string]): string =
  for candidate in candidates:
    let expanded = candidate.expandTilde
    if expanded.len > 0 and fileExists(expanded):
      return expanded
  ""

proc defaultWhisperBinary(): string =
  let configured = getEnv("GLAUCOPLASTIC_WHISPER_BINARY", "").strip
  if configured.len > 0:
    return configured.expandTilde

  result = firstExisting([
    getHomeDir() /
      "dev/glaucoplastic/examples/local_assistant/.runtime/whisper.cpp/build/bin/whisper-cli",
    getHomeDir() /
      "dev/glaucoplastic/examples/local_assistant/.runtime/whisper.cpp/build/bin/main",
    getCurrentDir() / ".runtime/whisper.cpp/build/bin/whisper-cli",
    getCurrentDir() / ".runtime/whisper.cpp/build/bin/main"
  ])

  if result.len == 0:
    result = "whisper-cli"

proc defaultWhisperModel(): string =
  let configured = getEnv("GLAUCOPLASTIC_WHISPER_MODEL", "").strip
  if configured.len > 0:
    return configured.expandTilde

  result = firstExisting([
    getHomeDir() /
      "dev/glaucoplastic/examples/local_assistant/.runtime/whisper.cpp/models/ggml-base.bin",
    getHomeDir() /
      "dev/glaucoplastic/examples/local_assistant/.runtime/whisper.cpp/models/ggml-small.bin",
    getCurrentDir() / ".runtime/whisper.cpp/models/ggml-base.bin",
    getCurrentDir() / ".runtime/whisper.cpp/models/ggml-small.bin"
  ])

proc parseMode(value: string): TestMode =
  case value.toLowerAscii
  of "system":
    modeSystem
  of "phone-api", "phone", "adb":
    modePhoneApi
  of "file":
    modeFile
  else:
    raise newException(ValueError, "Modo inválido: " & value)

proc parseConfig(): Config =
  result.mode = modeSystem
  result.durationSeconds = 6
  result.device = envOr(
    "GLAUCOPLASTIC_VOICE_INPUT_DEVICE",
    "glauco_phone_mic"
  )
  result.ffmpegBinary = envOr(
    "GLAUCOPLASTIC_FFMPEG_BINARY",
    "ffmpeg"
  )
  result.whisperBinary = defaultWhisperBinary()
  result.whisperModel = defaultWhisperModel()
  result.language = envOr(
    "GLAUCOPLASTIC_WHISPER_LANGUAGE",
    "pt"
  )
  result.phoneApi = envOr(
    "PHONE_MIC_CONTROL_URL",
    "http://127.0.0.1:5003"
  )

  let stamp = now().format("yyyyMMdd-HHmmss")
  result.workDir =
    getTempDir() / ("glaucoplastic-whisper-test-" & stamp)

  for parameter in commandLineParams():
    if parameter in ["--help", "-h"]:
      usage()
      quit(0)
    elif parameter.startsWith("--mode="):
      result.mode = parseMode(
        parameter["--mode=".len .. ^1]
      )
    elif parameter.startsWith("--duration="):
      result.durationSeconds = parseInt(
        parameter["--duration=".len .. ^1]
      )
    elif parameter.startsWith("--device="):
      result.device =
        parameter["--device=".len .. ^1]
    elif parameter.startsWith("--input="):
      result.inputPath =
        parameter["--input=".len .. ^1].expandTilde
    elif parameter.startsWith("--ffmpeg="):
      result.ffmpegBinary =
        parameter["--ffmpeg=".len .. ^1].expandTilde
    elif parameter.startsWith("--whisper="):
      result.whisperBinary =
        parameter["--whisper=".len .. ^1].expandTilde
    elif parameter.startsWith("--model="):
      result.whisperModel =
        parameter["--model=".len .. ^1].expandTilde
    elif parameter.startsWith("--language="):
      result.language =
        parameter["--language=".len .. ^1]
    elif parameter.startsWith("--phone-api="):
      result.phoneApi =
        parameter["--phone-api=".len .. ^1].strip(chars = {'/'})
    elif parameter.startsWith("--workdir="):
      result.workDir =
        parameter["--workdir=".len .. ^1].expandTilde
    else:
      raise newException(
        ValueError,
        "Argumento desconhecido: " & parameter
      )

  if result.durationSeconds < 1 or
      result.durationSeconds > 120:
    raise newException(
      ValueError,
      "--duration deve estar entre 1 e 120."
    )

  if result.mode == modeFile and
      result.inputPath.len == 0:
    raise newException(
      ValueError,
      "--mode=file exige --input=/caminho/audio."
    )

proc runProcess(
  executable: string;
  arguments: seq[string]
): tuple[exitCode: int, output: string] =
  let process = startProcess(
    executable,
    args = arguments,
    options = {
      poUsePath,
      poStdErrToStdOut
    }
  )

  try:
    result.exitCode = waitForExit(process)
    let output = process.outputStream
    if not output.isNil:
      result.output = output.readAll()
  finally:
    close(process)

proc captureSystem(
  config: Config;
  outputPath: string
) =
  echo &"[capture] Fonte do sistema: {config.device}"
  echo &"[capture] Duração: {config.durationSeconds}s"

  let arguments = @[
    "-hide_banner",
    "-loglevel", "info",
    "-y",
    "-f", "pulse",
    "-i", config.device,
    "-t", $config.durationSeconds,
    "-ar", "16000",
    "-ac", "1",
    "-c:a", "pcm_s16le",
    outputPath
  ]

  let execution = runProcess(
    config.ffmpegBinary,
    arguments
  )

  echo execution.output

  if execution.exitCode != 0:
    raise newException(
      OSError,
      "FFmpeg falhou ao capturar a fonte do sistema."
    )

proc phoneApiRequest(
  client: HttpClient;
  url: string;
  method = HttpPost
): JsonNode =
  let response = client.request(
    url,
    httpMethod = method
  )

  if response.code.int < 200 or
      response.code.int >= 300:
    raise newException(
      IOError,
      &"HTTP {response.code.int} em {url}: {response.body}"
    )

  parseJson(response.body)

proc capturePhoneApi(
  config: Config;
  outputPath: string
) =
  let client = newHttpClient(
    timeout = (config.durationSeconds + 15) * 1000
  )

  try:
    echo &"[capture] API direta: {config.phoneApi}"
    let status = phoneApiRequest(
      client,
      config.phoneApi & "/status",
      HttpGet
    )

    echo "[capture] Status:"
    echo status.pretty

    if not status{"phoneConnected"}.getBool(false):
      raise newException(
        IOError,
        "O celular não está conectado ao bridge."
      )

    discard phoneApiRequest(
      client,
      config.phoneApi & "/record/start"
    )

    echo &"[capture] Fale por {config.durationSeconds}s..."
    sleep(config.durationSeconds * 1000)

    let stopped = phoneApiRequest(
      client,
      config.phoneApi & "/record/stop"
    )

    if not stopped{"ok"}.getBool(false):
      raise newException(
        IOError,
        stopped{"error"}.getStr(
          "A API não retornou áudio."
        )
      )

    let encoded = stopped{"data"}.getStr
    if encoded.len == 0:
      raise newException(
        IOError,
        "A API retornou data vazia."
      )

    writeFile(outputPath, decode(encoded))

    let receivedBytes =
      stopped{"bytes"}.getInt(0)

    echo &"[capture] WAV direto: {outputPath}"
    echo &"[capture] Bytes HTTP: {receivedBytes}"

  finally:
    client.close()

proc copyInput(
  config: Config;
  outputPath: string
) =
  if not fileExists(config.inputPath):
    raise newException(
      IOError,
      "Arquivo não encontrado: " & config.inputPath
    )

  copyFile(config.inputPath, outputPath)
  echo &"[capture] Arquivo copiado: {config.inputPath}"

proc u16le(data: string; offset: int): int =
  ord(data[offset]) or
    (ord(data[offset + 1]) shl 8)

proc u32le(data: string; offset: int): int =
  ord(data[offset]) or
    (ord(data[offset + 1]) shl 8) or
    (ord(data[offset + 2]) shl 16) or
    (ord(data[offset + 3]) shl 24)

proc analyzeWav(path: string): WavStats =
  let data = readFile(path)

  if data.len < 44 or
      data[0 .. 3] != "RIFF" or
      data[8 .. 11] != "WAVE":
    raise newException(
      ValueError,
      "Arquivo não é RIFF/WAVE válido: " & path
    )

  var offset = 12
  var dataOffset = -1
  var dataLength = 0
  var audioFormat = 0

  while offset + 8 <= data.len:
    let chunkId = data[offset .. offset + 3]
    let chunkLength = u32le(data, offset + 4)
    let chunkData = offset + 8

    if chunkData + chunkLength > data.len:
      break

    case chunkId
    of "fmt ":
      if chunkLength >= 16:
        audioFormat = u16le(data, chunkData)
        result.channels = u16le(data, chunkData + 2)
        result.sampleRate = u32le(data, chunkData + 4)
        result.bitsPerSample = u16le(
          data,
          chunkData + 14
        )
    of "data":
      dataOffset = chunkData
      dataLength = chunkLength
      break
    else:
      discard

    offset = chunkData + chunkLength
    if (chunkLength and 1) == 1:
      inc offset

  if audioFormat != 1:
    raise newException(
      ValueError,
      "O analisador espera PCM linear; formato=" &
        $audioFormat
    )

  if result.bitsPerSample != 16:
    raise newException(
      ValueError,
      "O analisador espera PCM16; bits=" &
        $result.bitsPerSample
    )

  if dataOffset < 0 or dataLength < 2:
    raise newException(
      ValueError,
      "Chunk data ausente ou vazio."
    )

  result.dataBytes = dataLength
  result.samples = dataLength div 2

  if result.sampleRate > 0 and
      result.channels > 0:
    result.durationSeconds =
      result.samples.float /
      result.channels.float /
      result.sampleRate.float

  var sumSquares = 0.0
  var sum = 0.0
  var peak = 0.0
  var nonZero = 0
  var cursor = dataOffset
  let endOffset = min(
    data.len,
    dataOffset + dataLength
  )

  while cursor + 1 < endOffset:
    var raw = u16le(data, cursor)
    if raw >= 32768:
      raw -= 65536

    let normalized = raw.float / 32768.0
    let absolute = abs(normalized)

    sumSquares += normalized * normalized
    sum += normalized

    if absolute > peak:
      peak = absolute
    if raw != 0:
      inc nonZero

    cursor += 2

  if result.samples > 0:
    result.rms = sqrt(
      sumSquares / result.samples.float
    )
    result.dcOffset =
      sum / result.samples.float
    result.nonZeroRatio =
      nonZero.float / result.samples.float

  result.peak = peak

proc printStats(label, path: string; stats: WavStats) =
  echo ""
  echo &"[audio] {label}: {path}"
  echo &"[audio] canais={stats.channels}"
  echo &"[audio] sampleRate={stats.sampleRate}"
  echo &"[audio] bits={stats.bitsPerSample}"
  echo &"[audio] duração={stats.durationSeconds:.3f}s"
  echo &"[audio] rms={stats.rms:.6f}"
  echo &"[audio] peak={stats.peak:.6f}"
  echo &"[audio] nonZero={stats.nonZeroRatio:.6f}"
  echo &"[audio] dcOffset={stats.dcOffset:.6f}"

  if stats.rms < 0.001:
    echo "[audio][AVISO] Sinal praticamente silencioso."
  elif stats.rms < 0.004:
    echo "[audio][AVISO] Sinal muito baixo; o Whisper pode alucinar."
  elif stats.peak >= 0.999:
    echo "[audio][AVISO] Possível clipping."

proc normalizeAudio(
  config: Config;
  sourcePath, preparedPath: string
) =
  let arguments = @[
    "-hide_banner",
    "-loglevel", "info",
    "-y",
    "-i", sourcePath,
    "-af",
    "highpass=f=80,lowpass=f=7600,dynaudnorm=f=150:g=15",
    "-ar", "16000",
    "-ac", "1",
    "-c:a", "pcm_s16le",
    preparedPath
  ]

  let execution = runProcess(
    config.ffmpegBinary,
    arguments
  )

  echo execution.output

  if execution.exitCode != 0:
    raise newException(
      OSError,
      "FFmpeg falhou ao preparar o áudio."
    )

proc runWhisper(
  config: Config;
  preparedPath, outputPrefix: string
): string =
  if config.whisperModel.len == 0 or
      not fileExists(config.whisperModel):
    raise newException(
      IOError,
      "Modelo Whisper não encontrado. Use --model=... ou " &
      "GLAUCOPLASTIC_WHISPER_MODEL."
    )

  let binary =
    if fileExists(config.whisperBinary):
      config.whisperBinary
    else:
      findExe(config.whisperBinary)

  if binary.len == 0:
    raise newException(
      IOError,
      "whisper-cli não encontrado. Use --whisper=... ou " &
      "GLAUCOPLASTIC_WHISPER_BINARY."
    )

  echo ""
  echo &"[whisper] binário: {binary}"
  echo &"[whisper] modelo:  {config.whisperModel}"
  echo &"[whisper] áudio:   {preparedPath}"

  let arguments = @[
    "-m", config.whisperModel,
    "-f", preparedPath,
    "-l", config.language,
    "-otxt",
    "-of", outputPrefix
  ]

  let execution = runProcess(
    binary,
    arguments
  )

  echo execution.output

  if execution.exitCode != 0:
    raise newException(
      OSError,
      "whisper.cpp terminou com código " &
        $execution.exitCode
    )

  let transcriptPath = outputPrefix & ".txt"
  if fileExists(transcriptPath):
    result = readFile(transcriptPath).strip

proc main() =
  let config = parseConfig()

  createDir(config.workDir)

  let sourcePath =
    config.workDir / "source.wav"
  let preparedPath =
    config.workDir / "prepared.wav"
  let outputPrefix =
    config.workDir / "transcript"

  echo &"[test] diretório: {config.workDir}"
  echo &"[test] modo: {config.mode}"

  case config.mode
  of modeSystem:
    captureSystem(config, sourcePath)
  of modePhoneApi:
    capturePhoneApi(config, sourcePath)
  of modeFile:
    copyInput(config, sourcePath)

  let sourceStats = analyzeWav(sourcePath)
  printStats("capturado", sourcePath, sourceStats)

  normalizeAudio(
    config,
    sourcePath,
    preparedPath
  )

  let preparedStats = analyzeWav(preparedPath)
  printStats(
    "preparado",
    preparedPath,
    preparedStats
  )

  let transcript = runWhisper(
    config,
    preparedPath,
    outputPrefix
  )

  echo ""
  echo "================ TRANSCRIÇÃO ================"
  if transcript.len > 0:
    echo transcript
  else:
    echo "(vazia)"
  echo "=============================================="
  echo ""
  echo "[test] Arquivos preservados para inspeção:"
  echo "  " & sourcePath
  echo "  " & preparedPath
  echo "  " & outputPrefix & ".txt"

when isMainModule:
  try:
    main()
  except CatchableError as error:
    stderr.writeLine("[ERRO] " & error.msg)
    quit(1)
