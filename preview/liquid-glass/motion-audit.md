# flashCat Liquid Glass Motion & Interaction Audit

Audit date: 2026-11-03

Scope: `preview/liquid-glass` only.

Initial audit constraint: that pass added only `motion-audit.md` and
`motion-guard.js`; remediation changes are listed below.

## Remediation Status

Updated 2026-11-03 after the page pass:

- Overlay close now waits for a 150 ms exit transition before clearing the
  overlay state and accessibility attributes.
- Non-page-change commits use `FCMotionGuard.fadeSwap()` and preserve the
  focused control and scroll position.
- All product-visible text is at least 10 px at 1512x982 across the six pages.
- Light and dark muted text now use higher-contrast `--text-3` values.
- Inspector and download sheets stay inside the app window at 390x420.
- The model library cards now use the same Widget surface, icon block, status
  pill, edge highlight and grouped spec strip as the overview page.
- HIG Doctor 2.0.3 reports 0 critical and 0 serious findings. Remaining
  moderate findings are the generic hardcoded-size/less-than-12px checks and
  the intentional `!important` motion-measurement guards.

## Executive Summary

The preview has a strong Liquid Glass visual foundation, but the current
interaction layer is inconsistent. Several actions are visually animated, while
nearby state changes still replace the whole page or remove DOM immediately.
That combination is the main source of perceived flashing and lost animation.

Highest-priority findings:

1. **Overlay exit is instant.** `closeOverlays()` removes every open class in the
   same frame. The model menu reaches `visibility: hidden` immediately instead
   of playing its defined exit state.
2. **Whole-page replacement interrupts local motion.** More than twenty state
   changes call `renderPage(false)`. This destroys focus, scroll position,
   running card animations, switch transitions, and open local state.
3. **Typography is not readable enough.** The source contains 92 CSS
   declarations below 10px. At 1512x982, 131 visible text nodes were below 10px:
   overview 53, models 39, engines 18, logs 19, chat 1, settings 1.
4. **Muted text fails normal-text contrast.** `--text-3` is approximately
   2.47:1 on a white light surface and 3.56:1 on the dark page background.
5. **The parameter panel exceeds the app window on short viewports.** At
   390x420 its measured top is -52px while the app window begins at 30px.

## Audit Method

- HIG Doctor 2.0.3: `264` potential concerns, `1509` positive patterns, and
  `198` component usages across 5 HIG categories.
- Source review of all 8 JavaScript files and 5 stylesheets in scope.
- Browser verification at 1512x982, 820x820, 390x844, and 390x420.
- Light and dark appearance checks.
- Runtime sampling of overlay open/close state, bounds, opacity, visibility,
  computed font size, and overflow.
- The automated scan is evidence, not a full accessibility certification.
  Regex-only findings were separated from browser-confirmed behavior.

## Confirmed Findings

### P0: Overlay close paths flash and skip exit motion

Evidence:

- `app.js:1285-1291`: `closeOverlays()` immediately removes `is-open`,
  `command-open`, `inspector-open`, `downloads-open`, and `model-open`.
- `styles.css:3132-3140`: hiding `.overlay-layer` is tied to `visibility`.
- `chat-thinking.js:382-392`: the thinking menu is removed from the DOM before
  any exit animation can run.
- Browser probe: the first close sample already had
  `visibility: hidden`, `opacity: 0`, and no running animation.

Impact:

- Menu, parameter sheet, download sheet, and command palette disappear rather
  than dismiss.
- Perceived blinking is strongest on translucent surfaces because the entire
  layer changes visibility at once.

Recommended integration:

- Keep the open class until the target panel finishes a short `exit()` or
  `fadeSwap()` transition.
- Clear `aria-hidden` and `state.currentOverlay` only in the transition
  completion callback.
- Use `FCMotionGuard.exit(panel, { duration: 150, distance: 6 })` before
  removing overlay classes.

### P0: `renderPage(false)` resets entire workspaces

Evidence:

- `app.js:345`: all page content is produced by one `frame.innerHTML` commit.
- `app.js:965`, `980`, `1030`, `1109`, `1118`, `1138`, `1241`, `1274`,
  `2335`, `2419`, `2450`, `2455`, and `2482` call `renderPage(false)`.
- `app.js:1194` and `1219` re-render chat after streaming changes.

Affected behavior:

- Engine start/stop replaces overview and engine cards instead of transitioning
  only changed status areas.
- Opening engine configuration rebuilds the whole page; the two-column layout
  switches immediately while only the new panel animates in.
- Settings toggles and appearance choices rebuild the setting page, discarding
  the switch and segmented-control transition that was just triggered.
- Chat completion rebuilds messages after a streaming answer, resets scroll
  behavior, and restarts all message entrance animations.
- Search in the model page calls `updateModelsGrid()` and replaces the grid at
  `app.js:2513-2518` on every input event.

Recommended integration:

