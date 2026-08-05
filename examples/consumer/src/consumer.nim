import std/[json, os, strutils]
import glaucoplastic
import youtube_card_module

proc consumerTrace(message: string) =
  try:
    let path = "/tmp/consumer-entry.log"
    let previous =
      if fileExists(path):
        readFile(path)
      else:
        ""

    writeFile(path, previous & message & "\n")
  except CatchableError:
    discard

glaucoplastic ConsumerApplication, application:

  # ---------------------------------------------------------------
  # PROGRAMA NIM LIVRE DA APLICAÇÃO
  # ---------------------------------------------------------------
  # Esta area nao e uma sessao especial da DSL. `let`, `if`, `for`,
  # chamadas, JSON e procedimentos locais sao Nim normal.

  consumerTrace("startup: before configureUserFolder")
  block:
    let webviewRuntime = application.webview()
    webviewRuntime.userFolder =
      application.installation().dataRoot / "webview" / "Default"
    webviewRuntime.dataFolder = webviewRuntime.userFolder / "data"
    webviewRuntime.cacheFolder = webviewRuntime.userFolder / "cache"
    webviewRuntime.cookiesPath = webviewRuntime.userFolder / "cookies.sqlite"
    webviewRuntime.persistent = true
    webviewRuntime.configured = true
  consumerTrace("startup: after configureUserFolder")

  consumerTrace("startup: before configureCompatibility")
  block:
    let webviewRuntime = application.webview()
    webviewRuntime.persistentCookies = true
    webviewRuntime.acceptThirdPartyCookies = true
    webviewRuntime.safeGraphics = true
    webviewRuntime.configured = true
  consumerTrace("startup: after configureCompatibility")

  product:
    title "Consumer YouTube Search"
    description "Exemplo com entidades de dominio, hooks `when`, foreign e RLM executando JS para buscar titulos no YouTube."
    version "0.4.0"

  config:
    okfPath ".glauco/okf/youtube-results-demo"

  installation:
    windowsMsi:
      productName "Consumer YouTube Search"
      manufacturer "GlaucoPlastic"
      version "0.4.0"
      upgradeCode "854047E8-CA27-4AC5-83E8-61E992931420"
      scope perUser
      executable "consumer-youtube-search.exe"

      installDirectory:
        root localAppDataPrograms
        path "ConsumerYouTubeSearch"

      applicationData:
        root localAppData
        path "ConsumerYouTubeSearch"
        createDirectory "data"
        createDirectory "okf"
        createDirectory "webview/Default"
        createDirectory "webview/Default/data"
        createDirectory "webview/Default/cache"

  orm:
    Pesquisa:
      termo string
      url string
      titulos string

  okfs:
    Geral:
      purpose "Conhecimento geral de trabalho do consumer."
      owner "Consumer"
      scope "app"

    YoutubeResultados:
      purpose "Espaço de demonstração para registrar consultas, títulos, links e metadados da página de resultados do YouTube."
      source "YouTube results page"
      registry "public metadata only"
      captureMode "dom-query"

      Captura:
        purpose "Coleta os elementos `ytd-video-renderer` e seus links públicos."
        selector "ytd-video-renderer"
        titleSelector "a#video-title"
        filters "title, ariaLabel, href"

      Selecao:
        purpose "Escolhe o melhor link para a query do usuario com inferencia."
        inputs "query, items"
        outputs "selectedTitle, selectedHref, notes, needsMoreResults"

      Registro:
        purpose "Armazena a analise final no diretório OKF configurado."
        format "json"
        retention "local"

  modules:
    YoutubeCardModule

  states:
    Title isset "Consumer YouTube Search"
    BootPhase isset "Inicializando runtime"
    BootConnection isset "Verificando llama-server..."
    BootModel isset "Localizando modelos incluídos..."
    BootProgress isset "0%"
    BootDetail isset "A tela de carregamento aguarda o handshake do runtime."
    Search isset {
      query: "public domain audio",
      url: "https://www.youtube.com/results?search_query=public+domain+audio",
      status: "Digite um termo e pressione Buscar.",
      results: "Nenhum resultado carregado.",
      selectedTitle: "",
      selectedHref: "",
      candidates: {
        pageTitle: "",
        url: "",
        readyState: "",
        count: 0,
        items: []
      },
      collectionVersion: 0,
      requested: 0
    }

    when Title changed:
      Home.Title.textContent = states.Title

    when Search changed:
      Home.SearchQueryInput.value = states.Search.query
      Home.SearchUrlValue.textContent = states.Search.url
      Home.SearchStatusValue.textContent = states.Search.status
      Home.SearchSelectedTitleValue.textContent = states.Search.selectedTitle

  components:
    BootScreen(phase, connection, model, progress, detail):
      render:
        main BootOverlay(
          style = (if phase == "Pronto":
            "display:none"
          else:
            "display:flex;flex-direction:column;justify-content:center;align-items:center;min-height:100vh;padding:24px;background:radial-gradient(circle at 50% 0%,rgba(255,255,255,0.05) 0%,rgba(255,255,255,0) 22%),linear-gradient(180deg,#202020 0%,#202020 62%,#2b3550 100%);color:#f4f4f4;box-shadow:inset 0 3px 0 rgba(97,154,255,0.42)")
        ):
          section BootCard(
            style = "display:flex;flex-direction:column;gap:16px;max-width:720px;width:100%;padding:30px 32px 28px;border-radius:14px;border:1px solid rgba(244,244,244,0.08);background:rgba(42,42,42,0.96);box-shadow:0 22px 80px rgba(0,0,0,0.34)"
          ):
            p BootTag(
              style = "margin:0;font-size:11px;letter-spacing:.22em;text-transform:uppercase;color:#bdbdbd"
            ) "GlaucoPlastic / boot"
            h1 BootTitle(
              style = "margin:0;font-size:29px;line-height:1.14;font-weight:600;letter-spacing:-0.03em;color:#f4f4f4"
            ) phase
            divi BootTelemetry(
              style = "display:flex;flex-direction:column;gap:10px"
            ):
              divi BootTelemetryRow(
                style = "display:flex;flex-direction:column;gap:4px;padding:10px 12px;border-radius:10px;background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.05)"
              ):
                p BootTelemetryLabel(
                  style = "margin:0;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#bdbdbd"
                ) "Conexão"
                p BootStatusValue(
                  style = "margin:0;font-size:16px;line-height:1.5;color:#f4f4f4"
                ) connection

              divi BootTelemetryRow(
                style = "display:flex;flex-direction:column;gap:4px;padding:10px 12px;border-radius:10px;background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.05)"
              ):
                p BootTelemetryLabel(
                  style = "margin:0;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#bdbdbd"
                ) "Modelo"
                p BootModelValue(
                  style = "margin:0;font-size:14px;line-height:1.55;color:#f4f4f4;word-break:break-word"
                ) model

              divi BootTelemetryRow(
                style = "display:flex;flex-direction:column;gap:4px;padding:10px 12px;border-radius:10px;background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.05)"
              ):
                p BootTelemetryLabel(
                  style = "margin:0;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#bdbdbd"
                ) "Detalhe"
                p BootHint(
                  style = "margin:0;font-size:12px;line-height:1.6;color:#d0d0d0;max-width:64ch"
                ) detail
            divi BootMeter(
              style = "display:flex;flex-direction:column;gap:8px"
            ):
              divi BootProgressHeader(
                style = "display:flex;justify-content:space-between;align-items:baseline;gap:12px"
              ):
                p BootProgressLabel(
                  style = "margin:0;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#bdbdbd"
                ) "Progresso"
                p BootProgressValue(
                  style = "margin:0;font-size:18px;line-height:1.2;font-weight:600;color:#f4f4f4;font-variant-numeric:tabular-nums"
                ) progress

              divi BootTrack(
                style = "height:8px;border-radius:999px;background:rgba(244,244,244,0.09);overflow:hidden"
              ):
                divi BootFill(
                  style =
                    "height:100%;width:100%;transform-origin:left center;" &
                    "transform:scaleX(" &
                    formatFloat(
                      clamp(
                        parseFloat(progress.replace("%", "").strip()) / 100.0,
                        0.0,
                        1.0
                      ),
                      ffDecimal,
                      2
                    ) &
                    ");background:linear-gradient(90deg,#0f62fe 0%," &
                    "#7aa6ff 100%);border-radius:999px"
                )

    Home(titulo, status):
      portal = foreign Portal(
        url = states.Search.url,
        title = "YouTube search preview",
        style = "display:block;flex:1;min-height:420px;width:100%;margin-top:0;background:#ffffff"
      ):
        statusCss:
          loading ":host { opacity: .70; }"
          ready ":host { opacity: 1; }"
          failed ":host { outline: 2px solid #da1e28; }"

        documentStart:
          evalJs "window.__GLAUCOPLASTIC_FOREIGN__ = true;"

      render:
        main Root(
          style = "display:flex;flex-direction:column;min-height:100vh;padding:20px;gap:16px;overflow:hidden;background:#161616;color:#f4f4f4;font-family:'IBM Plex Sans','Segoe UI',sans-serif"
        ):
          header Cabecalho(
            style = "display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap;padding:16px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626"
          ):
            divi CabecalhoTexto(
              style = "display:flex;flex-direction:column;gap:8px;min-width:280px;max-width:760px"
            ):
              span Identidade(
                style = "display:inline-flex;align-items:center;width:max-content;padding:4px 10px;border:1px solid rgba(15,98,254,0.70);border-radius:999px;color:#f4f4f4;background:rgba(15,98,254,0.16);font-size:11px;letter-spacing:.08em;text-transform:uppercase"
              ) "GlaucoPlastic / foreign / RLM"

              h1 Title(
                style = "margin:0;font-size:32px;line-height:1.1;font-weight:600;letter-spacing:-0.02em"
              ) titulo

              p Intro(
                style = "margin:0;max-width:72ch;font-size:14px;line-height:1.55;color:#c6c6c6"
              ) "O exemplo mostra um chatbox para busca e um foreign element apontado para a pagina de resultados do YouTube. O listener do foreign coleta os títulos visíveis depois do carregamento; o agente escolhe o resultado."

            p Status(
              style = "margin:0;min-width:280px;max-width:460px;padding:12px 14px;border-radius:6px;background:#393939;border:1px solid rgba(244,244,244,0.10);font-family:'IBM Plex Mono','SFMono-Regular',monospace;font-size:12px;line-height:1.6;white-space:pre-wrap;color:#f4f4f4"
            ) status

          section KPIs(
            style = "display:flex;flex-wrap:wrap;gap:12px"
          ):
            article KPI1(
              style = "flex:1 1 180px;padding:14px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626"
            ):
              p KpiLabel1(
                style = "margin:0 0 8px 0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
              ) "Busca"
              p KpiValue1(
                style = "margin:0;font-size:18px;font-weight:600"
              ) states.Search.query

            article KPI2(
              style = "flex:1 1 180px;padding:14px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626"
            ):
              p KpiLabel2(
                style = "margin:0 0 8px 0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
              ) "URL"
              p SearchUrlValue(
                style = "margin:0;font-size:12px;line-height:1.4;font-family:'IBM Plex Mono','SFMono-Regular',monospace;color:#f4f4f4;word-break:break-all"
              ) states.Search.url

            article KPI3(
              style = "flex:1 1 180px;padding:14px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626"
            ):
              p KpiLabel3(
                style = "margin:0 0 8px 0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
              ) "Selecionado"
              p SearchSelectedTitleValue(
                style = "margin:0;font-size:13px;line-height:1.45"
              ) states.Search.selectedTitle

            article KPI4(
              style = "flex:1 1 180px;padding:14px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626"
            ):
              p KpiLabel4(
                style = "margin:0 0 8px 0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
              ) "Resultados"
              p SearchStatusValue(
                style = "margin:0;font-size:13px;line-height:1.45"
              ) states.Search.status

          section Conteudo(
            style = "display:flex;flex-wrap:wrap;gap:16px;align-items:stretch"
          ):
            article Chatbox(
              style = "flex:1 1 520px;padding:16px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626;display:flex;flex-direction:column;gap:12px"
            ):
              header ChatboxCabecalho(
                style = "display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:flex-start"
              ):
                divi ChatboxTexto(
                  style = "display:flex;flex-direction:column;gap:8px;min-width:260px"
                ):
                  p ChatboxTag(
                    style = "margin:0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
                  ) "Chatbox"
                  h2 ChatboxTitulo(
                    style = "margin:0;font-size:22px;line-height:1.2;font-weight:600"
                  ) "Buscar titulos no YouTube"
                  p ChatboxIntro(
                    style = "margin:0;font-size:14px;line-height:1.55;color:#c6c6c6"
                  ) "Digite um termo, abra a pagina de resultados e aguarde o listener coletar os títulos e deixe o agente escolher o resultado."

              divi ChatboxForm(
                style = "display:grid;grid-template-columns:1fr auto auto;gap:8px;align-items:center"
              ):
                input SearchQueryInput(
                  type = "text",
                  value = states.Search.query,
                  autocomplete = "off",
                  spellcheck = "false",
                  placeholder = "Ex: bossa nova, lo-fi, public domain audio",
                  style = "height:40px;padding:0 12px;border:1px solid rgba(244,244,244,0.10);border-radius:4px;background:#161616;color:#f4f4f4"
                )

                button Buscar(
                  type = "button",
                  title = "Abrir a pagina e coletar titulos",
                  style = "height:40px;padding:0 16px;border:1px solid rgba(15,98,254,0.70);border-radius:4px;background:#0f62fe;color:#f4f4f4"
                ) "Buscar"

                button Limpar(
                  type = "button",
                  title = "Limpar resultado",
                  style = "height:40px;padding:0 16px;border:1px solid rgba(244,244,244,0.10);border-radius:4px;background:#393939;color:#f4f4f4"
                ) "Limpar"

              p Note(
                style = "margin:0;font-size:12px;line-height:1.55;color:#c6c6c6"
              ) "O exemplo consulta apenas titulos publicamente visiveis na pagina de resultados. Ele nao faz download."

            article Preview(
              style = "flex:1 1 360px;padding:16px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#262626;display:flex;flex-direction:column;gap:12px"
            ):
              p PreviewTag(
                style = "margin:0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
              ) "Foreign"
              h2 PreviewTitulo(
                style = "margin:0;font-size:22px;line-height:1.2;font-weight:600"
              ) "YouTube results page"
              p PreviewIntro(
                style = "margin:0;font-size:14px;line-height:1.55;color:#c6c6c6"
              ) "A superfície foreign carrega a página de resultados; a coleta DOM ocorre no evento loaded antes da inferência."

              portal

              YoutubeCard(
                title = states.Search.selectedTitle,
                href = states.Search.selectedHref,
                channel = "YouTube"
              )

      when SearchQueryInput changes:
        eventValue changes states.Search.query

      when Buscar clicks:
        consumerTrace("Buscar click")

        let queryValue =
          application.states().get("Search.query")

        let queryText =
          if queryValue.kind == JString:
            queryValue.getStr
          else:
            pretty(queryValue)

        let normalizedQuery = queryText.strip
        
        if normalizedQuery.len == 0:
          states.Search.url =
            %"https://www.youtube.com/results?search_query=public+domain+audio"
        else:
          states.Search.url =
            %("https://www.youtube.com/results?search_query=" &
              normalizedQuery.replace(" ", "+"))
        states.Search.requested = states.Search.requested + 1
        states.Search.results = %"Aguardando carregamento da pagina de resultados..."
        states.Search.selectedTitle = %""
        states.Search.selectedHref = %""
        states.Search.candidates = newJNull()
        states.Search.status = %"Abrindo a pagina de resultados antes da coleta DOM..."
        portal.navigate states.Search.url

      when Limpar clicks:
        states.Search.query = %""
        states.Search.url =
          %"https://www.youtube.com/results?search_query=public+domain+audio"
        states.Search.results = %"Nenhum resultado carregado."
        states.Search.selectedTitle = %""
        states.Search.selectedHref = %""
        states.Search.candidates = newJNull()
        states.Search.status = %"Busca limpa. Digite outro termo."

      when Portal loaded:
        var loadedUrlValue = Home.Portal evalJs "location.href"
        let loadedUrl =
          if loadedUrlValue.kind == JString:
            loadedUrlValue.getStr
          else:
            pretty(loadedUrlValue)

        if loadedUrl.startsWith("about:blank"):
          consumerTrace("Portal loaded: about:blank ignorado")
        else:
          consumerTrace("Portal loaded: iniciando coleta DOM em " & loadedUrl)
          states.Search.status =
            %"Pagina carregada. Aguardando os resultados dinamicos do YouTube..."

          var preview = newJNull()
          var collected = false

          let collectorScript =
            """
            (() => {
              const items = [];
              const seen = new Set();
              const nodes = Array.from(document.querySelectorAll('ytd-video-renderer'));

              for (const renderer of nodes) {
                const titleNode = renderer.querySelector('a#video-title');
                if (!titleNode) continue;

                const title = (
                  titleNode.getAttribute('title') ||
                  titleNode.textContent ||
                  ''
                ).trim();
                const href = titleNode.href || '';
                const ariaLabel = (titleNode.getAttribute('aria-label') || '').trim();
                const channelNode = renderer.querySelector(
                  'ytd-channel-name a, #channel-name a, #text.ytd-channel-name'
                );
                const channel = channelNode ? (channelNode.textContent || '').trim() : '';

                if ((!title && !href) || seen.has(href)) continue;
                seen.add(href);

                items.push({
                  title,
                  href,
                  ariaLabel,
                  channel
                });

                if (items.length >= 20) break;
              }

              return JSON.stringify({
                pageTitle: document.title,
                url: location.href,
                readyState: document.readyState,
                count: items.length,
                items
              });
            })()
            """

          for attempt in 0 ..< 12:
            preview = Home.Portal evalJs collectorScript

            if preview.kind == JString:
              try:
                preview = parseJson(preview.getStr)
              except CatchableError:
                discard

            if preview.kind == JObject and
                preview.hasKey("items") and
                preview["items"].kind == JArray and
                preview["items"].len > 0:
              collected = true
              break

            sleep(250)

          if collected:
            states.Search.candidates = preview
            states.Search.results =
              %"Candidatos coletados; aguardando a seleção do agente."
            states.Search.status =
              %("Foram coletados " & $preview["items"].len &
                " titulo(s). Enviando os candidatos para a inferencia...")
            states.Search.collectionVersion =
              states.Search.collectionVersion + 1
            consumerTrace(
              "Portal loaded: collected count=" & $preview["items"].len
            )
          else:
            states.Search.results = preview
            states.Search.status =
              %"A pagina terminou de carregar, mas nenhum titulo foi encontrado no DOM."
            consumerTrace("Portal loaded: nenhum ytd-video-renderer encontrado")

  agents:
    LoadingScreen("loading-screen", okfPrincipal = Geral):
      purpose "Mantém a tela de carregamento enquanto o runtime inicializa o llama-server e abre os modelos incluídos."

      render:
        BootScreen(
          states.BootPhase,
          states.BootConnection,
          states.BootModel,
          states.BootProgress,
          states.BootDetail
        )

      when initializes:
        consumerTrace("loadingScreen: initialize")
        states.BootPhase = %"Inicializando runtime"
        states.BootConnection = %"Verificando llama-server..."
        states.BootModel = %"Localizando modelos incluídos..."
        states.BootProgress = %"0%"
        states.BootDetail = %"A tela de carregamento aguarda o handshake do runtime."
        consumerTrace(
          "loadingScreen: phase=" & states.BootPhase &
          " connection=" & states.BootConnection &
          " model=" & states.BootModel &
          " progress=" & states.BootProgress
        )

      when states.BootConnection changed:
        consumerTrace(
          "loadingScreen: connection changed -> " & states.BootConnection
        )
        states.BootDetail =
          states.BootConnection & " " & states.BootModel

      when states.BootModel changed:
        consumerTrace(
          "loadingScreen: model changed -> " & states.BootModel
        )
        states.BootDetail =
          states.BootConnection & " " & states.BootModel

      when states.BootProgress changed:
        consumerTrace(
          "loadingScreen: progress changed -> " & states.BootProgress
        )

      when states.BootPhase changed:
        consumerTrace(
          "loadingScreen: phase changed -> " & states.BootPhase
        )

      when states.BootDetail changed:
        consumerTrace(
          "loadingScreen: detail changed -> " & states.BootDetail
        )


    AssistenteGeral(
      "assistente-geral",
      okfPrincipal = Geral,
      session = "consumer-youtube"
    ):
      purpose "Você é um agente de seleção assistida sobre resultados já coletados da página do YouTube."

      dominio:
          state Search:
            "Estado da busca. `candidates` contém a página e os itens coletados pelo listener `Portal loaded`; `collectionVersion` muda somente após uma coleta DOM válida e dispara a inferência."
          when changes:
            "Quando `states.Search.collectionVersion` mudar, os resultados já foram coletados em `states.Search.candidates.items`. Compare os títulos com `states.Search.query`, escolha o item mais adequado e use a capability `state.set` para atualizar `Search.results`, `Search.selectedTitle`, `Search.selectedHref` e `Search.status`. Termine com `answer` contendo a seleção. Não execute JavaScript e não tente chamar `BuscarTitulosYoutube`."
            into states.Search

      rlm:
        conditions:
          """
          A coleta DOM acontece no listener `when Portal loaded`, antes desta
          inferência. Leia os candidatos em `states.Search.candidates.items`.

          Escolha somente um item presente nessa lista. Use as capabilities:

          - state.set {"name":"Search.results","value":{...}}
          - state.set {"name":"Search.selectedTitle","value":"..."}
          - state.set {"name":"Search.selectedHref","value":"..."}
          - state.set {"name":"Search.status","value":"..."}

          `Search.results` deve receber um objeto com `selectedTitle`,
          `selectedHref`, `notes`, `candidateCount` e `query`.
          Depois das instruções, devolva o mesmo objeto em `answer`.
          Não navegue a foreign e não invente links ausentes nos candidatos.
          """


  render:
    when states.BootPhase == "Pronto":
      section AppShell(
        style = "display:flex;flex-direction:column;gap:16px"
      ):
        Home(
          states.Title,
          states.Search.status
        )
    else:
      BootScreen(
        states.BootPhase,
        states.BootConnection,
        states.BootModel,
        states.BootProgress,
        states.BootDetail
      )

proc run*() =
  consumerTrace("run(): before application.run()")
  application.run()

when isMainModule:
  consumerTrace("main: args=" & commandLineParams().join(" "))

  if "--prepare-dev" in commandLineParams():
    consumerTrace("main: prepare-dev")
    application.validateInstallation()

  elif "--manifest" in commandLineParams():
    consumerTrace("main: manifest")
    application.writeInstallerManifest(
      "build/windows-msi/installer.json"
    )

  elif "--runtime-summary" in commandLineParams():
    consumerTrace("main: runtime-summary")
    application.validateInstallation()

    echo pretty(
      application.initializeTechnologies(
        startModel = false
      )
    )

  else:
    consumerTrace("main: run")
    run()
