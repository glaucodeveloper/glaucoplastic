import std/json
import glaucoplastic

let existing = %*[
  {
    "kind": "person",
    "title": "Nome do Usuário",
    "content": "Ícaro Glauco de Oliveira",
    "scope": "global",
    "status": "active"
  }
]

let duplicateByAnswer = %*{
  "kind": "person",
  "title": "Ícaro Glauco de Oliveira",
  "content": "Nome do usuário: Ícaro Glauco de Oliveira.",
  "scope": "session:session-test"
}

let sessionNoise = %*{
  "kind": "person",
  "title": "Identificação",
  "content": "Usuário identificado na sessão.",
  "scope": "session:session-test"
}

let validPreference = %*{
  "kind": "preference",
  "title": "Estilo de Resposta",
  "content": "O usuário prefere respostas curtas e diretas.",
  "scope": "global"
}

doAssert(
  plasticAssistantNormalizeLearningCandidate(
    existing,
    duplicateByAnswer
  ).kind == JNull
)

doAssert(
  plasticAssistantNormalizeLearningCandidate(
    existing,
    sessionNoise
  ).kind == JNull
)

doAssert(
  plasticAssistantNormalizeLearningCandidate(
    existing,
    validPreference
  ).kind == JObject
)

echo "filtro de redundância: OK"
