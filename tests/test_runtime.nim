import std/[json, os, strutils, tables]
import glaucoplastic

proc containsNamedNode(node: JsonNode; expectedName: string): bool =
  if node.kind == JObject:
    if node.hasKey("name") and
       node["name"].kind == JString and
       node["name"].getStr == expectedName:
      return true

    if node.hasKey("children"):
      for child in node["children"].items:
        if containsNamedNode(child, expectedName):
          return true

  elif node.kind == JArray:
    for child in node.items:
      if containsNamedNode(child, expectedName):
        return true

  false

glaucoplastic TestePlastic, testApp:
  product:
    title "Teste Plastic"
    version "0.1.0"

  okfs:
    Teste:
      purpose "Conhecimento de teste."

  orm:
    Obra:
      id integer primary
      nome string

  states:
    Contador integer = 1

  components:
    Painel(titulo):
      render:
        section Root:
          h1 Titulo titulo
          divi Resultado
          foreign Browser(url = "https://example.com"):
            when loaded:
              discard

  agents:
    Analista("teste", modo = "unitario"):
      purpose "Executar teste."
      when states.Contador changed:
        discard

  render:
    Painel("Teste")

proc main() =
  testApp.validateInstallation()
  testApp.run(startModel = false)

  doAssert testApp.name == "TestePlastic"
  doAssert testApp.product.title == "Teste Plastic"
  doAssert testApp.states.get("Contador").getInt == 1

  let html = testApp.renderApplicationHtml()
  doAssert html.contains("<h1")
  doAssert html.contains("Teste")
  doAssert html.contains("data-glauco-foreign=\"Painel.Browser\"")

  var observed = false
  testApp.states.onChanged("Contador", proc(change: PlasticStateChange) =
    observed = true
    doAssert change.currentValue.getInt == 2
  )
  testApp.states.set("Contador", %2)
  doAssert observed

  let inserted = testApp.orm.insertRow("Obra", %*{"nome": "Teste"})
  doAssert inserted["id"].getInt >= 1
  doAssert testApp.orm.findById("Obra", inserted["id"].getInt)["nome"].getStr == "Teste"

  let insertedId = inserted["id"].getInt
  doAssert testApp.orm.deleteById("Obra", insertedId)
  doAssert testApp.orm.findById("Obra", insertedId).kind == JNull

  let browserResult = testApp.foreign.evalJs(
    "Painel.Browser",
    "document.title"
  )
  doAssert browserResult["mock"].getBool
  doAssert testApp.foreign.describe("Painel.Browser")["events"].len == 1

  doAssert containsNamedNode(testApp.renderTree, "div")
  doAssert containsNamedNode(testApp.renderTree, "h1")

  let createdOkf = testApp.okf.persist(%*{
    "space": "Teste",
    "title": "Documento",
    "summary": "Conhecimento"
  })
  doAssert testApp.okf.search("Conhecimento").len == 1

  let createdOkfId = createdOkf["id"].getStr
  let updatedOkf = testApp.okf.persist(%*{
    "id": createdOkfId,
    "space": "Teste",
    "title": "Documento atualizado",
    "summary": "Conhecimento revisado"
  })
  doAssert updatedOkf["id"].getStr == createdOkfId
  doAssert testApp.okf.search("Conhecimento revisado").len == 1
  doAssert testApp.okf.list("Teste").len == 1

  doAssert testApp.agents.hasKey("teste")
  doAssert testApp.installerManifest()["product_name"].getStr == "TestePlastic"

  echo "Todos os testes de runtime passaram."
  testApp.close()

when isMainModule:
  main()
