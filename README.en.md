<img src="native/Sources/FlashCat/Resources/app-icon.png" width="88" align="right" alt="flashCat" />

# flashCat

**A local LLM console for the Mac.** Install inference engines, download models,
chat, and turn the whole machine into a local endpoint any AI client can use —
all in one window.

**Elegant · Fluid · Powerful**

English | [简体中文](README.md)

[![Release](https://img.shields.io/github/v/release/imi4u36d/flashCat?display_name=tag&style=flat-square)](https://github.com/imi4u36d/flashCat/releases/latest)
[![macOS 26+](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://github.com/imi4u36d/flashCat/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

![flashCat overview](https://flashxlab.com/assets/overview.webp)

## Features

- **Four engines, one console.** Splash, oMLX, MTPLX, and MLX-Serve coexist as
  peers, each with its own runtime, model directory, and logs. Ports are assigned
  automatically; oMLX and MLX-Serve switch models without restarting.
- **One local endpoint.** A fixed `http://127.0.0.1:9000/v1` that speaks both
  OpenAI and Claude formats. The gateway switches or starts the right engine
  based on the model in the request, so clients never edit their Base URL.
- **Model library and hub.** Search Hugging Face, HF-Mirror, or ModelScope, read
  model cards, and download. Pick a single GGUF quantization, pause and resume
  transfers. Weights land in a shared folder that every engine can see.
- **A chat you can work in.** Streaming output, thinking blocks, Markdown,
  edit-and-resend, branching, regeneration, and queued messages. Attach text,
  source files, PDF, or RTF, plus images and video; ⌘V pastes screenshots
  directly. Conversations stay local and can be searched, pinned, and renamed.
- **Real measurements.** Decode speed, time to first token, prefill, cache hit
  rate, and context usage, with a 60-second chart and a per-request list. Metrics
  are sampled by the gateway, and anything that cannot be measured shows `—`.
- **Made to fit.** System, light, and dark appearance; six accent presets plus a
  system color picker; native title bar and sidebar; a menu bar panel for
  switching models and reading telemetry without returning to the main window.
- **A complete CLI.** The bundled `flashcat` shares the app's engines, models,
  settings, and logs. Every result command supports `--json` for scripting.

## Requirements

| | |
| --- | --- |
| Chip | Apple Silicon (M series) |
| System | macOS 26.0 or later |
| Disk | About 15 MB for the app; 50–600 MB per engine runtime; 2–250 GB per model |

The interface follows the system language: Simplified Chinese or English. Both
are bundled with the app.

## Install

Download from [Releases](https://github.com/imi4u36d/flashCat/releases/latest):

- `flashCat-2.0.0.dmg` — open it and drag flashCat into Applications.
- `flashCat-2.0.0.pkg` — double-click and follow the installer; it can link
  `flashcat` into `/usr/local/bin`.

The app is ad-hoc signed and not notarized by Apple. On first launch, if
Gatekeeper blocks it, right-click flashCat in Finder and choose Open, or allow
it under System Settings → Privacy & Security.

## Quick start

1. On the launch page, pick an engine, download, and install it.
2. Download a model from the Model Library, or search any Hugging Face /
   ModelScope repository in the Model Hub.
3. Start the engine from Overview, then verify in Chat. Point other clients at
   `http://127.0.0.1:9000/v1`.

Engine runtimes are downloaded on demand and are not bundled with the app.
Installed engines can be updated, inspected, or removed from the Engines page.

## Local API

The API is available as soon as the app starts. OpenAI and Claude formats share
one port; the API key is not checked, so any string works.

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:9000/v1` (port configurable in Settings) |
| OpenAI | `POST /v1/chat/completions` (streaming) |
| Claude | `POST /v1/messages`, `POST /v1/messages/count_tokens` (streaming) |
| Models | `GET /v1/models` |

```bash
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

For the Claude SDK, use `http://127.0.0.1:9000` as the Base URL. Model names come
from `/v1/models`; the gateway makes sure the matching weights are loaded. The
server listens on the loopback interface only and is never exposed publicly.

## CLI

`flashcat` shares state with the app: while the app runs it drives the local
control API; while the app is closed it can still inspect and install engines,
read and write configuration, and read logs.

```bash
flashcat                            # app, engine, gateway, and download status
flashcat engines list               # installed versions and state
flashcat engines start omlx         # switch engines and wait for the model
flashcat models list --all          # local weights and recommended tiers
flashcat models download mlx-community/Qwen3-8B-4bit --wait
flashcat chat "Explain MoE in one sentence"   # stream through the local API
flashcat logs --engine omlx -f      # follow engine logs
flashcat doctor                     # install, permission, runtime, and PATH check
```

The `.pkg` installer links `/usr/local/bin/flashcat` when possible; with `.dmg`,
run `flashcat cli install` to link it into your PATH. See `flashcat --help` for
the full command set.

Exit codes are stable: `0` success, `1` failure, `2` usage, `3` app not running,
`4` not found, `5` timeout, `6` state conflict, `7` control token error. Errors
also support `--json`.

## Models and data

| Content | Location |
| --- | --- |
| App configuration, chat history | `~/Library/Application Support/flashCat` |
| Engine runtimes | `~/Library/Application Support/flashCat/engines/<engine>/<version>` |
| Model weights | `~/Library/Application Support/flashCat/models/<engine>` |
| Shared model folder | `~/Library/Application Support/flashCat/shared-models` |
| Control API credentials | `~/Library/Application Support/flashCat/control.json` (mode 0600) |
| Logs | `~/Library/Logs/flashCat` |

Recommended tiers come from each installed engine's own catalog: Splash and
MTPLX provide them; oMLX and MLX-Serve do not. Weights you download yourself are
marked as personal downloads. Removing the app does not remove engines or
models; delete the folders above to clean them up.

## Settings

General (appearance, launch at login, download cache, accent color), Model
Sources (Hugging Face / HF-Mirror / ModelScope, mirror, token), API (gateway and
control ports), Chat (defaults and system prompt), and About (version and update
check). Both local APIs are always on; engine ports are assigned automatically
and are not a setting.

## FAQ

**An engine will not start, or keeps spinning.** Check the last lines on the Logs
page; usually the model does not fit in memory or a file is incomplete. Try a
smaller quantization or reinstall the runtime from Engines.

**A model is missing from the library.** Switch engines at the top of the page.
Recommended tiers depend on the engine's catalog, which only exists after that
engine is installed.

**Can other machines connect?** The app listens on `127.0.0.1` only. Put your own
reverse proxy in front if you need remote access, and never expose the port
directly to the internet.

**`flashcat` says the app is not running.** Run `flashcat app open` first;
`flashcat doctor` will point at the step that failed.

## Development

```bash
make app      # build and install into /Applications
make test     # unit tests (778 total, 5 skipped when the local environment is absent)
make verify   # build, install, launch, and verify the process and bundled CLI
```

Sources live in `native/`; the UI is SwiftUI / AppKit with no WebView. See
[CONTRIBUTING.en.md](CONTRIBUTING.en.md) for the environment and architecture
rules, and [UI-SPEC.md](native/Sources/FlashCat/UI-SPEC.md) for the interface spec.

## License

[MIT](LICENSE) © 2026 wangzhuo

The inference engines are the work of their upstream projects; this project
handles downloading, installing, and scheduling their runtimes:
[Splash](https://github.com/incoai/splash),
[oMLX](https://github.com/jundot/omlx),
[MTPLX](https://github.com/youssofal/mtplx),
[MLX-Serve](https://github.com/ddalcu/mlx-serve).
Model copyrights remain with their publishers.
