# Rehearsal: app WebUI

`native/Sources/FlashCat/WebUI/` is the single visual source. The old
`preview/liquid-glass` mock and its sync scripts were removed; styles,
components and motions are edited directly here, and `live.js` is the only
runtime adapter layer on top.

Beats: shell enters -> snapshot paints the active page -> controls respond ->
a result settles. Menus open from their anchor; the sidebar divider and rail
move as one object; charts draw once; messages arrive from their own side.

Captured: installed app at 1280x820; full sidebar and rail; overview, chat,
models, engines, logs and settings; light and dark; model switcher; engine
config split; command palette; launch / recommendation page; model plaza;
download center.

Checks:
- CSS and JavaScript parse; every statically named icon exists in the local
  Lucide subset.
- Buttons use the shared 6–10px geometry; press and focus states are shared.
- Five runtimes appear on the engine page and in the model filter; the model
  page reads the flat all-engine pool, not just the browsed engine.
- Every model surface (cards, the switcher, the chat chip) carries the family
  mark — Qwen, Xiaomi MiMo, DeepSeek, … — and an unrecognized pack falls back to
  its initial letter. A family keeps its colour in both appearances.
- Overview draws only sampled data: stop the engine and the decode chart shows
  its empty state instead of a curve, TTFT/prefill/memory read "—", and the
  rhythm and metric gauges collapse. Run a request and every visual moves with
  the real throughput/TTFT/prefill/memory samples, not on a timer.
- The model plaza opens on the Hub's trending list; sort, format filter and the
  pager each send one `searchHub` with the current query, a row opens its model
  card, and Escape backs out of the card before closing the panel.
- A model with an active transfer shows the same percentage on its card and in
  the download center, never「使用」; the card's progress action opens the center.
  A paused card's button resumes the same row in place instead of opening the
  center, and its percentage continues from 已下载/总量 rather than 0%. Failed
  rows keep the card out of use, and an installed card's「使用」sits directly
  left of its「⋯」overflow button.
- Closing the model plaza by clicking the dim leaves the model toolbar clickable:
  the hidden panel must not swallow the next press on its entry point.
- The launch page never offers "安装" for a runtime the catalog marks installed.
- Cards and every floating sheet are fully opaque: no page text, chart line or
  card edge reads through a widget, model/engine card, menu, palette, inspector,
  hub, engine panel or toast. The download sheet stays readable over the gateway
  card and its rows keep progress + pause/cancel inside the 400px panel.
- Command palette: ⌘K opens, ↑/↓ moves, ↵ runs, esc closes.
- Model menu closes on Escape and on an outside click.
- Chat scrolls to the newest message, and the composer keeps its value while
  snapshots stream.
- A streaming answer is token-accurate: Swift sends each SSE delta on a 16 ms
  batched side channel, the web view paints it on the next animation frame, and
  the 100 ms snapshot only repairs or confirms what is already on screen. There
  is no typewriter pacing and no backlog: at 100+ tok/s the reply advances with
  the engine and stops the moment generation stops. Missing or out-of-order
  events fall back to the snapshot watermark, so text is never duplicated or
  lost. Waiting for the first token shows a compact three-dot state with a
  shimmer; the card surface stays invisible until there is text to hold.
- The thinking block is its own channel: it streams reasoning markdown in real
  time, ticks elapsed seconds while the answer is empty, then folds into
  "思考了 8.4 秒" shortly after the first answer token. A model with no
  reasoning channel never shows an empty band. Folded, it keeps the newest line
  of thought under the header; expanding reveals the full reasoning with a
  height-only transition, and closing returns to the one-line preview. Opening
  or closing by hand survives the rest of the stream and the final repaint; an
  old reply keeps the stored duration.
- Scrolling up while a reply streams pins the conversation and offers a
  "回到最新" control instead of yanking the reader back; following resumes when
  they return to the bottom.
- Long replies stay cheap: plain-text growth appends to the existing text node
  in O(1), and only a structural Markdown change re-parses the tail block.
- A fast burst does not land as one hard block of text. New lines and long new
  lines are split into short reveal pieces that fade in with a small stagger
  (42 ms per piece, 38 ms per line, capped at ~260 ms). The characters are
  already in the DOM and already take their final space — only opacity and a
  few pixels of lift are animated — so a 100+ tok/s engine produces a steady
  flow of lines with no queue draining after generation stops. Opening an old
  thread seeds the seen-line set and never replays the fade on history;
  `prefers-reduced-motion` and the final settle both retire the animation.
- Markdown renders in the reply, not raw: headings, bold/italic, inline code,
  fenced code with a language tag, ordered/unordered/task lists, tables,
  blockquotes and safe links. `javascript:` links stay visible as text, raw HTML
  is escaped, and no remote image is fetched.
- With `prefers-reduced-motion`, tokens still arrive in real time (no simulated
  pacing to remove), but shimmer, caret blink and fold transitions are disabled.
- Light/dark resolve from the same tokens; no page branches on the theme.

Not checked: IME composition during a streaming snapshot, very long logs, and a
live Hugging Face request under rate limiting.
