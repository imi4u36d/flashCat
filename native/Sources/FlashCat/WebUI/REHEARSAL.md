# Rehearsal: flashCat WebUI control redraw

Gold: `controls` for button/icon anatomy and `choreography` for cause/response timing. The product's own layout, content hierarchy and flashCat mascot were kept; the app icon is explicitly out of scope.

Beats: page enters -> status/action responds -> result content settles; menus open from their trigger; the sidebar divider and rail move as one object; charts draw once; messages arrive from their own side.

Captured: installed app at 1280x820; full sidebar and rail; overview, chat, models, engines, logs and settings; light and dark appearances; model switcher popover.

Checks:
- CSS and JavaScript parse; every statically named icon exists in the local Lucide subset.
- Buttons use one 6px geometry, 28-30px control height, shared press and focus states.
- Hero actions have a 16px separation from the API block; the removed Claude helper copy is absent.
- Metric order is decode, prefill, TTFT, memory.
- Sidebar controls and menu triggers expose button semantics and keyboard activation.

Not checked: reduced-motion mode on a physical device, a live token stream, long log lists, and the model-search modal during an actual Hugging Face request.
