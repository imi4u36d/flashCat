# webui-render-check

`WebUI/` is the whole user-facing product and, until this tool existed, it had no
automated test at all. A broken renderer showed up as a blank window that nobody
noticed until they opened that page. This tool is the regression net.

It loads `index.html` in a real `WKWebView`, pushes a snapshot the same way
`WebBridge.pushSnapshot()` does, and asserts that every page paints.

```sh
cd native
swift run webui-render-check --webui Sources/FlashCat/WebUI
```

Exit code is `0` only when every check passes.

## What it checks

| Group | Check |
|---|---|
| boot | the bridge entry points (`__fc__.push`, `__fcToast`, `__fcErrors`) exist, all 14 scripts ran, a stylesheet applied, the body painted a themed background, six nav items rendered |
| fixture | every `snap.<field>` the JavaScript reads exists in the fixture — a renamed field fails here instead of silently emptying a panel |
| pages | all six pages, in a warm state and a cold one (engine stopped, no history): the view switched, the page shell mounted, content rendered, the frame has text and a non-zero box |
| stream | two token deltas extend the last message without creating a second one; `end` leaves the transcript intact |
| nav | clicking each nav item switches the page on the client alone |
| overlay | a sheet opens with text and closes without blanking the page behind it |
| chrome | theme switch, sidebar collapse, toast — all outside `#pageFrame`, so a page-only check would miss them |
| console | no CSP violations, no uncaught exceptions, no logged errors |

## Why it is not an XCTest target

WebKit needs an `NSApplication` and a run loop, and a real (if offscreen) window.
Keeping it out of `swift test` keeps the unit suite fast and free of UI
dependencies; CI runs it as its own job.

## Skips

Two checks wait for `requestAnimationFrame`: the streaming append and its
`end`. WebKit throttles those to zero while the page reports
`visibilityState === "hidden"` — which is what happens on a locked screen or an
unattended CI box. They report `skip` with the reason rather than a failure the
code did not cause. Run the tool with the screen unlocked to exercise them.

Environment noise is handled the same honest way: when the window is hidden,
`document.startViewTransition` rejects and the page logs that rejection. Those
messages are suppressed **and counted** (`suppressed N hidden-window notices`),
and only the exact rejection is matched — an exception thrown *inside* the
transition callback still fails the run.

## The fixture

`Fixtures/snapshot.json` is a captured snapshot in the shape
`WebSnapshot.data(state:)` produces. It is committed so runs are deterministic
and diffs are reviewable.

When you change the snapshot contract in `Sources/FlashCat/WebViewShell.swift`,
update the fixture in the same commit. The `fixture/covers read fields` check
tells you when you forget: it fails with the list of fields the page reads but
the fixture does not carry.

The cold pass is derived from the same file at runtime (engine stopped, `stats`
null, empty history), so there is only one file to maintain.

## Limitations

- It drives the page through the same entry points Swift uses
  (`__fc__.push`, `__fc__.stream`), not through a real Swift bridge. The bridge
  itself is covered by `Tests/FlashCatTests`.
- It renders at one fixed viewport (1440×900); responsive breakpoints are not
  covered yet.
- It does not compare pixels. It asserts structure, layout box and text — enough
  to catch "blank page", not enough to catch "3px misaligned".
