import std/[json, os, strformat, tables]
import glaucoplastic

glaucoplastic ConsumerApplication, application:

  # ---------------------------------------------------------------
  # PROGRAMAÇÃO NIM LIVRE DA APLICAÇÃO
  # ---------------------------------------------------------------
  # Esta área não é uma seção especial da DSL. `let`, `if`, `for`,
  # chamadas, objetos JSON e procedimentos locais são código Nim normal.

  # Perfil persistente compartilhado pelo frontend e por todos os foreign.
  application.webview().configureUserFolder(
    application.installation().dataRoot /
      "webview" /
      "Default"
  )

  let orm = application.orm()

  if orm.whereEq(
      "Documento",
      "url",
      %"https://example.com"
    ).len == 0:
    discard orm.insert(
      "Documento",
      %*{
        "titulo": "Documento inicial",
        "url": "https://example.com"
      }
    )

  let okf = application.okf()

  discard okf.persist(
    %*{
      "id": "consumer-bootstrap",
      "space": "Geral",
      "title": "Inicialização do consumer",
      "summary": "ORM, OKF, Git memory, foreign, RLM, agente, frontend e llama.cpp foram instanciados pelo macro."
    }
  )

  let gitSnapshot =
    application.gitMemory().capture()

  let technologyStatus = fmt"""
  ORM={application.orm().count("Documento")} documento(s)
  OKF={application.okf().list("Geral").len} item(ns)
  Git={gitSnapshot.branch}
  Foreign={application.foreign().elements.len}
  RLM={application.rlm().capabilities.len} capabilities
  Agents={application.agents().len}
  Components={application.components().len}
  WebViewUserFolder={application.webview().userFolder}
  Llama={application.llama().endpoint}
  """

  application.states().set(
    "Tecnologias",
    %technologyStatus
  )

  product:
    title "Consumer Macro Integral Funcional"
    description "Exemplo com frontend, database, OKF, memória Git, foreign, RLM, agente e llama.cpp."
    version "0.3.0"

  installation:
    windowsMsi:
      productName "Consumer Macro Integral Funcional"
      manufacturer "GlaucoPlastic"
      version "0.3.0"
      upgradeCode "854047E8-CA27-4AC5-83E8-61E992931420"
      scope perUser
      executable "consumer-macro-integral.exe"

      installDirectory:
        root localAppDataPrograms
        path "ConsumerMacroIntegral"

      applicationData:
        root localAppData
        path "ConsumerMacroIntegral"
        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"
        createDirectory "webview/Default"
        createDirectory "webview/Default/data"
        createDirectory "webview/Default/cache"

  orm:
    Documento:
      titulo string
      url string

  okfs:
    Geral:
      purpose "Conhecimento geral produzido e consultado pela aplicação."

  components:
    PortalWeb():
      portal = foreign(
        part = Portal,
        url = binds states.Url,
        title = "Conteúdo web",
        style = "display:block;flex:1;min-height:420px;width:100%;margin-top:0"
      ):
        statusCss:
          loading ":host { opacity: .55; }"
          ready ":host { opacity: 1; }"
          failed ":host { outline: 2px solid #dc2626; }"

      when portal loaded:
        portal.evalJs """
          (() => {
            if (!document.body) return null;

            const hue = Math.floor(Math.random() * 360);
            const saturation = 55 + Math.floor(Math.random() * 26);
            const lightness = 82 + Math.floor(Math.random() * 11);
            const color =
              `hsl(${hue} ${saturation}% ${lightness}%)`;

            document.body.style.backgroundColor = color;
            return color;
          })()
        """

      render:
        section(
          part = PortalFrame,
          style = "display:flex;flex:1;min-height:420px;width:100%;background:#ffffff;border:1px solid #cbd5e1;border-radius:12px;overflow:hidden"
        ):
          portal

    Home(titulo, tecnologias):
      render:
        main(
          part = Root,
          style = "display:flex;flex-direction:column;min-height:100vh;padding:16px;gap:12px;overflow:hidden;background:#f8fafc;color:#0f172a"
        ):
          header(
            part = Cabecalho,
            style = "display:flex;flex-direction:column;gap:4px"
          ):
            h1(
              part = Titulo,
              style = "margin:0;font-size:22px"
            ) titulo

            p(
              part = Tecnologias,
              style = "margin:0;padding:10px 12px;border-radius:8px;background:#e2e8f0;font-family:monospace;font-size:12px;white-space:pre-wrap"
            ) tecnologias

          nav(
            part = Navegacao,
            style = "display:flex;align-items:center;gap:8px;width:100%"
          ):
            button(
              part = Voltar,
              type = "button",
              title = "Voltar",
              style = "min-width:42px;height:38px",
              onClick = PortalWeb.portal.goBack()
            ) "←"

            button(
              part = Avancar,
              type = "button",
              title = "Avançar",
              style = "min-width:42px;height:38px",
              onClick = PortalWeb.portal.goForward()
            ) "→"

            button(
              part = Recarregar,
              type = "button",
              title = "Recarregar",
              style = "min-width:42px;height:38px",
              onClick = PortalWeb.portal.reload()
            ) "↻"

            input(
              part = BarraUrl,
              type = "url",
              value = states.UrlDigitada,
              onBlur = eventValue changes states.UrlDigitada,
              placeholder = "Digite uma URL",
              autocomplete = "on",
              spellcheck = "false",
              style = "flex:1;min-width:0;height:38px;padding:0 12px"
            )

            button(
              part = Ir,
              type = "button",
              title = "Abrir endereço",
              style = "height:38px;padding:0 18px",
              onClick = states.UrlDigitada changes states.Url
            ) "Ir"

          PortalWeb()

  states:
    Titulo string = "Consumer Macro Integral Funcional"
    Tecnologias string = "Inicializando runtimes..."
    Url string = "https://example.com"
    UrlDigitada string = "https://example.com"

    when states.Titulo changed:
      Home.Titulo.textContent = states.Titulo

    when states.Tecnologias changed:
      Home.Tecnologias.textContent = states.Tecnologias

    when states.Url changed:
      states.Url changes states.UrlDigitada
      Home.BarraUrl.value = states.Url

  agents:
    Assistente("assistente-geral", okfPrincipal = Geral):
      purpose "Use estados, ORM, OKF, memória Git, foreign, RLM e llama.cpp para auxiliar a aplicação."

  render:
    Home(states.Titulo, states.Tecnologias)

proc run*() =
  application.prepareDevelopmentLayout()

  let startModel =
    getEnv(
      "GLAUCOPLASTIC_START_MODEL",
      "1"
    ) != "0"

  application.run(
    startModel = startModel
  )

when isMainModule:
  if "--prepare-dev" in commandLineParams():
    application.prepareDevelopmentLayout()

  elif "--manifest" in commandLineParams():
    application.writeInstallerManifest(
      "build/windows-msi/installer.json"
    )

  elif "--runtime-summary" in commandLineParams():
    application.prepareDevelopmentLayout()

    echo pretty(
      application.initializeTechnologies(
        startModel = false
      )
    )

  else:
    run()
