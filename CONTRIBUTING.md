# Contributing to Control Station

Thanks for wanting to make this better! This guide gets you from fork to working
PR, and explains the handful of design rules that aren't negotiable.

## Dev setup

Omarchy loads a plugin from `~/.config/omarchy/plugins/<id>/`, and a plugin's
folder *is* its git checkout. So developing means swapping the installed copy
for your fork:

```sh
omarchy plugin remove justarieldotcom.control-station --yes
git clone https://github.com/<you>/omarchy-control-station \
  ~/.config/omarchy/plugins/justarieldotcom.control-station
omarchy plugin enable justarieldotcom.control-station

# after editing Panel.qml, restart the shell. Hot reload keeps the old IPC
# target and won't reliably reinitialize the panel component
omarchy restart shell
```

If you're forking to publish your *own* variant, give it an id under your own
name: rename the folder, then change `id` in `manifest.json` and every
`justarieldotcom.control-station` in the QML
(`grep -rn justarieldotcom.control-station`). Marketplace ids are permanent and
can't collide.

## How the pieces fit

| File | Job |
|---|---|
| `Model.js` | Pure logic: every parser, the card registry, the bar-chip formatter. No QML imports, no side effects. |
| `Panel.qml` | The dashboard. Owns all state and all fetchers, lays out the bento, handles drag/resize/zoom, hosts the settings editor, answers IPC. |
| `BarWidget.qml` | The bar face. Renders the chips and delegates everything else to the panel it loads. |
| `manifest.json` | Two entry points plus the settings schema the bar's own editor reads. |

One rule explains most of the structure: **the panel is the only data owner.**
`BarWidget.qml` loads `Panel.qml` invisibly and injects `bar`, `settings`,
`anchorItem` and itself into it, so the bar and the panel share one set of
fetches and one IPC target. Don't add a second fetcher for the bar.

Take care around `updateResize`, `spanStep`, `computeFlow` and the zoom grip.
Drag-to-resize used to flicker because the handle was anchored to the thing it
resized, so every span change moved the handle out from under the cursor and
the next event pushed the span straight back. Measure a drag in a frame that
the drag does not move, and keep the span hysteresis — the obvious fix here is
the one that caused the bug.

## Adding a card

1. One entry in `Model.CARDS`: `id`, `title`, `group`, `summary`, whether it's
   `default`, whether it makes sense in the `bar`, its `glyph`, and its `needs`
   (what setting or probe has to be true before the picker offers it).
2. A parser in `Model.js` with assertions in `selfCheck()`.
3. A `Process` in `Panel.qml` plus an entry in the `cardRefresh` table.
4. A body component, and the card's `checkedAt` stamp via `stampCard()`.
5. A `barChip()` case if it's bar-worthy.

Anything the user can configure needs a `schema` entry *and* a `defaults` entry
in `manifest.json`. Settings round-trip as strings, so parse them back with a
range check.

## Testing your change

There's no build step. Run whichever of these your change touches:

```sh
# Model.js: assert-based self check (add your assertions to selfCheck())
node -e "require('./Model.js').selfCheck()"

# QML: expect some noise about qs.Commons / qs.Ui; compare against main, not zero
qmllint -I "$OMARCHY_PATH/shell" Panel.qml BarWidget.qml   # or /usr/lib/qt6/bin/qmllint

# manifest
omarchy plugin validate .

# live: drive the panel over IPC (-q must come BEFORE the target)
omarchy-shell justarieldotcom.control-station refresh
omarchy-shell justarieldotcom.control-station toggle

# geometry: walks the live scene graph and reports per-card overflow as JSON
omarchy-shell justarieldotcom.control-station measure
omarchy-shell justarieldotcom.control-station audit
```

`audit` is the honest way to check a card fits. Every `Text` reports whether it
outgrew its box and every card reports the worst overflow in its subtree, so
clipping is a number instead of a squint. Any card you add or resize should come
back with an empty `issues` array at zoom 1.0.

## Rules that keep this plugin trustworthy

This plugin reaches the network and runs local tools, so these aren't style
preferences. PRs that break them won't be merged:

1. **No API keys, no accounts.** Every source is either open data or something
   already on the user's machine. A card that needs a key doesn't belong here.
2. **No credentials in shipped source**, and nothing that writes a user's URLs
   or company numbers anywhere but their own `shell.json`.
3. **No privilege.** No `sudo`, `pkexec`, systemd units, package installs or
   install scripts. Everything runs as the user, as a child of the shell.
4. **Quote every interpolation into a shell command** (`Util.shellQuote`). Paths,
   symbols, town names and connection names are all user input.
5. **One heartbeat.** New fetchers hang off the existing timer on a stagger.
   No per-card timers, no fetch on every render.
6. **A failed fetch keeps the last good data** and marks itself in
   `failedFetches`. Never blank a card because one request failed.
7. **`Model.js` stays pure.** No `Process`, no QML imports, no clock reads that
   aren't passed in. That's what keeps it testable under node.

## Pull requests

- Keep PRs focused, one idea per PR.
- Say how you tested it (which of the commands above, and on what setup).
- Screenshots or a GIF for anything visual are hugely appreciated.
- Update `README.md` if you change user-facing behavior or settings.

Something else in mind? Open an issue and let's talk.
