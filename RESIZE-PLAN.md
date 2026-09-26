# Drag-to-resize: diagnosis and improvement plan

Investigated 2026-09-26 against `Panel.qml` (4102 lines) in this directory.

Symptom reported: dragging a card's corner handle to resize it flashes and is
not smooth.

The flashing is not a rendering or vsync problem. It is a positive feedback
loop between the drag handle and the thing it resizes, plus a full delegate
teardown at the end of every drag. Four separate defects stack up.

---

## Root causes

### 1. The handle runs away from the cursor (this is the flashing)

`resizeHandle` is anchored to `gridCell.right` / `gridCell.bottom`
(`Panel.qml:2586-2588`), and `gridCell.width` is driven live by
`root.resizeLive.span` (`Panel.qml:2544-2550`). The MouseArea fills that
handle and reports `mouse.x` **in the handle's own coordinate system**
(`Panel.qml:2607-2611`).

So the instant a span threshold is crossed, the card grows ~180px, the handle
jumps 180px right along with it, and the very next mouse event reports an `x`
that is 180px *smaller* -- which pushes the span straight back down.

Simulated with the real constants (`cellWidth 170`, `gridGap 10`), one smooth
240px drag:

```
span flips: 35
cols sequence: 111111111111111111111111121212121212121212121212121212121212
```

35 flips in a single drag -- that is exactly the reported flashing.

Note the sequence never reaches `3`. Because the handle outruns the cursor,
**3-column and 2-row spans are effectively unreachable by dragging**, no
matter how far the pointer is pulled.

### 2. Every resize destroys and rebuilds all 12 cards

`Repeater { model: root.cellPlans }` (`Panel.qml:1802-1804`) uses a plain JS
array. `computeFlow()` assigns a fresh array (`Panel.qml:380`), which resets
the delegate model.

Verified on this machine with `qml6`: reassigning an array with the same ids
and one changed field produced **3 delegates created, 3 destroyed**.

So `endResize()` -> `computeFlow()` tears down and recreates every card, every
`Loader`, and every card body. It also fires `registerLoader` 24 times, each
call copying the whole `loaders` map (`Panel.qml:220-226`). This is the
visible lurch at the end of a drag.

The same teardown happens on card reorder and swap, so fixing it helps there
too.

### 3. Zoom is applied in the wrong direction

`updateResize` multiplies the drag delta by `root.zoom`
(`Panel.qml:410-411`). But the grid lives under `zoomHost`, which carries
`scale: root.zoom` (`Panel.qml:1692-1695`), so `mouse.x` is *already* in
unscaled local units matching `cellWidth`. The multiply double-counts:

- at zoom 1.6 the drag is 60% oversensitive
- at zoom 0.75 it is sluggish

### 4. Nothing animates, and the Flickable can steal the drag

- No `Behavior` on `GridCell.x/y/width/height`, so reflow teleports.
- Neighbours do not move during the drag (`computeFlow` is not called until
  release), so the growing card overlaps them and then everything snaps.
- The handle's MouseArea sits inside `bentoScroll` (`Panel.qml:1783`) with no
  `preventStealing`, so a downward drag can hand the grab to the Flickable
  mid-resize.

### Bonus: the panel grip has the same bug class

The panel grip (`Panel.qml:2311-2316`) is anchored to a parent whose size is
`root.zoom`-driven, so `updatePanelZoom` (`Panel.qml:439-443`) has the
identical runaway loop. Worse, each frame resizes *and repositions* a Wayland
layer-shell surface (via `panelContentHeight`, `Panel.qml:1139`), which costs
a compositor round-trip per frame.

---

## Plan

### Fix 1 -- measure the drag in a coordinate space that does not move

*(the actual cure)*

In the handle's `onPressed` / `onPositionChanged`, map the point into
`gridItem` before using it:

```qml
var p = resizeHandle.mapToItem(gridItem, mouse.x, mouse.y)
```

`gridItem`'s origin is stable during a drag, and mapping through it also stays
correct if the Flickable scrolls mid-drag. Store `pressGX` / `pressGY` in
place of `resizePressMX` / `resizePressMY`.

Verified against the same simulation: **flips 35 -> 1**.

### Fix 2 -- add span hysteresis

With the coordinate fix alone, a hand resting exactly on a threshold still
chatters:

