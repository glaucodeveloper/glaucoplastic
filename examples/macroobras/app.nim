import std/[json, os, strutils]
import glaucoplastic

glaucoplastic MacroObras, macroObras:
  product:
    title "MacroObras"
    description "Administração integrada de obras"
    version "1.0.0"

  installation:
    windowsMsi:
      productName "MacroObras"
      manufacturer "Glauco Developer"
      version "1.0.0"
      upgradeCode "D5752383-57A9-577E-B90D-F9D865A14A53"
      scope perUser
      executable "MacroObras.exe"

      installDirectory:
        root localAppDataPrograms
        path "MacroObras"

      applicationData:
        root localAppData
        path "MacroObras"
        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"

      package:
        file "runtime/llama/windows-x64/bin/llama-server.exe", destination = "runtime/llama/llama-server.exe"
        glob "runtime/llama/windows-x64/bin/*.dll", destination = "runtime/llama"
        file "~/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf", destination = "models/Qwen3-4B-Q4_K_M.gguf"

      shortcut:
        desktop true
        startMenu true

  orm:
    Obra:
      id integer primary
      nome string
      endereco string
      orcamento money

  okfs:
    Obras:
      purpose "Conhecimento estrutural e operacional das obras."

  components:
    Painel(titulo, estado):
      visual = {
        titulo: titulo + " — MacroObras",
        estado: estado,
        contador: 1
      }

      render:
        section(part = Root, class = "container"):
          h1(part = Titulo) visual.titulo
          span(part = Estado) visual.estado
          divi(part = Resultado)

          foreign(
            part = Documentacao,
            url = "https://example.com",
            class = "documentacao-webcontents"
          ):
            statusCss:
              loading ":host { opacity: .6; }"
              ready ":host { opacity: 1; }"
              failed ":host { outline: 1px solid red; }"

            documentStart:
              evalJs "window.__GLAUCOPLASTIC_FOREIGN__ = true;"

            when loaded:
              discard

    CartaoObra(obra):
      render:
        article(part = Root, class = "obra-card"):
          h2(part = Nome) obra.nome
          span(part = Orcamento) obra.orcamento

  states:
    ObraSelecionada Obra:
      id 0
      nome ""
      endereco ""
      orcamento 0.0

    EstadoAnalise string = "ocioso"
    ResultadoAnalise json

    when states.ObraSelecionada changed:
      render:
        CartaoObra(states.ObraSelecionada)

    when states.EstadoAnalise == "executando":
      Painel.Resultado.innerHTML = "Analisando..."

  agents:
    Analista(
      "analista-administrativo",
      especialidade = "obras",
      okfPrincipal = Obras,
      podeNavegar = true
    ):
      purpose """
        Analise a obra selecionada usando ORM, memória Git e OKF.
      """

      render:
        section(class = "agent-status"):
          span "Analista disponível"

      when states.ObraSelecionada changed:
        let obra = orm.Obra.find(states.ObraSelecionada.id)
        render:
          span obra.nome

  render:
    Painel("Balanço das obras", states.EstadoAnalise)

proc runMacroObras*() =
  macroObras.validateInstallation()
  macroObras.run(startModel = false)

when isMainModule:
  if "--prepare-dev" in commandLineParams():
    macroObras.validateInstallation()
    echo "Layout de desenvolvimento preparado em: ", macroObras.installation.dataRoot
  elif "--manifest" in commandLineParams():
    macroObras.writeInstallerManifest("build/windows-msi/installer.json")
    echo "Manifesto emitido."
  elif "--show-plan" in commandLineParams():
    echo macroObras.planJson
  else:
    runMacroObras()
    echo "Aplicação carregada: ", macroObras.name
    echo "Estados: ", macroObras.states.snapshot().pretty
    echo "Componentes: ", macroObras.components.pretty
    echo "Render: ", macroObras.renderTree.pretty
    macroObras.close()
