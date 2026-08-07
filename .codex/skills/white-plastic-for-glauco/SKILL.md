---
name: white-plastic-for-glauco
description: Build and refine GlaucoPlastic WebUI applications using the White Plastic visual language: bright neutral surfaces, disciplined spacing, compact sidebars, rounded controls, readable Markdown, native voice, and explicit tool-driven assistants.
---

# White Plastic for Glauco

Use this skill when creating or modifying a GlaucoPlastic interface, especially local assistants, operational tools, desktop WebViews, dashboards, and document-oriented workspaces.

## Required workflow

1. Inspect the consumer DSL and the relevant generated HTML/CSS/JavaScript before editing the framework core.
2. Keep application-specific behavior in the consumer. Change `glaucoplastic.nim` only for reusable runtime, DSL, bridge, rendering, agent, voice, persistence, or tooling capabilities.
3. Preserve the monolithic GlaucoPlastic architecture when a reusable capability must enter the framework.
4. Use `Tools` and `Tool` as the agent-facing vocabulary. Treat legacy `Function` declarations only as backward compatibility.
5. Keep the WebView responsive. Model inference, Whisper transcription, memory consolidation, document generation, and other blocking operations must run outside the UI thread.
6. Render assistant output as sanitized Markdown. User text must remain escaped plain text.
7. Prefer local, cross-platform backends. For speech recognition use `whisper.cpp`; let the WebView record audio through `MediaRecorder`, then send it to the native runtime for conversion and transcription.
8. Keep generated office files inside a declared workspace. Expose document, spreadsheet, presentation, PDF, extraction, listing, and workspace-summary operations as RLM tools.
9. Verify the Nimble scaffold, section ordering, local paths, and generated overloads before declaring the example runnable.

## Visual language

Read `references/style.md` before making UI changes. The interface should feel bright, physical, quiet, and precise rather than decorative. Use neutral white layers, pale gray background, dark graphite actions, small radii hierarchy, restrained shadows, and generous readable space.

## GlaucoPlastic conventions

Read `references/glaucoplastic.md` before changing DSL or framework behavior.

## Completion checks

- `nimble run` resolves a `.nimble` manifest and `../../src` path.
- `states`, `okfs`, and `components` appear before `agents` when their generated helpers are required.
- Agent declarations use `Tool` and include a concrete `capability` name.
- The local assistant has Markdown output, native Whisper fallback, automatic TTS, sessions, persistent learned items, and office tools.
- Changes are idempotent or backed up by the installer.
