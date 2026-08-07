# GlaucoPlastic — thin Nimble tasks.
# Toda operação de filesystem/build fica fora do VM NimScript.

import std/strutils

const gpTasksSource =
  currentSourcePath().replace('\\', '/')

const gpNimbleMarker = "/nimble/"
const gpMarkerPos = gpTasksSource.rfind(gpNimbleMarker)

when gpMarkerPos < 0:
  {.error: "glaucoplastic_tasks.nims deve estar em <glaucoplastic>/nimble/".}

const gpFrameworkRoot =
  gpTasksSource[0 ..< gpMarkerPos]

proc gpQuote(value: string): string =
  "'" & value.replace("'", "'\"'\"'") & "'"

proc gpRun(command: string) =
  let script =
    gpFrameworkRoot &
    "/scripts/glaucoplastic-project-build.sh"

  exec(
    "bash " &
    gpQuote(script) & " " &
    gpQuote(command) & " " &
    gpQuote(glaucoplasticApplication)
  )

task devLinux, "Compila o executável Linux de desenvolvimento":
  gpRun("dev-linux")

task devWindows, "Cross-compila o executável Windows de desenvolvimento":
  gpRun("dev-windows")

task dev, "Compila Linux e Windows de desenvolvimento":
  gpRun("dev")

task buildLinux, "Gera o bundle Linux completo com runtime e Metis":
  gpRun("build-linux")

task buildWindows, "Gera o bundle Windows completo com runtime e Metis":
  gpRun("build-windows")

task build, "Gera os bundles completos Linux e Windows":
  gpRun("build")

task webBuild, "Compila o servidor web headless":
  gpRun("web-build")

task web, "Compila e executa o servidor web headless":
  gpRun("web")

task verifyBundle, "Valida os bundles completos":
  gpRun("verify")