```
cursor on the 1->2 boundary, +/-2px tremor, 40 events:
  no hysteresis : 39 flips
  hysteresis 0.2:  0 flips
```

Require ~0.2 of a cell past the current span before committing to a new one.

### Fix 3 -- drop the `* root.zoom` factor

Remove it from `updateResize` (`Panel.qml:410-411`) so sensitivity is correct
at every zoom stop.

### Fix 4 -- stop recreating delegates

Replace the JS-array model with a `ListModel` (or `DelegateModel`) synced in
place: `computeFlow` sets `x/y/w/h` on existing rows and only inserts, removes
or moves when the card set actually changes. Kills the release lurch, and also
speeds up reorder and swap.

### Fix 5 -- live reflow plus animation

Once delegates are stable:

- call `computeFlow()` from `updateResize` when the span actually changes (it
  already reads `resizeLive` via `sizeFor`), so neighbours slide out of the way
  during the drag instead of being overlapped
- add to `GridCell`:
  `Behavior on x/y/width/height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }`
- drop the now-redundant `resizeLive` override at `Panel.qml:2544-2550`
- suppress the animation on first load so the panel does not fly in

### Fix 6 -- `preventStealing: true`

On the handle's MouseArea, so `bentoScroll` cannot hijack a vertical resize.

### Fix 7 -- the panel grip

Apply the same `mapToItem` treatment, and throttle the layer-shell resize:
drive a local `zoomPreview` during the drag and commit to `root.zoom` (and the
surface size) only on release, or gate it behind a short timer.

---

## Sequencing and risk

**Stage A (fixes 1, 2, 3, 6)** -- contained to two functions and one MouseArea,
roughly 30 lines. Resolves the flashing on its own. Do this first and feel the
difference before touching anything else.

**Stage B (fix 4)** -- the larger change; it alters how the grid is modelled.
It is what makes stage C worth doing.

**Stage C (fix 5)** -- live reflow and animation.

**Stage D (fix 7)** -- independent of the rest.

This plugin is not under version control, and the shell hot-reloads on save,
so copy `Panel.qml` to a timestamped backup before editing and verify each
stage with:

```bash
omarchy-shell shell summon justarieldotcom.control-station '{}'
```

If a change somehow fails to apply, force a reload with
`omarchy-shell shell rescanPlugins`.

---

## Outcome — implemented 2026-09-26

All seven fixes landed in `Panel.qml`. Backup of the pre-change file:
`~/.config/omarchy/plugin-backups/justarieldotcom.control-station.Panel.qml.bak.20260926-223033`.

| Fix | Where |
|-----|-------|
| 1. Measure in `gridItem` space (`resizePressGX/GY`) | handle MouseArea `onPressed` / `onPositionChanged` |
| 2. Span hysteresis (`spanHysteresis: 0.2`) | new `spanStep()` |
| 3. `* root.zoom` dropped | `updateResize()` |
| 4. `cellPlans` is a `ListModel`, synced in place | new `syncCellPlans()` |
| 5. Live reflow + `Behavior` on `x/y/width/height` | `updateResize()`, `GridCell` |
| 6. `preventStealing: true` | handle MouseArea (and the panel grip) |
| 7. Grip reads screen coords; zoom commit throttled | `panelGrip`, `zoomDraft`, `zoomCommit` timer |

`GridCell` now takes `required property var model` instead of `modelData`, and
the card id role is `cardId` (`id` is a ListModel role that reads badly in QML).
`resizeStartW/H` are read from the model row, not the item, so a drag started
mid-animation still measures from the settled size.

### Verified

A harness (`qml6` 6.11.2) that imports the real `computeFlow`, `syncCellPlans`,
`spanStep`, `updateResize` and `endResize` bodies straight out of `Panel.qml`,
with a delegate that counts construction and destruction:

```
smooth 240px drag, stable frame : flips=1   final 2x1
  cols: 111111111111111111111111111111122222222222222222222222222222
same drag, old moving frame     : flips=27
  cols: 111111111111111111111111111111121212121212121212121212121222
reach test (+400,+240)          : final 3x2   (3 columns / 2 rows now reachable)
tremor on the 1->2 boundary     : flips=0     (40 events, +/-2px)

resize a card      : 0 delegates created, 0 destroyed   (was 12 / 12)
swap two cards     : 0 created, 0 destroyed
remove one card    : 0 created, 1 destroyed
re-add it          : 1 created, 0 destroyed
```

