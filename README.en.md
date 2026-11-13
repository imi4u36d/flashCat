<img src="native/Sources/FlashCat/Resources/app-icon.png" width="96" align="right" alt="flashCat" />

# flashCat

**A local LLM console for the Mac.** Install engines, download models, chat, and
turn the whole thing into a local endpoint any AI client can use — all in one window.

**Elegant · Fluid · Powerful**

**English** | [简体中文](README.md)

[![flashCat intro video (no narration)](https://github.com/imi4u36d/flashCat/releases/download/v1.5.1/flashCat-1.5.1-poster.png)](https://github.com/imi4u36d/flashCat/releases/download/v1.5.1/flashCat-1.5.1-intro.mp4)

<sub>▶ A 50-second tour · no narration, sound on for the music · footage from a real flashCat session</sub>

No per-engine flag sheets to memorize; it works the moment you open it, and when
another tool needs to plug in it is simply an address such as
`http://127.0.0.1:9000/v1`. Terminal people can install the `flashcat` command
once and script status, start/stop, models, and chat.

---

## Highlights

**1. Dynamic Island.** A glass capsule sits permanently at the top of the window:
engine name, real phase (starting / loading weights / warming up), live tok/s, and
start/stop. Notifications pop up in place, graded info / success / warning / error,
and return to engine status after 3.2 seconds; click to expand notification history
or engine details right there, click anywhere else to collapse. It replaces three
surfaces at once — the status bar, toasts, and a details page.

**2. Multi-engine aggregation, transparent model switching.** Splash, oMLX, MTPLX,
MLX-Serve, and Strata coexist as peers, each with its own port range, runtime, logs,
and model directory. Hot-swap engines keep their process alive; restart-style engines
still show their phase and an "elapsed m:ss" counter. Clients notice none of it — the
gateway address is fixed, so switching engines or ports never means editing a Base URL.

**3. Customizable engine settings.** Ports are validated against each engine's range;
thirteen knobs are translated into that engine's own startup flags — MTP / DFlash2,
`--max-memory`, `--max-context`, PLE cache and SSD offload, thinking budget, extra
arguments. Leave one blank and the engine decides; defaults come from the engine's
own recommendation, and a new pack can add knobs without migrating your config.

**4. Model downloads.** Curated tiers are sized for this Mac's memory, with size and
memory floor printed on the card; the Model Hub searches Hugging Face, sorts by
downloads, filters MLX / GGUF, pages through results, and opens a model card
(README cleaned up before rendering, family badges included). Downloads pause and
resume; weights land in a shared folder as a single copy, and you tick which engines
may use them afterwards.

**5. Readable runtime numbers.** Decode speed, first-token latency, prefill, DFlash2
draft acceptance, cache hit rate, and current context usage (e.g. `18K / 262K`) in one
screen. Total decode is a 60-second live curve; recent requests are listed one by one
with status, decode speed, and context, and the last row stays put after a request
finishes instead of the page resetting to zero. Overview readings all tick at 1 Hz:
the curve draws "how fast right now" and freezes when the request ends, while the hero
number only shows the average since the model started. Every metric has exactly one
source: speed metrics are timed by the gateway per request (measured over wall-clock
windows, so a batch arriving at once does not flicker); prefill prefers the per-request
timing the engine reports itself (`timings`, carried by streaming and non-streaming
responses alike) and falls back to the gateway's TTFT only when that is absent; VRAM
and acceptance rate come from the engine, because only it can measure them. Each
reading declares its provenance (LIVE / LAST / AVG), a cell that cannot be measured
draws "—", and nothing invents a speed from the lower bound of an inter-arrival gap.

**6. Built-in chat.** Streaming output, thinking blocks, Markdown, temperature /
top-p / max output / thinking level; Return sends, ⌘Return inserts a newline; every
reply is stamped with tok/s and first-token latency; history is local, and new and
past chats are always one click away. The first thing to do after installing an
engine is to verify it here.

**7. Draw pictures, make videos, inside a chat.** The composer has a Draw toggle:
when the engine declares `tool-use`, the chat model writes its own storyboard and
hands back several prompts at once; the client calls the image model shot by shot
with one shared seed, hangs each image in the thread as it lands, then returns the
results to the chat model to keep writing — vision-capable models look at the images
first and decide whether to draw more. Image and video models get their own composer:
size, steps, seed, first and last frame; REF2VA models can also take reference images
and reference videos. Outputs go to the Lab with their prompt, model, and seed
attached, and survive a restart.

## Requirements

| | |
| --- | --- |
| Chip | Apple Silicon (M-series) |
| OS | macOS **26.0** or later |
| Disk | About 15 MB for the app (including the `flashcat` CLI); 50 MB – 600 MB per engine; models on top of that (2 – 250 GB per tier) |

The interface follows the system language: **Simplified Chinese** or **English**. Both
sets of copy ship inside the app; change the system language and reopen it.

## Install

Download the latest build from [Releases](https://github.com/imi4u36d/flashCat/releases):

- `flashCat-<version>.dmg` — open it and drag flashCat into Applications
- `flashCat-<version>.pkg` — double-click and follow the installer

The app is not notarized, so the first launch is blocked: in Finder, **right-click
flashCat → Open**, and macOS stops asking. The first launch needs a network
connection to download an engine runtime (80 MB – 600 MB, depending on the engine).

## First launch

1. The launch page lists every supported engine. Pick one, click download, and wait
   for it to finish installing.
2. It becomes the default engine and the window moves into the console automatically.
3. From then on you can install other engines on the **Engines** page, change the
   default there, or download models on the **Models** page.

Every engine is a peer:

| Engine | Default port | Best at | Changing models |
| --- | --- | --- | --- |
| **Splash** | 8000 | One model, least fuss, draft-model acceleration | Restarts the engine |
| **oMLX** | 8100 | Keeping several models resident, switching without a restart | Hot swap |
| **MTPLX** | 8200 | Long context, multi-token prediction | Restarts the engine |
| **MLX-Serve** | 8300 | General MLX / GGUF, multi-model hot loading, tool calling | Hot swap |
| **Strata** | 8400 | SSD expert streaming, large MoE, multiple hardware backends | Restarts the engine |

Every engine supports chat and streaming; vision, thinking, tool calling, and
multi-model support are declared item by item in each engine descriptor, and the UI
never assumes an engine has them. Each engine owns a port block, so they never collide.

## A tour of the interface

**Overview** — engine status, current model, live speed curve, memory and port usage,
and how much context the current session occupies (e.g. `18K / 262K`). On the right
are the API gateway addresses (one line for OpenAI, one for Claude, each with a
one-click copy).

**Chat** — the built-in chat window. The top bar switches models, adjusts temperature /
top-p / max output, and sets thinking mode. Every reply is labeled with tok/s and
first-token latency. Transcripts stay local; start a new one or browse history anytime.

**Models** — one library per engine; pick the engine at the top first (engines you have
not installed still show what they support). Installed weights get a "Use" button,
missing ones a "Download" that pulls in place, and each card lists size, memory floor,
and quantization format (`QUANT`: `Q4_K_M` / `oQ4e` / `8-bit` / `BF16`…).
"Model Hub" in the top right opens search: Hugging Face repositories by popularity,
keyword search, sort by downloads, filter by "All / MLX / GGUF", page through results
(30 per page from HF), and click a row to open its model card (README / file list /
tags) before deciding. Weights land in a shared folder as a single copy, and you tick
which engines may use them; each card's origin is either "engine recommendation" or
"personal download".

**Engines** — one card per engine: status, port, launch arguments, comparison against
the upstream version, plus one-click update, open install folder, view logs, and
removal of a specific version.

**Logs** — live output from the current engine, filterable by "All / Info / Warning /
Error", with search, pause scrolling, and clear.

**Settings** — appearance, background image and opacity, ports, launch at login,
thinking mode, reasoning effort, default model, download cache folder, keeping the
image model resident, and more; every row applies as you change it.

**Lab** — the library of generated results. Switch between "Images / Videos" at the
top, one page of thumbnails per screen, page back from the top left; open one to view
the full image or play the video, with prompt, model, and seed attached so you can
copy it back into the composer and draw again. Only outputs generated in a chat land
here — background and first-frame images you drag into the composer stay out.

Navigation and common actions all live under **Page → Command Palette**: seven pages,
start/stop an engine, new chat, Downloads, Model Hub, toggle appearance, collapse the
sidebar — type a keyword and click a row to jump straight there. The app registers no
keyboard shortcuts; everything can be done with the mouse, and keyboard users should
use the `flashcat` command line described below.

## Connecting your own client

The app ships an **API gateway**, and it is what every client should talk to: the
address is fixed, and both OpenAI and Claude formats work. The `model` in a request
decides which weights actually load: if the model belongs to another engine, the
gateway switches engines; if that engine is not running, it starts it and forwards
once loading finishes.

| | |
| --- | --- |
| Address | `http://127.0.0.1:9000/v1` (port configurable) |
| OpenAI format | `POST /v1/chat/completions` (streaming supported) |
| Claude format | `POST /v1/messages`, `POST /v1/messages/count_tokens` (streaming supported) |
| Model list | `GET /v1/models` |
| API key | Not checked by the local service; any string works |

OpenAI format:

```bash
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

Claude format (set the SDK's Base URL to `http://127.0.0.1:9000`):

```bash
curl http://127.0.0.1:9000/v1/messages \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "your-model-name",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

- Use a name returned by `/v1/models`; the gateway makes sure that model is loaded,
  and Overview shows which one is loaded right now.
- The Claude format is translated in full: system prompt, images, tool calls, stop
  sequences, thinking blocks, and stop reasons such as `end_turn` / `max_tokens` /
  `tool_use` are all supported.
- You can also talk to an engine directly on its own port, but that address changes
  whenever you switch engines — which is why the gateway is usually the better bet.

## The `flashcat` command line

The app ships a complete command-line client that shares the same engines, models,
settings, and logs as the GUI. The `.pkg` points `/usr/local/bin/flashcat` at the
executable inside the app when that directory is writable; with the `.dmg`, or to put
it on your PATH yourself:

```bash
/Applications/flashCat.app/Contents/Helpers/flashcat cli install
# Installs to ~/.local/bin/flashcat by default; add it to PATH:
export PATH="$HOME/.local/bin:$PATH"
```

`flashcat` works in two modes:

- **App running**: it drives the app through a local loopback control interface
  (`127.0.0.1:9100` by default, with a fresh random token on every launch, readable
  only by the current user) to start and stop engines, switch models, download, and
  change settings.
- **App not running**: it can still inspect engines and models on disk, install or
  remove engines, read and write configuration that needs no side effects, and read
  logs. Actions that require the app fail with exit code `3` instead of pretending to
  succeed.

```bash
flashcat                            # Status: app, engine, gateway, downloads
flashcat engines list               # Installed version and state of all five engines
flashcat engines install omlx       # Download and install a runtime without the GUI
flashcat engines start omlx         # Switch to it and wait until weights really load
flashcat models list --all          # Local weights plus recommended tiers
flashcat models download mlx-community/Qwen3-8B-4bit --wait
flashcat models use <model-id>      # Load and wait until ready (switching engines if needed)
flashcat chat "Explain MoE in one sentence"   # Goes through the local gateway, streaming
printf 'Summarize this log\n' | flashcat chat - --model <model-id> --json
flashcat logs --engine omlx -f      # Follow logs; --gateway / --control
flashcat config set appearance dark
flashcat gateway status             # OpenAI / Claude gateway
flashcat app open                   # Launch the app and wait for the control interface
flashcat doctor                     # Check install, permissions, runtimes, disk, PATH
```

To install an engine offline, when the index shipped with the app carries only file
names and not the archives, point at a downloadable index with `--index <pack-index.json
or URL>` (or set `FLASHCAT_PACK_INDEX_URL`); otherwise the command fails clearly with
"the archive named in the index is not on this machine" rather than starting a download
that cannot succeed.

| Command | Purpose |
| --- | --- |
| `status` | App / engine / gateway / download status; `--watch` refreshes continuously |
| `engines` | `list`, `start`, `stop`, `restart`, `use`, `install`, `uninstall`, `port`, `logs` |
| `models` | `list`, `use`, `download`, `delete`, `path` |
| `chat` | Talk through the gateway; stdin, streaming, thinking, and JSON supported |
| `gateway` | `status`, `start`, `stop` |
| `logs` | Engine / gateway / control-interface logs, with level filters and follow mode |
| `config` | `list`, `get`, `set`, `unset`, `path` |
| `app` | `status`, `open`, `quit`, `restart`, `path` |
| `doctor` | Environment check; exits with code 1 if anything reports `fail` |
| `completion` | Emit a zsh / bash / fish completion script |
| `cli` | Link `flashcat` onto your PATH, or print where it currently lives |

**For scripts.** Result-producing commands support `--json` (errors are JSON too, on
stderr); progress and hints go to stderr and the payload goes to stdout, so
`flashcat models list --json | jq` never has log lines mixed in. Exit codes are fixed:
`0` success, `1` failure, `2` usage error, `3` app not running, `4` not found,
`5` timeout, `6` state conflict, `7` bad control token. `--timeout` caps how long a
command waits, `--quiet` silences hints, and `--no-color` or `NO_COLOR` disables ANSI
color.

The control interface's switch and port live under Settings → Command-line Interface.
After you change the port, the effective one is written to `control.json` and the CLI
follows it automatically — no reinstall needed. The interface listens only on
`127.0.0.1`, rotates to a fresh random token on every launch, and keeps `control.json`
at mode `0600`, so other users on the same machine cannot drive the app.

## Models

Models are downloaded inside the app, from Hugging Face. The Models page puts weights
that can load right away under "Local", and tiers this Mac's memory can hold but that
have not been downloaded yet under "FlashCat Recommended":

| Tier | Approximate size | Notes |
| --- | --- | --- |
| Qwen 3.6 35B-A3B | About 16 – 20 GB | The most dependable everyday choice |
| Qwen 3.8 27B | About 16 – 21 GB | Newer generation, better balance of quality and speed |
| Qwen 3.8 Flash-Next | About 99 GB | The heaviest tier; needs 128 GB of memory |

Splash runs GGUF builds of the 27B IQ3_S and Flash-Next Q2_0; oMLX uses Jundot's `oQ4e`
quantization; MTPLX additionally falls back to two Youssofal-optimized packs, MiMo 9B
and Qwen3.5 4B, on low-memory machines. To run something else, open the Model Hub from
"＋ Download Model" in the top right of the Models page, search or browse Hugging Face
repositories, open the model card, and download from there: weights land in a shared
folder as a single copy, and you tick which engines may use them afterwards (ticking
only controls visibility; files are never copied). Whether a given engine can load a
model is the engine's own call, and the Models page keeps downloaded weights separate
from not-yet-downloaded "FlashCat Recommended" tiers, tagging each local weight as
"catalog" or "personal download".

For mirrors or gated repositories, set two preference values from the command line
(leave them alone for huggingface.co and anonymous access):

```bash
defaults write com.zhuo.flashCat hfEndpoint https://hf-mirror.com   # mirror
defaults write com.zhuo.flashCat hfToken hf_xxx                     # token with access
```

The downloader (Python) does not read macOS proxy settings, so the system proxy is
passed to it verbatim when a download starts; running proxy software needs no extra
configuration.

Model ownership uses engine tags: Splash only ships GGUF, oMLX leads with Jundot's
`oQ4e` packs, and MTPLX leads with Qwen while falling back to MiMo 9B and Qwen3.5 4B
on low-memory machines.

Where things live on disk (handy when cleaning up):

| Content | Location |
| --- | --- |
| App configuration, chat history | `~/Library/Application Support/flashCat` |
| Runtime packs for every engine | `~/Library/Application Support/flashCat/engines/<engine>/<version>` |
| Models for every engine | `~/Library/Application Support/flashCat/models/<engine>` |
| Shared folder (your own downloads) | `~/Library/Application Support/flashCat/shared-models` |
| Download cache | Hugging Face's cache directory by default; change it in Settings |
| Control interface | `~/Library/Application Support/flashCat/control.json` (loopback only, mode 0600) |
| Logs | `~/Library/Logs/flashCat` |

## Settings

| Setting | What it does |
| --- | --- |
| Appearance | Follow system / light / dark; applies immediately |
| Port | The engine's listening port; warns when it is taken |
| API Gateway | Switch and port for the unified dual-format endpoint (9000 by default); applies immediately |
| Start with flashCat | Start the engine automatically when the app opens |
| Launch at login | Add flashCat to your macOS login items |
| Thinking mode | Auto / off / on; whether thinking models emit reasoning first |
| Reasoning Effort | Applies when thinking mode is on; the levels come from the engine |
| Default model | Which model to load when the engine starts |
| Download cache folder | Where model downloads are cached |
| Command-line Interface | Switch and port for the local `flashcat` connection (9100 by default) |
| Restore Defaults | Reset everything above to factory values |

## FAQ

**The engine will not start, or spins forever?**
Check the last lines on the Logs page — usually a taken port or a model too large for
memory. Pick another port, or a smaller model tier.

**Downloads are slow?**
The oMLX runtime is about 590 MB; Splash and MTPLX are 80 – 130 MB. Models range from
a dozen GB to 99 GB, so network speed dominates.

**Memory was not released after switching models?**
oMLX can hot-swap between models; Splash and MTPLX restart the process, so wait until
the state reads "Running" again before sending requests.

**Can another machine connect?**
The app listens on `127.0.0.1` only. If you need to serve other machines, put your own
reverse proxy in front of it; do not expose the port directly to the internet.

**The app will not open, saying it is damaged or from an unknown developer?**
Right-click → Open, or go to System Settings → Privacy & Security and click "Open Anyway".

**A model does not show up for an engine on the Models page?**
Switch engines at the top; engines you have not installed can still show the curated
tiers they support.

**Why are there no keyboard shortcuts in the app?**
This release deliberately registers no app-level shortcuts: every action has a
clickable menu item or button, and keyboard efficiency lives in the `flashcat` command
line (completion, JSON, scripting). macOS's own text editing, clipboard, close-window,
and quit keys are unaffected.

**`flashcat` says the app is not running?**
Run `flashcat app open` first. If the app is clearly running, check whether Settings →
Command-line Interface was turned off, or whether `control.json` was deleted;
`flashcat doctor` will say which step fails.

**The command-line port is taken?**
The control interface starts at 9100 and walks forward up to 20 ports; the effective
port is written to `~/Library/Application Support/flashCat/control.json`, and
`flashcat` reads it automatically.

## Uninstall

1. Quit flashCat.
2. Drag `/Applications/flashCat.app` to the Trash.
3. If you installed the command line, remove the links:
   `rm -f /usr/local/bin/flashcat ~/.local/bin/flashcat`
4. To remove configuration and models as well, delete:

```bash
rm -rf ~/Library/Application\ Support/flashCat ~/Library/Logs/flashCat
```

Note that models live in those folders, so deleting them deletes your downloaded
weights too — confirm you have nothing worth keeping first.

## License

[MIT](LICENSE) © 2026 wangzhuo

The inference engines are the work of their respective upstream projects; this project
handles downloading, installing, and orchestrating their runtimes:
[Splash](https://github.com/incoai/splash),
[oMLX](https://github.com/jundot/omlx),
[MTPLX](https://github.com/youssofal/mtplx),
[MLX-Serve](https://github.com/ddalcu/mlx-serve),
[Strata](https://github.com/Niko1221/Strata).
Model copyrights belong to their respective publishers.
