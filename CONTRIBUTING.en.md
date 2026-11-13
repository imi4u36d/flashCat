# Contributing

**English** | [简体中文](CONTRIBUTING.md)

flashCat folds "install an engine, download models, chat, expose a local endpoint" into
a single window. Its value is not the number of features but **collapsing the
differences between five inference engines into one layer** — so the rules that matter
most here are all about not leaking those differences back into the business layer.

## Requirements

| Need | Version |
| --- | --- |
| macOS | 26.0+ (the app targets macOS 26 for Liquid Glass; the MLX-Serve engine's packs are built for 26.4) |
| Xcode / Swift | 6.x toolchain |
| SwiftLint / swift-format | Optional, `brew install swiftlint swift-format` |

## Local checks (all must pass before committing)

```bash
cd native && swift build          # 0 warnings; CI runs with -warnings-as-errors
cd native && swift test           # app layer + Kit cases, about a second
make app                          # assemble the .app in /Applications (or INSTALL=0 for dist only)
```

The whole interface lives in `Sources/FlashCat/UI/`; `swift run flashCat` shows it
directly. There is no packaging step — edit a Swift file, rebuild, look.

Strict concurrency is a **ratchet**, not a "zero warnings" pledge: the repo currently
sits at 0, `native/.strict-concurrency-baseline` records that number, and CI fails only
when the count grows. When you fix a warning, lower the baseline by one — that is how it
walked down to zero without going red on day one, and the ratchet keeps it there.

## Architecture rules (the ones reviewers bounce)

1. **`FlashCatKit` may not import UI.** Only `Foundation` / `Network` / `CryptoKit` are
   allowed. This layer must run in a windowless test process — all 252 Kit cases live
   here; the shell contributes 189 and the CLI another 34 pure-logic cases.
2. **Dependencies point one way.** `FlashCat` → `FlashCatKit`. Any app-side symbol
   appearing inside the Kit is a break.
3. **Engine differences may only live in a descriptor or an adapter.** Do not write
   `if engine == .splash` in `EngineManager`, the install center, or a page. If you
   genuinely need to branch per engine, first ask whether it can become a manifest field.
4. **The manifest contract is the only interface.** Apart from fields declared in
   `manifest.json`, the app interprets no file inside a pack.
5. **Unknown enum values degrade, they do not fail.** Unknown `capability` /
   `modelArgument` values introduced by a newer pack must still install and start in an
   older app.
6. **Only the user's own packs are removable.** Deleting one inside the app bundle
   breaks the signature; one in a checkout is a build artifact. Both are read-only.
7. **No keyboard shortcuts inside the app.** Menus, the command palette, text fields,
   and sheets carry no key equivalents; keyboard efficiency goes through `flashcat`.
   `LocalizationTests.testNoInAppKeyboardShortcutsRemain` scans the source and blocks
   `.keyboardShortcut` / `.onKeyPress` / `.onSubmit` / `NSEvent` monitors.
8. **Paths and the control protocol exist once.** The app and the CLI share
   `FlashCatPaths`, `EngineInstallations`, and `Control/*`; never write a second set of
   directories or JSON shapes inside one target.

The full procedure for adding an engine is in "Adding a new engine" in
`native/Sources/FlashCatKit/SPEC.md`.

## Code style

- 4-space indent; 140-column limit, break the line when you exceed it. Format with
  `swift-format` (`native/.swift-format`).
- **Comments: design notes under `native/` are written in Chinese; interface docs aimed
  at outside contributors are written in English.** Do not mix the two in one file.
  Comments explain *why*, not *what* —
  `// 让大数字、曲线、菜单栏读的都是同一个平滑速率` is a good comment;
  `// 设置 liveDecodeRate` is not.
- `try!` / `as!` / `fatalError` are forbidden; bind or throw on every optional that
  comes from runtime data, never force-unwrap. The only exception is a literal
  `URL(string:)` constant in source (such as `https://huggingface.co`): it is not user
  input, and Foundation offers no non-optional equivalent. Keep such constants to a
  minimum.
- Do not swallow errors with `try?`. Either handle them or write them to `LogStore` —
  the log page is the only place users can diagnose anything.
- Before adding shared mutable state outside `@MainActor`, read how the existing strict
  concurrency baseline is kept at zero (`native/.strict-concurrency-baseline`).

## Tests

- Pure logic goes into `FlashCatKit` with unit tests. **The test: if a behavior can be
  asserted without a window and without an engine process, it does not belong in
  `AppState`.**
- CLI parsing, output, and SSE decoding go into `FlashCatCLICoreTests`; control-protocol
  routing and documents do too (they depend on the Kit and need no running app).
- Bug fixes come with a case that reproduces them. This is especially true for parsing —
  every case in `StatusParserTests` corresponds to a real production bug.
- Install flows that touch real archives use the skip mechanism in
  `PackInstallIntegrationTests`; do not pull GB-sized files in CI.
- **Read `native/Sources/FlashCat/UI-SPEC.md` before changing the interface.** The seven
  pages only read `AppState` and only call its methods; views never make network
  requests, read or write files, or mutate `EngineStore` behind `AppState`'s back. New
  pages reuse the `Native` tokens and components in `Design.swift`; do not introduce a
  second palette or corner radius. Prefer a button or menu item for new actions over a
  keyboard shortcut.
- **Do not bring the web layer back.** No `WKWebView`, no embedded HTML/JS, no
  cross-language snapshot bridge. For rich text use `MarkdownView`; for charts use
  Swift Charts.

## Commits

Conventional Commits, with the module name as the scope:

```
feat(engines): add MLX-Serve and Strata to the multi-engine architecture
fix(kit): stop treating split GGUF in the root as a separate quantization
docs(spec): record that DFlash2 ships with the main model and is filled in before start
```

Types: `feat` / `fix` / `refactor` / `perf` / `test` / `docs` / `chore` / `build`.

One commit does one thing. Large diffs such as formatting or renames go in their own
commit so `git blame --ignore-rev` can skip them.

## Versioning

The `VERSION` file is the single source of truth. Do not hard-code a version anywhere in
a script — `scripts/version.sh` reads it. At release time `VERSION` and the tag must
match; CI enforces it.

## License

By submitting a contribution you agree to license it under [MIT](LICENSE).
