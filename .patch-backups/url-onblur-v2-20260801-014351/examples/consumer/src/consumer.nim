import std/os
import glaucoplastic

let application* = glaucoplastic ConsumerApplication:
  product:
    title "Consumer Application"
    version "0.1.0"

  installation:
    windowsMsi:
      productName "Consumer Application"
      manufacturer "Example"
      version "0.1.0"
      upgradeCode "4BE35814-4F03-4DDA-935D-7117C115EA9B"
      scope perUser
      executable "consumer.exe"

      installDirectory:
        root localAppDataPrograms
        path "ConsumerApplication"

      applicationData:
        root localAppData
        path "ConsumerApplication"
        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"

  okfs:
    Geral:
      purpose "Conhecimento geral da aplicação."

  components:
    Home(titulo, url):
      render:
        main(
          part = Root,
          style = "display:flex;flex-direction:column;height:100vh;padding:16px;gap:12px;overflow:hidden"
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
              `aria-label` = "Voltar",
              style = "min-width:42px;height:38px",
              onClick = Home.Portal.goBack()
            ) "←"

            button(
              part = Avancar,
              type = "button",
              title = "Avançar",
              `aria-label` = "Avançar",
              style = "min-width:42px;height:38px",
              onClick = Home.Portal.goForward()
            ) "→"

            button(
              part = Recarregar,
              type = "button",
              title = "Recarregar",
              `aria-label` = "Recarregar",
              style = "min-width:42px;height:38px",
              onClick = Home.Portal.reload()
            ) "↻"

            input(
              part = Url,
              type = "url",
              value = url,
              `bind` = states.Url,
              onEnter = Home.Portal.navigate(states.Url),
              placeholder = "Digite uma URL",
              autocomplete = "off",
              spellcheck = "false",
              `aria-label` = "Endereço da página",
              style = "flex:1;min-width:0;height:38px;padding:0 12px"
            )

            button(
              part = Ir,
              type = "button",
              title = "Abrir endereço",
              style = "height:38px;padding:0 18px",
              onClick = Home.Portal.navigate(states.Url)
            ) "Ir"

          # Um URL visível na inicialização evita a impressão de tela vazia.
          # `about:blank` continua sendo o fallback quando o estado fica vazio.
          # `binds` liga a propriedade URL do elemento foreign ao estado nas
          # duas direções: estado -> navegação e navegação -> estado.
          foreign(
            part = Portal,
            url = binds states.Url,
            title = "Conteúdo web",
            style = "flex:1;min-height:0;margin-top:0"
          ):
            statusCss:
              loading ":host { opacity: .55; }"
              ready ":host { opacity: 1; }"
              failed ":host { outline: 1px solid red; }"

  states:
    Titulo string = "Consumer Application"
    Url string = "https://example.com"

    when states.Titulo changed:
      Home.Titulo.textContent = states.Titulo

  agents:
    Assistente("assistente-geral", okfPrincipal = Geral):
      purpose "Auxilie o usuário usando os estados, ORM, Git e OKF."

  render:
    Home(states.Titulo, states.Url)

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
