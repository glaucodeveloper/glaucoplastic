# GlaucoPlastic implementation conventions

## Responsibility split

`glaucoplastic.nim` supplies reusable runtimes and DSL semantics. The consumer defines its pages, states, agents, tools, visual composition, and product-specific behavior.

## Section ordering

Generated routines currently depend on section order. When an agent uses state, OKF, or WebContents capabilities, place sections in this order:

```nim
states:
  # ...

okfs:
  # ...

components:
  # ...

agents:
  # ...

assistant:
  # ...
```

## Agent vocabulary

Use:

```nim
agents:
  OfficeAssistant:
    rlm:
      conditions """..."""

      Tool CreateDocument(title, paragraphs), JsonNode:
        capability "office.document.create"
        systemPrompt "Create a DOCX document in the office workspace."
```

`Tool` is a manifest entry describing a registered RLM capability. The capability executes in the runtime; the declaration tells the model when and how to invoke it.

## Native voice

The WebView records through `MediaRecorder`. It sends base64 audio and MIME metadata through the GlaucoPlastic UI event bridge. A voice worker writes the audio, converts it to 16 kHz mono WAV using FFmpeg, and transcribes with `whisper-cli` from whisper.cpp. Never depend on `SpeechRecognition` for core functionality.

## Office tools

The Python bridge is an external optional backend controlled by Nim. It must accept a capability plus a JSON arguments file and return one JSON object. Keep all output inside the configured workspace.

## Persistence

Sessions, summaries, learned items, audio artifacts, tool outputs, and model/runtime files belong under the application data root or an explicitly configured project workspace.