`qmllint` reports the same warning set before and after (only the unresolvable
`qs.Commons` / `qs.Ui` imports and pre-existing notes). Live in the shell:
`audit` loads all six enabled cards with zero geometry issues, and the shell
log is clean.

---

## Follow-up — panel zoom (the grip), 2026-09-26

The grip was still broken after the first pass. Two corrections to the
diagnosis above, both found by probing the live panel over IPC rather than
reading the code.

### The "Wayland round-trip per frame" premise was wrong

`KeyboardPanel` is a **full-screen** layer-shell `PanelWindow` (`anchors` all
four sides, `mask` fixed to `screenW`/`screenH`). The visible panel is a plain
`BorderSurface` *inside* that surface, placed at `cardOrigin`. Changing
`contentWidth`/`contentHeight` therefore moves and resizes an Item in the
scene — the Wayland surface never reconfigures, and there is no compositor
round-trip to throttle.

So the 50ms `zoomCommit` timer from Fix 7 bought nothing and cost everything:
it turned a continuous drag into 20 discrete jumps a second. **That was the
choppiness.** Timer and `zoomDraft` removed; `root.zoom` is assigned directly
again.

Keeping the screen-coordinate measurement was still right — see below.

### `zoomHost` scaled about its centre

`zoomHost` had the default `transformOrigin: Item.Center`, while the card it
lives in hangs from a fixed top edge and grows downwards. So the content was
painted offset by `height * (zoom - 1) / 2`. Measured in the running panel:

```
zoom   card box     zoomHost painted y     keyCatcher h
0.75   452 x 373      57  ->  397              341      (57px gap on top, bottom clipped)
1.0    592 x 486       0  ->  454              454
1.3    760 x 622     -68  ->  522              590      (top 68px cut off)
1.6    928 x 758    -136  ->  590              726      (toolbar + first row gone)
```

At high zoom the toolbar and the top of the first card row were painted above
the card and clipped away, with an equal band of dead space at the bottom.
That is the "doesn't work". Fixed with `transformOrigin: Item.Top`; the
painted box is now exactly `0 .. height * zoom` at every stop.

While there: `fittedContentWidth` does not add the card's padding and borders
the way `fittedContentHeight` does, so the content box was 32px narrower than
`zoomHost` and the grid spilled over the border on both sides at every zoom.
The inset is now added at the call site.

### Gain and axis

The old `((dx) + (dy)) * 0.005` crossed the entire 0.75..1.6 range in 85px of
diagonal movement — which is why the persisted `zoom` was sitting on the
0.75 floor. It is now `dy / zoomHost.height`, the exact rate the grip travels,
so the handle stays under the pointer.

The horizontal drag is ignored on purpose: the card is pinned to the right
edge of the screen and grows leftwards, so its right edge cannot follow the
pointer. Feeding `dx` in only added zoom that the grip had to express
downwards, and the corner then outran the cursor.

### Verified

A probe (since removed) replaying drags through the real `beginPanelZoom` /
`updatePanelZoom` with screen coordinates, reporting where the grip landed
relative to the cursor:

```
from zoom  drag (dx,dy)   zoom ->    reversals   grip vs cursor
1.00       (  0, 200)     1.441          0          +0 px
1.00       (150, 150)     1.330          0          +0 px
1.00       (300,   0)     1.000          0          +0 px   (horizontal ignored)
0.75       (  0, 400)     1.600          0         -15 px   (clamped at max)
1.60       (  0,-400)     0.750          0         +15 px   (clamped at min)
```

Before the axis fix, the `(150,150)` drag overshot by **+122px**.

`qmllint` warning set is still identical to the original file. Live: `audit`
loads every enabled card with zero geometry issues and the shell log is clean.

### Operational note

**Plugin hot-reload does not re-register the panel.** Saving `Panel.qml` logs
`Local plugin changed, reloading`, but the existing panel instance keeps
ownership of the `IpcHandler` target, so new IPC functions never appear and
panel changes may not be live. `omarchy restart shell` is required to test a
`Panel.qml` change. (`omarchy-shell shell rescanPlugins` is not enough.)
