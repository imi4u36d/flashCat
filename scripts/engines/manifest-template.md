# `manifest.json` — engine runtime pack manifest (schemaVersion 1)

One `manifest.json` sits at the root of every installed pack
(`vendor/engines/<engine-id>/<version>/manifest.json`). The app reads it to
decide *what to execute*, *with which arguments*, and *how to poll* the engine.
Nothing else in the pack is interpreted by the app.

```json
{
  "schemaVersion": 1,
  "id": "omlx",
  "name": "oMLX",
  "version": "0.7.2",
  "kind": "bundled",
  "arch": "arm64",
  "minMacOS": "14.0",
  "entrypoint": "python/bin/python3",
  "workingDirectory": ".",
  "modelsSubdirectory": "models",
  "launchProfiles": {
    "default": {
      "args": ["-m", "omlx.cli", "serve", "--host", "127.0.0.1", "--port", "{port}", "--model-dir", "{models}"],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "health": { "path": "/health", "readyStatus": 200, "loadingStatus": 503 },
  "status": ["/api/status", "/v1/models/status"],
  "models": { "path": "/v1/models" },
  "defaultPort": 8100,
  "modelSwitch": "hot",
  "capabilities": ["chat", "streaming", "vision", "reasoning", "multiModel", "hotLoad", "hotUnload", "modelRescan"],
  "license": "Apache-2.0"
}
```

## Fields

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | int | Manifest format version. `1` for everything described here; bump only on breaking changes. |
| `id` | string | Engine id, lowercase, stable across versions (`splash`, `omlx`, `mtplx`). Matches the directory name and is used as the app-side engine key. |
| `name` | string | Human-readable engine name shown in the UI. |
| `version` | string | Exact engine version shipped in this pack. Must equal the `<version>` directory and the version the engine itself prints. |
| `kind` | `bundled` \| `download` | `bundled`: the pack ships with (or is built into) the app. `download`: the app fetches the pack separately. |
| `arch` | string | Required CPU architecture, e.g. `arm64`. The app refuses to run the pack on another arch. |
| `minMacOS` | string | Minimum macOS version, `major.minor`. mlx-based engines need Metal features of a recent release. |
| `entrypoint` | string | Executable to spawn, relative to the pack root. Template variables are allowed. Packs here use `python/bin/python3` (the bundled CPython). |
| `workingDirectory` | string | cwd for the spawned process, relative to the pack root. `.` = the pack root, so relative engine paths resolve inside the pack. |
| `modelsSubdirectory` | string | Directory (inside the pack or inside the user data dir, depending on the app's mode) where model folders are discovered. Created empty by the build scripts. |
| `launchProfiles` | object | Named argv/environment recipes. `default` is used unless the user picks another profile. |
| `launchProfiles.<name>.args` | string[] | argv passed to `entrypoint` **as an array** — never a shell string. `{port}`, `{model}`, … are substituted by the app (see below). |
| `launchProfiles.<name>.environment` | object | Extra environment variables merged over the inherited environment. `PYTHONNOUSERSITE=1` keeps the user's `~/.local` site-packages out; `PYTHONDONTWRITEBYTECODE=1` keeps the pack read-only-safe; `PYTHONUNBUFFERED=1` gives live logs. |
| `health.path` | string | Health probe path. The app polls it until it answers with `readyStatus`. |
| `health.readyStatus` | int | HTTP status meaning "engine ready". |
| `health.loadingStatus` | int | HTTP status meaning "engine still loading" (e.g. model swap). Any other status is treated as a failure. |
| `status` | string[] | Extra status endpoints the app may poll for rich engine telemetry (scheduler, memory, per-model state). |
| `models.path` | string | OpenAI-compatible model listing endpoint. |
| `defaultPort` | int | Preferred localhost port. The app may pick another one and pass it via `{port}`. |
| `modelSwitch` | `hot` \| `restart` | `hot`: the engine can load/unload models in-process. `restart`: a model change requires restarting the process with a new `{model}`. |
| `capabilities` | string[] | Feature flags used to gate UI: `chat`, `streaming`, `vision`, `reasoning`, `multiModel`, `singleModel`, `hotLoad`, `hotUnload`, `modelRescan`, `mtp`. |
| `warmup` | object | **MTPLX only.** `precompiled`: pack-relative files to copy into `cacheDir` before the first launch. `cacheDir`: destination, `{home}`-anchored. Lets a machine without a compiler skip the `_paged_ops` build. |
| `license` | string | SPDX identifier of the bundled engine (`Apache-2.0` for both omlx and mtplx). |

## Template variables

Only these tokens are substituted, and only inside `entrypoint`, `workingDirectory`
and `launchProfiles.*.args` / `.environment` values:

| Token | Expands to |
|---|---|
| `{root}` | absolute pack root (the directory holding `manifest.json`) |
| `{port}` | the port the app decided to bind |
| `{models}` | absolute directory the app wants the engine to scan for models |
| `{model}` | absolute path of the single model to serve (single-model engines) |
| `{support}` | the app's writable support/data directory |
| `{home}` | the user's `$HOME` |

Anything else in braces (`{apiKey}`, `{foo}`, …) is **not** substituted. If an
engine needs a value that is not in this list, either raise it with the app team
first, or pass it through `environment`.

## Rules and gotchas

- **The pack is not relocatable.** The MTPLX native extension carries an absolute
  rpath into `<pack>/python/lib/python3.13/site-packages/mlx/lib`, so the install
  path must include the version and must never move after installation.
- `version` in the manifest, the directory name, and the engine's own
  `--version` output must agree — the build scripts enforce this.
- Keep `modelSwitch` honest: MTPLX reloads the model by restarting (`restart`),
  oMLX swaps models inside one process (`hot`), so the app must not try to
  hot-swap a `restart` engine.
- Adding a field is backward compatible; renaming or repurposing one requires
  `schemaVersion` to change.