- Prefer targeted DOM updates for one changed field or card.
- Where replacement is unavoidable, wrap the commit:

```js
await FCMotionGuard.fadeSwap(grid, () => {
  grid.innerHTML = nextMarkup;
}, { durationOut: 90, durationIn: 220 });
```

- Do not use page-level replacement for toggle, status, progress, filter, or
  text-only changes.
- Preserve focus and input selection across any search-result update.

### P1: Filter and row visibility changes use instantaneous `display: none`

Evidence:

- `app.js:2560-2568`: log rows receive `hidden` directly.
- `styles.css:2711`: `.log-line.hidden { display: none; }`.
- `styles.css:3671`: several responsive sidebar elements use `display: none`
  in addition to opacity and max-width.
- `styles.css:3682` and nearby responsive rules also remove controls with
  `display: none`.

Impact:

- Log filtering, live search, and some resize transitions collapse layout in a
  single frame.
- Existing `log-in` animation covers additions, but not removals.

Recommended integration:

- Animate logs through opacity and translate, then set `hidden` after exit.
- Batch row exits with a small stagger; keep the console scroll position stable.
- On responsive breakpoints, prefer container-aware visibility rules where
  layout permits it; preserve reduced-motion behavior.

### P1: Parameter panel exceeds the app window in short viewports

Evidence:

- `styles.css:3196-3206`: inspector height is content-driven.
- `styles.css:3735`: narrow layout pins the panel to the bottom but does not add
  `max-height`, `overflow-y`, or safe-area constraints.
- Browser measurement at 390x420:
  - app window: top 30, bottom 412;
  - inspector: top -52, bottom 408, height 460;
  - `inside: false`.

Recommended integration:

- For inspector and download sheet, compute `max-height` from the `.window`
  boundary and enable internal scrolling when constrained.
- Use `FCOverlayBounds.place()` for the inspector/command palette, or port the
  same boundary math into their responsive CSS.
- Add a compact-header layout when the safe content height is below roughly
  500px.

### P1: Small type and low-contrast metadata are widespread

Measured type scale:

| Page | Visible text below 10px at 1512x982 |
| --- | ---: |
| Overview | 53 |
| Models | 39 |
| Engines | 18 |
| Logs | 19 |
| Chat | 1 |
| Settings | 1 |

Notable examples:

- `styles.css:2175`: request rate unit is 6.5px.
- `styles.css:1846-1853`: provider mark is 7px.
- `styles.css:1283-1291`: flow-stage label is 8px.
- `styles.css:3440`: engine live heading is 8px.
- `styles.css:3447-3450`: metric tags, units, and hints are 8.5-9.5px.
- `styles.css:3455-3459`: request metadata and footer are 8.5-9px.
- `styles.css:3475-3485`: model metadata and actions are 8-9px.
- `styles.css:3488-3495`: engine metadata and log preview are 8.5-9px.
- `chat-thinking.css:419-425`: effort headings and hints are 8-9px.
- `model-workspace.css:481` and `629`: model specs and empty text are 9px.
- `engine-workspace.css:362`: engine metadata labels are 9px.

Contrast estimate:

- Dark `--text-3: rgba(222, 227, 241, .43)` on `#0d1018` is about 3.56:1.
- Light `--text-3: rgba(33, 41, 56, .42)` on white is about 2.47:1.
- Translucent glass backgrounds may make the real ratio worse.

Recommended baseline:

- Normal body and control text: at least 12px.
- Metadata and uppercase micro-labels: at least 11px, with 10px reserved for
  nonessential decorative labels.
- Numerals and chart axes: at least 10px when they carry meaning.
- Raise light-theme `--text-3` toward 0.65 alpha and dark-theme `--text-3`
  toward at least 0.50 alpha, then re-check composited contrast on both glass
  backgrounds.
- Do not solve readability by making the page visually denser; remove
  redundant secondary copy before shrinking it.

### P1: Several button groups animate the indicator but rebuild the content

Good existing patterns:

- `styles.css:940-975`: page transitions use `startViewTransition`.
- `styles.css:2473-2487`: legacy engine tabs animate their indicator.
- `model-workspace.css:40-61`: model filter indicator has a 420ms spring.
- `styles.css:2754-2786`: settings and log segmented controls use a sliding
  segment.
- `styles.css:2311-2332`: reasoning disclosure uses animated grid rows.
- `chat-thinking.css:116-190`: menus have directional open animation.

Broken continuity:

- Settings appearance/thinking changes call `renderPage(false)`, so the
  segmented control is replaced instead of continuing its transition.
- Model search replaces the grid on every input with no transition.
- `setModelFilter()` fades out for only 110ms, replaces entire card markup, then
  restarts every card entrance animation (`app.js:2551-2568`).
- Engine configuration opening switches the workspace grid immediately; only
  the panel itself enters (`app.js:1020-1031`, `engine-workspace.css:20-23`,
  `engine-workspace.css:949-967`).

