import std/os
import glaucoplastic

glaucoplastic ConsumerApplication, application:
  product:
    title "Consumer Macro Integral"
    description "Exemplo do GlaucoPlastic entregue integralmente pela macro."
    version "0.2.0"

  installation:
    windowsMsi:
      productName "Consumer Macro Integral"
      manufacturer "GlaucoPlastic"
      version "0.2.0"
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
        style = "flex:1;min-height:0;margin-top:0"
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
          style = "display:flex;flex:1;min-height:0"
        ):
          portal

    Home(titulo):
      render:
        main(
          part = Root,
          style = "display:flex;flex-direction:column;height:100vh;padding:16px;gap:12px;overflow:hidden;background:#f8fafc;color:#0f172a"
        ):
          h1(
            part = Titulo,
            style = "margin:0;font-size:22px"
          ) titulo

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
    Titulo string = "Consumer Macro Integral"
    Url string = "https://example.com"
    UrlDigitada string = "https://example.com"

    when states.Titulo changed:
      Home.Titulo.textContent = states.Titulo

    when states.Url changed:
      states.Url changes states.UrlDigitada
      Home.BarraUrl.value = states.Url

  agents:
    Assistente("assistente-geral", okfPrincipal = Geral):
      purpose "Use estados, ORM, OKF, memória Git, foreign e llama.cpp."

  render:
    Home(states.Titulo)

proc run*() =
  application.prepareDevelopmentLayout()
  application.run(startModel = false)

when isMainModule:
  if "--prepare-dev" in commandLineParams():
    application.prepareDevelopmentLayout()
  elif "--manifest" in commandLineParams():
    application.writeInstallerManifest(
      "build/windows-msi/installer.json"
    )
  else:
    run()
