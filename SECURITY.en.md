# Security Policy

**English** | [简体中文](SECURITY.md)

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's
[Private vulnerability reporting](https://github.com/imi4u36d/flashCat/security/advisories/new),
or email the maintainer (see the repository commits).

In your report, state the affected version, reproduction steps, and impact (can it read
local files / execute commands / crash the app?).

You will get a first reply within 48 hours. Please do not disclose details publicly
before a fix ships.

## Security model

Knowing these four points prevents a lot of false reports:

1. **The gateway authenticates nothing, and only listens on loopback.** `127.0.0.1:9000`
   is bound through `requiredLocalEndpoint`
   (`native/Sources/FlashCatKit/Gateway/GatewayHTTPServer.swift:152`), and any API key is
   accepted. **This is not a vulnerability, it is the design.** Any process able to reach
   the loopback interface could run its own inference server anyway. If you need to serve
   other machines, add your own reverse proxy.
2. **Engine runtimes are third-party binaries.** Packs download from addresses declared
   in `pack-index.json` and are SHA-256 verified before unpacking
   (`native/Sources/FlashCatKit/EngineInstaller.swift:398`). The app launches them
   strictly according to `manifest.json` and interprets no other file.
3. **There is no web layer.** The interface is native SwiftUI — no `WKWebView`, no
   embedded HTML/JS, no script bridge. Remote content (Hugging Face model cards) is
   converted to Markdown with every HTML tag stripped in
   `native/Sources/FlashCat/UI/ModelCardText.swift` and then rendered as plain styled
   text: no scripts run, and no remote image is loaded.
4. **The control interface is token-gated.** It binds loopback only, requires a token
   generated fresh on every launch
   (`native/Sources/FlashCat/ControlServer.swift:37`), accepts it as
   `Authorization: Bearer` or `x-flashcat-token`, and keeps `control.json` at mode `0600`
   (`native/Sources/FlashCat/ControlServer.swift:36`).

## Known attack surface (reports against these are welcome)

- **The control interface is a command surface.** Whoever holds the token can change
  settings, start and stop engines, download models, and read logs. Token leakage, a
  file-permission mistake, a listener bound beyond loopback, or a way around the 401 are
  all valid findings.
- **Model cards and other Hugging Face metadata are untrusted input.** All of it is
  escaped or stripped before rendering; any path that executes remote markup, or loads
  a remote resource while rendering it, is a valid vulnerability.
- **Downloaded packs and models are untrusted data.** SHA-256 proves transport
  integrity; it says nothing about the intent of whoever built a pack or a model.
  Memory-safety bugs in an engine parsing model files belong upstream, but a flaw in
  how flashCat filters, installs, or launches those artifacts is ours.
- **Engine logs are untrusted input.** Log lines come from engine stdout, appear on the
  Logs page, and are parsed for status. They must never be executed or interpolated into
  a shell command.
