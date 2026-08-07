# White Plastic visual specification

## Character

White Plastic is a bright operational interface language for Glauco applications. It combines the cleanliness of white molded material with the restrained density of a serious desktop tool. The interface is calm, legible, and tactile without skeuomorphism.

## Surfaces

- Application background: very light neutral gray, approximately `#f4f5f7`.
- Primary panels: white or near-white.
- Secondary cards: `#fafbfc` with a quiet gray border.
- Primary action: graphite, approximately `#1e2329`, with white text.
- Status and accent colors are functional only: green for ready, amber for processing, red for failure or recording.

## Geometry

- Sidebar width around 280–320 px on desktop.
- Main content constrained to a readable 820–900 px conversation width.
- Large containers: 14–18 px radius.
- Controls: 8–12 px radius.
- Message bubbles use an asymmetric reduced corner near the speaker edge.
- Borders are thin and neutral; shadows are broad and low-opacity.

## Typography

Use the platform UI sans stack. Headings are compact and semibold. Supporting text is smaller and gray. Avoid oversized marketing typography in operational applications.

## Density

Use 8–10 px internal control spacing, 14–18 px card spacing, and 22–28 px major region spacing. Keep the composition airy, but do not waste vertical space.

## Assistant conversation

- User messages: graphite surface, white text, aligned right.
- Assistant messages: white surface, gray border, aligned left.
- Assistant Markdown supports headings, paragraphs, lists, blockquotes, links, inline code, fenced code, and tables when practical.
- Code blocks use a slightly darker neutral background, horizontal scrolling, and a copy-friendly monospace font.
- Composer is a single white rounded shell with microphone, textarea, and send action.

## Sidebar

The sidebar contains brand, new-session action, sessions, and learned items. Learned items use small type labels, concise declarative content, and explicit actions such as pin and forget.

## Motion

Use only functional motion: subtle pulse while thinking or recording, short opacity/transform transitions, and no continuous decorative animation.

## Accessibility

Maintain visible focus states, keyboard submission, sufficient contrast, semantic buttons, and reduced-motion compatibility.
