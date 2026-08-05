# GlaucoPlastic Nim Inline Blocks

VS Code / Codium extension scaffold for highlighting embedded blocks inside Nim triple-quoted strings.

Supported markers:

- `//js`
- `//html`
- `//css`

Example:

```nim
let script = """
//js
(() => {
  return document.title
})()
"""
```

This repository only contains the TextMate grammar scaffold. It can be packaged
with `vsce` or opened as an unpacked extension in Codium.
