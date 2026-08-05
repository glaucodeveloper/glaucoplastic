import std/[json, os]
import glaucoplastic

glaucoplastic LearningConsumer, application:
  product:
    title "Learning Consumer"
    version "0.1.0"

  installation:
    windowsMsi:
      productName "Learning Consumer"
      manufacturer "Example"
      version "0.1.0"
      upgradeCode "925147BC-D9C0-41A2-ADCD-34702B942D3B"
      scope perUser
      executable "learning-consumer.exe"

      installDirectory:
        root localAppDataPrograms
        path "LearningConsumer"

      applicationData:
        root localAppData
        path "LearningConsumer"
        createDirectory "data"
        createDirectory "okf"
        createDirectory ".glauco/memory"
        createDirectory ".glauco/sessions"
        createDirectory ".glauco/learning"

  learning:
    background:
      enabled true
      startWithApplication false
      collectHistory true
      collectWhileInactive true
      pollIntervalMs 500

      worker:
        argument "--glaucoplastic-learning-worker"

    history:
      consent required
      approval manual
      retentionDays 365

    dataset:
      name "LearningConsumerConversations"
      minimumApprovedConversations 1

    # Treinador real em background.
    # Requer GLAUCOPLASTIC_BASE_MODEL apontando para um modelo Transformers
    # compatível com PEFT/LoRA.
    trainer:
      command "python3 trainer/refine_model.py --dataset {dataset} --output {output}"

  okfs:
    Geral:
      purpose "Conhecimento geral da aplicação."

  components:
    Home(titulo):
      render:
        main(part = Root):
          h1(part = Titulo) titulo
          p "A aprendizagem é ativada e controlada pela aplicação."
          p "Use --learning-demo para testar o worker e o treino em background."

  states:
    Titulo string = "Learning Consumer"

    when states.Titulo changed:
      Home.Titulo.textContent = states.Titulo

  agents:
    Assistente("assistente-geral", okfPrincipal = Geral):
      purpose "Auxilie o usuário e registre conversas consentidas para refinamento."

  render:
    Home(states.Titulo)

proc printLearningStatus() =
  echo pretty(application.learning().status())

proc addApprovedExample(): string =
  let learning = application.learning()
  learning.grantConsent()

  result = learning.recordExchange(
    "assistente-geral",
    %"Como ativo a aprendizagem da aplicação?",
    %"Chame application.learning().enable()."
  )

  if result.len == 0:
    raise newException(
      PlasticLearningError,
      "A conversa não foi registrada. Verifique o consentimento e a configuração learning."
    )

  if not learning.approveConversation(result):
    raise newException(
      PlasticLearningError,
      "Não foi possível aprovar a conversa " & result
    )

proc waitForCurrentJob(maxWaitMs = 10_000) =
  let learning = application.learning()
  var waited = 0

  while waited < maxWaitMs:
    let current = learning.latestJob()
    if current.kind == JObject and current.hasKey("status"):
      let jobStatus = current["status"].getStr
      if jobStatus in ["completed", "failed"]:
        echo pretty(current)
        return
    sleep(250)
    inc waited, 250

  echo "O job continua em background. Consulte com --learning-status."

proc run*() =
  application.run(startModel = false)

when isMainModule:
  if application.handleLearningWorkerCommand():
    quit(0)

  let parameters = commandLineParams()

  if "--prepare-dev" in parameters:
    application.validateInstallation()
    echo "Layout preparado em: " & application.learning().rootPath

  elif "--learning-demo" in parameters:
    let conversationId = addApprovedExample()
    echo "Conversa aprovada: " & conversationId

    let jobId = application.learning().runOnce()
    echo "Job criado: " & jobId
    waitForCurrentJob()
    application.learning().disable()

  elif "--learning-add-example" in parameters:
    echo "Conversa aprovada: " & addApprovedExample()

  elif "--learning-enable" in parameters:
    application.learning().grantConsent()
    application.learning().enable()
    printLearningStatus()

  elif "--learning-run-once" in parameters:
    application.learning().grantConsent()
    echo "Job criado: " & application.learning().runOnce()

  elif "--learning-pause" in parameters:
    application.learning().pause()
    printLearningStatus()

  elif "--learning-resume" in parameters:
    application.learning().resume()
    printLearningStatus()

  elif "--learning-disable" in parameters:
    application.learning().disable()
    printLearningStatus()

  elif "--learning-status" in parameters:
    printLearningStatus()

  else:
    run()