Recommended integration:

- Keep the segmented indicator element stable.
- Animate grid/list changes through `fadeSwap()`, not through an arbitrary
  timeout followed by `innerHTML`.
- Use one transition token per container so rapid clicks cannot queue stale
  commits.

### P2: Overlay positioning helper can suppress motion during measurement

Evidence:

- `overlay-bounds.css:20-26`: the measuring class sets `animation: none`,
  `transition: none`, and `pointer-events: none`.
- `overlay-bounds.js:205-278`: measurement may temporarily set display and
  visibility.
- `overlay-bounds.js` defaults to `animate: false`.

Current runtime result:

- Model popover, thinking menu, inspector, and download sheet remained inside
  the window at 1512x982, 820x820, and 390x844.

Risk:

- Repositioning while the sidebar is dragged or resized is intentionally
  immediate, but temporary hiding/measuring must never happen after the panel
  is visible.
- A future caller that positions a `display: none` panel can produce a hidden
  measurement frame.

Recommended integration:

- Measure before adding the visible class.
- Prefer `transform` for anchor-origin movement once the panel is visible.
- Keep `animate: false` only during direct drag tracking; use an animated
  reposition for window resize and sidebar collapse.

## Page-by-Page Checklist

### Overview

- Preserve the existing token-flow canvas and model character roll.
- Do not rebuild the entire widget grid for engine start/stop; update the status,
  rate, buttons, and meter in place.
- Add readable minimum sizes to request metadata and metric hints.
- Keep the chart's current-history ordering fixed; only append new samples.

### Chat

- Reasoning disclosure is already smooth; keep it.
- Replace the message list swap after stream completion with localized metadata
  and card updates.
- Thinking-mode cycling should animate the trigger value rather than rebuilding
  the page.
- AI icon treatment is already consistent and should not be converted back to a
  portrait-style avatar.

### Models

- Keep the engine-filter indicator.
- Animate search result replacement with `fadeSwap()`.
- Preserve card identity where possible so progress and download state animate
  instead of restarting card entrance.
- Raise specs, repo text, tags, and action labels above the current 8-9.5px.

### Engines

- Opening and closing configuration needs a FLIP or grid transition for the
  workspace, not just panel entrance.
- Keep cards stable when toggling installed, running, updating, and deleting
  states.
- Preserve focus on the config trigger when the panel closes.

### Logs

- Animate filter removal and live-search hiding.
- Keep timestamps, levels, and messages on consistent columns at readable sizes.
- Restore scroll position after filtering unless the user is explicitly
  following the live tail.

### Settings

- Animate toggles and segmented changes in place.
- A theme change should transition colors through a stable shell and should not
  replace the settings DOM.
- Keep the current single-screen density, but remove low-value microcopy before
  reducing type size.

### Menus and Overlays

- Apply exit transitions to model menu, thinking menu, inspector, downloads,
  and command palette.
- Clamp panel height to `.window` and enable internal scroll.
- Keep focus restoration after close.
- Do not let a closing panel remain keyboard-focusable or exposed to
  accessibility APIs.

## Automated Scan Notes

- Detected framework: HTML.
- HIG Doctor found 264 potential concerns, including multiple
  `font-size-below-12px`, `outline-none`, and `overflow` rules.
- Some `outline: 0` findings are mitigated by visible `:focus-within` or
  `box-shadow` focus states, but `chat-thinking.css:144` and
  `.sidebar-resize:focus-visible` still need explicit focus treatment.
- The scan cannot prove whether a transition is visually smooth or whether a
  DOM replacement flickers. Those findings above come from source and browser
  probes.

## Motion Guard Integration Order

1. Install `motion-guard.js` after `overlay-bounds.js` and before business
   handlers initialize.
2. Replace instant overlay dismissal with `FCMotionGuard.exit()`.
3. Replace high-value whole-page commits with `fadeSwap()`:
   model grid, log console, settings rows, request list, engine state cluster.
4. Use `observeTruthy()` only for conditionally added local objects such as
   engine panels and inline notices. Do not observe an entire page.
5. Use `pulse()` for acknowledgement after copy, save, refresh, or model
   selection.
6. Verify rapid repeated actions: second click must cancel or reverse the first
   transition without committing stale markup.
7. Re-run at 1512x982, 820x820, 390x844, and 390x420 in both appearances.

## Acceptance Gate

A page is considered ready only when all of the following hold:

- No user-visible `display` or `visibility` switch occurs at full opacity.
- Every open action has a reversible close path with matching timing.
- No text node carrying product meaning is below 10px.
- Body and controls target 12px minimum and pass normal-text contrast.
- Every menu, sheet, popover, and toast stays inside the app window.
- Rapid repeated toggles produce no stale commits, no duplicate overlays, and no
  focus loss.
- `prefers-reduced-motion` removes motion without changing state correctness.

