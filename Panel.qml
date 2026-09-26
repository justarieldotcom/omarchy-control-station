import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Control Station — a resizable bento dashboard: Weather, Market, Companies
// House, Calendar, System, Reminders. One heartbeat timer drives all fetchers;
// each card shows "checked at HH:MM". Drag a card onto another to swap their
// cells (order persists in the `layout` setting); the corner handle (enable via
// the resize button) changes a card's span (persisted in `sizes`); the gear
// opens the in-panel plugin settings editor.
Panel {
  id: root
  moduleName: "justarieldotcom.control-station"
  ipcTarget: "justarieldotcom.control-station"
  manageIpc: false

  property var hostWidget: null
  // Set by BarWidget.qml: the object holding the bar chips, so `audit` can
  // report them. Null when the panel is not hosted in a bar.
  property var barChipsProvider: null
  // Injected by BarWidget.qml when this panel is hosted on the bar; null when
  // the panel is loaded standalone, in which case the internal button below
  // doubles as the popup anchor.
  property Item anchorItem: button

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- settings
  property string weatherTown: setting("weatherTown", "")
  property string weatherCoords: setting("weatherCoords", "")
  property string settingSymbols: setting("symbols", Model.DEFAULT_SYMBOLS)
  property string companyNumber: setting("companiesHouseNumber", "")
  property bool showHeaders: String(setting("showHeaders", "true")).toLowerCase() !== "false"
  property string calendarUrl: setting("calendarIcalUrl", "")
  property int refreshIntervalSec: Math.max(60, parseInt(setting("refreshIntervalSec", 300), 10) || 300)
  property string repoPathsRaw: setting("repoPaths", "")

  readonly property var companyNumbers: (function() {
    var out = []
    var parts = String(root.companyNumber || "").split(",")
    for (var i = 0; i < parts.length; i++) {
      var n = String(parts[i] || "").trim()
      if (/^[A-Za-z0-9]+$/.test(n)) out.push(n.toUpperCase())
    }
    return out
  })()

  readonly property var repoPaths: Model.parseRepoPaths(root.repoPathsRaw, Quickshell.env("HOME"))

  // ------------------------------------------------------------- data state
  property var weather: ({})
  property var market: ({ symbols: [], checkedAt: "" })
  property var companies: []
  property var calendar: ({ events: [], checkedAt: "" })
  property var system: ({})
  property string systemAt: ""
  // Ids whose last fetch came back empty; the data shown is the last good one.
  property var failedFetches: []
  // A geometry snapshot taken while the panel was definitely on screen.
  property string measureJson: ""
  property bool measurePending: false
  property int measureTries: 0
  property var reminders: ({ count: 0, reminders: [], checkedAt: "" })

  // ---------------------------------------------- the six newer cards
  // Each one keeps its own data plus a "checked at" stamp, so the header and
  // the bar chip read the same table the body does.
  property var cardAt: ({})
  property var mediaPlayer: null
  property var inboxRows: []
  property bool inboxDnd: false
  property var vpnConnections: []
  property string vpnBackend: setting("vpnBackend", "openvpn")
  // Probed rather than stored: a setting would claim docker exists on a
  // machine where it was since uninstalled.
  property bool dockerBin: false
  property var containers: null
  property string containersError: ""
  property var repos: []
  property string reposError: ""

  readonly property bool inboxUrgent: root.inboxDnd
    || (root.inboxRows.length > 0 && root.inboxRows[0].urgency >= 2)
  readonly property bool reposDirty: (function() {
    for (var i = 0; i < root.repos.length; i++) if (root.repos[i].dirty) return true
    return false
  })()

  // The timer is the only card that keeps state rather than fetched state, so
  // it is held as plain numbers here and written to settings on every
  // transition, never on every tick.
  property string timerModeId: "focus"
  property bool timerRunning: false
  property int timerLeft: Model.timerMode("focus").seconds
  property int timerDone: 0
  property int stopwatchBase: 0
  property double stopwatchStartedAt: 0
  property double timerEndsAt: 0
  property int timerLeftAtLastPause: Model.timerMode("focus").seconds

  property var cardOrder: []
  property double nowMs: Date.now()
  property bool editingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePending: ""
  property string geocodeActive: ""

  // Keyboard cursor across the bento.
  property int focusIndex: 0
  property bool cursorActive: false

  // Dashboard / settings view + card resizing.
  property string viewMode: "dashboard"
  property bool resizeMode: false
  property var resizeLive: ({ id: "", span: { cols: 1, rows: 1 } })
  // The press point in `gridItem` coordinates. The handle itself rides on the
  // card it resizes, so measuring the drag in the handle's own frame makes the
  // card chase the cursor and the cursor chase the card -- read the delta in
  // the grid's frame, which holds still.
  property real resizePressGX: 0
  property real resizePressGY: 0
  property real resizeStartW: 0
  property real resizeStartH: 0
  // How far past a cell boundary the pointer has to travel before the span
  // commits, so a hand resting on a threshold does not flicker between sizes.
  readonly property real spanHysteresis: 0.2
  // Cards slide to their new places, but not on the first layout -- opening
  // the panel should not look like the grid is flying in.
  property bool cellsAnimate: false
  readonly property int toolbarHeight: Style.space(26)

  // Whole-plugin zoom: one scale factor drives the entire panel content
  // (cards + typography) so everything follows resizing proportionally.
  // Persisted in the widget settings as `zoom`.
  property real zoom: root.clamp(parseFloat(setting("zoom", "1")) || 1, 0.75, 1.6)
  readonly property real zoomMin: 0.75
  readonly property real zoomMax: 1.6
  // The grip rides the card's bottom edge, which moves as the zoom changes,
  // so the press point is kept in screen coordinates -- the one frame the
  // drag does not move.
  property real zoomPressY: 0
  property real zoomStartZoom: 1

  // ------------------------------------------------------------- helpers
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  // Available height for a card body: the Loader (parent) sets a fixed height,
  // so measure it instead of the body Column's own height (which depends on the
  // number of rows it shows - a circular dependency that would limit lists).
  function bodyHeight(el) {
    if (el && el.parent && el.parent.height > 0) return el.parent.height
    return el && el.height > 0 ? el.height : Style.space(120)
  }

  function cardTitle(id) {
    var card = Model.cardById(id)
    return card ? card.title : ""
  }

  function checkedAtFor(id) {
    if (id === "weather") return root.weather && root.weather.checkedAt ? root.weather.checkedAt : ""
    if (id === "market") return root.market && root.market.checkedAt ? root.market.checkedAt : ""
    if (id === "companies") return root.companies && root.companies.length > 0 && root.companies[0].checkedAt ? root.companies[0].checkedAt : ""
    if (id === "calendar") return root.calendar && root.calendar.checkedAt ? root.calendar.checkedAt : ""
    if (id === "reminders") return root.reminders && root.reminders.checkedAt ? root.reminders.checkedAt : ""
    if (id === "system") return root.systemAt
    return root.cardAt[id] || ""
  }

  function cardUrgent(id) {
    if (id === "market") return root.marketAlarming
    if (id === "companies") return root.companyDueSoon
    if (id === "reminders") return root.reminders && root.reminders.count > 0
    if (id === "inbox") return root.inboxUrgent
    if (id === "repos") return root.reposDirty
    return false
  }

  function cardComponent(id) {
    if (id === "weather") return weatherBodyComp
    if (id === "market") return marketBodyComp
    if (id === "companies") return companiesBodyComp
    if (id === "calendar") return calendarBodyComp
    if (id === "system") return systemBodyComp
    if (id === "media") return mediaBodyComp
    if (id === "timer") return timerBodyComp
    if (id === "inbox") return inboxBodyComp
    if (id === "vpn") return vpnBodyComp
    if (id === "containers") return containersBodyComp
    if (id === "repos") return reposBodyComp
    return remindersBodyComp
  }

  property Component weatherBodyComp: Component { WeatherBody {} }
  property Component marketBodyComp: Component { MarketBody {} }
  property Component companiesBodyComp: Component { CompaniesBody {} }
  property Component calendarBodyComp: Component { CalendarBody {} }
  property Component systemBodyComp: Component { SystemBody {} }
  property Component remindersBodyComp: Component { RemindersBody {} }
  property Component mediaBodyComp: Component { MediaBody {} }
  property Component timerBodyComp: Component { TimerBody {} }
  property Component inboxBodyComp: Component { InboxBody {} }
  property Component vpnBodyComp: Component { VpnBody {} }
  property Component containersBodyComp: Component { ContainersBody {} }
  property Component reposBodyComp: Component { ReposBody {} }

  function cardIndexFor(id) { return Math.max(0, root.cardOrder.indexOf(id)) }

  // One stamp table for the newer cards, so the header's "checked" line is the
  // same value the body last wrote rather than a second opinion.
  function stampCard(id, at) {
    var stamps = {}
    for (var key in root.cardAt) stamps[key] = root.cardAt[key]
    // The header prints this value as it stands, and every call site passes a
    // millisecond clock, so the formatting belongs here rather than at each of
    // them -- a raw `Date.now()` reaches the card as "1790460527794".
    stamps[id] = (typeof at === "number") ? Model.formatTimeNow() : at
    root.cardAt = stamps
  }

  // Card id -> its body Loader. The cells come and go as the order and the
  // layout change, so the audit asks this rather than walking a stale tree.
  property var loaders: ({})

  function registerLoader(id, loader) {
    var next = {}
    for (var key in root.loaders) next[key] = root.loaders[key]
    if (loader === null) delete next[id]
    else next[id] = loader
    root.loaders = next
  }

  function focusCard(index) {
    root.focusIndex = root.clamp(index, 0, Math.max(0, root.cardOrder.length - 1))
    root.cursorActive = true
  }

  function moveCursor(dx, dy) {
    var n = root.cardOrder.length
    if (n === 0) return
    var row = Math.floor(root.focusIndex / 3) + dy
    var col = (root.focusIndex % 3) + dx
    row = root.clamp(row, 0, Math.floor((n - 1) / 3))
    col = root.clamp(col, 0, 2)
    root.focusCard(row * 3 + col)
  }

  // Which fetcher a card's Enter key runs. Data, not shape, so it stays a table
  // rather than growing a branch per card.
  readonly property var cardRefresh: ({
    weather: "startWeather",
    market: "startMarket",
    companies: "startCompany",
    calendar: "startCalendar",
    system: "startSystem",
    reminders: "startReminders",
    media: "refreshMedia",
    inbox: "startInbox",
    vpn: "startVpn",
    containers: "startContainers",
    repos: "startRepos"
  })

  function refreshFocused() {
    var name = root.cardRefresh[root.cardOrder[root.focusIndex]]
    if (name && typeof root[name] === "function") root[name]()
  }

  function swapCards(srcId, dstId) {
    var idxA = root.cardOrder.indexOf(srcId)
    var idxB = root.cardOrder.indexOf(dstId)
    if (idxA < 0 || idxB < 0 || idxA === idxB) return
    var next = root.cardOrder.slice()
    next[idxA] = root.cardOrder[idxB]
    next[idxB] = root.cardOrder[idxA]
    root.setCardOrder(next)
  }

  // `cards` is both the enable set and the display order. The pre-registry
  // `layout` key is read once as a fallback so an upgrade keeps its arrangement,
  // then the resolved list is written back once and the legacy key is done.
  function loadLayout() {
    var raw = setting("cards", null)
    var next = Model.enabledCards(raw, setting("layout", null))
    if (JSON.stringify(next) === JSON.stringify(root.cardOrder)) return
    root.cardOrder = next
    if (raw === null || raw === undefined || String(raw).trim() === "")
      root.persistSettings({ cards: next })
  }

  function setCardOrder(next) {
    root.cardOrder = next
    root.persistSettings({ cards: next })
    root.computeFlow()
  }

  // ------------------------------------------------------------- bento layout
  function defaultSizes() {
    var map = {}
    for (var i = 0; i < Model.CARDS.length; i++) map[Model.CARDS[i].id] = { cols: 1, rows: 1 }
    return map
  }

  function sizeFor(id) {
    if (root.resizeLive.id === id && root.viewMode === "dashboard") return root.resizeLive.span
    var s = root.cardSizes[id]
    return s ? { cols: root.clamp(s.cols | 0, 1, 3), rows: root.clamp(s.rows | 0, 1, 2) } : { cols: 1, rows: 1 }
  }

  function loadSizes() {
    var map = root.defaultSizes()
    var raw = setting("sizes", "{}")
    var src = raw
    // The setting arrives either as the JSON string persistSizes wrote or, if
    // something edited it by hand, as an object. A value in neither shape falls
    // back to 1x1 for every card rather than throwing away the whole layout.
    if (typeof raw === "string") {
      try { src = JSON.parse(raw) || {} } catch (e) { src = {} }
    }
    if (!src || typeof src !== "object") src = {}
    for (var id in src) {
      if (!map[id]) continue
      var value = src[id]
      // Accept `[cols, rows]` as well as `{cols, rows}`: both read naturally,
      // and silently rendering everything 1x1 is a confusing way to be strict.
      var cols = Array.isArray(value) ? value[0] : (value && value.cols)
      var rows = Array.isArray(value) ? value[1] : (value && value.rows)
      map[id] = { cols: root.clamp(cols | 0, 1, 3) || 1, rows: root.clamp(rows | 0, 1, 2) || 1 }
    }
    root.cardSizes = map
    // A settings reload relays the whole grid; let it land before the cells
    // start animating, or every card slides in from wherever it used to be.
    root.cellsAnimate = false
    root.computeFlow()
    settleCells.restart()
  }

  function persistSizes() {
    var map = {}
    for (var id in root.cardSizes) map[id] = root.cardSizes[id]
    root.persistSettings({ sizes: JSON.stringify(map) })
  }

  function isFreeAt(rows, r, c, cols, height) {
    for (var ci = c; ci < c + cols; ci++)
      for (var ri = r; ri < r + height; ri++)
        if (rows[ri] && rows[ri][ci]) return false
    return true
  }

  function occupy(rows, r, c, cols, height) {
    for (var ri = r; ri < r + height; ri++) {
      if (!rows[ri]) rows[ri] = []
      for (var ci = c; ci < c + cols; ci++) rows[ri][ci] = true
    }
  }

  function computeFlow() {
    var totalCols = root.columns
    var rows = []
    var plans = []
    var ids = root.cardOrder.slice()
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i]
      var span = root.sizeFor(id)
      var placed = false
      for (var r = 0; r < 14 && !placed; r++) {
        for (var c = 0; c <= totalCols - span.cols; c++) {
          if (root.isFreeAt(rows, r, c, span.cols, span.rows)) {
            root.occupy(rows, r, c, span.cols, span.rows)
            plans.push(root.planFor(id, c, r, span))
            placed = true
            break
          }
        }
      }
      if (!placed) {
        var rr = rows.length
        plans.push(root.planFor(id, 0, rr, span))
        root.occupy(rows, rr, 0, span.cols, span.rows)
      }
    }
    var usedRows = 1
    for (var ri = 0; ri < rows.length; ri++) {
      var used = false
      for (var ci = 0; ci < totalCols; ci++) if (rows[ri][ci]) { used = true; break }
      if (used) usedRows = ri + 1
    }
    root.syncCellPlans(plans)
    root.gridHeight = usedRows * root.cellHeight + (usedRows - 1) * root.gridGap
  }

  // Fold a freshly computed layout into `cellPlans` without replacing it: rows
  // are matched by card id and their geometry is written in place, so only a
  // real change to the card set inserts, removes or moves a delegate.
  function syncCellPlans(plans) {
    for (var i = cellPlans.count - 1; i >= 0; i--) {
      var gone = true
      for (var j = 0; j < plans.length; j++) if (plans[j].id === cellPlans.get(i).cardId) { gone = false; break }
      if (gone) cellPlans.remove(i)
    }
    for (var k = 0; k < plans.length; k++) {
      var plan = plans[k]
      var at = -1
      // Everything before `k` is already settled, so the match can only be
      // at or after it.
      for (var m = k; m < cellPlans.count; m++) if (cellPlans.get(m).cardId === plan.id) { at = m; break }
      if (at === -1) {
        cellPlans.insert(k, { cardId: plan.id, cols: plan.cols, rows: plan.rows,
                              x: plan.x, y: plan.y, w: plan.w, h: plan.h })
        continue
      }
      if (at !== k) cellPlans.move(at, k, 1)
      var row = cellPlans.get(k)
      if (row.cols !== plan.cols) cellPlans.setProperty(k, "cols", plan.cols)
      if (row.rows !== plan.rows) cellPlans.setProperty(k, "rows", plan.rows)
      if (row.x !== plan.x) cellPlans.setProperty(k, "x", plan.x)
      if (row.y !== plan.y) cellPlans.setProperty(k, "y", plan.y)
      if (row.w !== plan.w) cellPlans.setProperty(k, "w", plan.w)
      if (row.h !== plan.h) cellPlans.setProperty(k, "h", plan.h)
    }
  }

  function planFor(id, col, row, span) {
    return {
      id: id, cols: span.cols, rows: span.rows,
      x: col * (root.cellWidth + root.gridGap),
      y: row * (root.cellHeight + root.gridGap),
      w: span.cols * root.cellWidth + (span.cols - 1) * root.gridGap,
      h: span.rows * root.cellHeight + (span.rows - 1) * root.gridGap
    }
  }

  function cellForId(id) {
    for (var i = 0; i < cellPlans.count; i++) {
      var row = cellPlans.get(i)
      if (row.cardId === id) return row
    }
    return null
  }

  function beginResize(id) {
    var span = root.sizeFor(id)
    root.resizeLive = { id: id, span: span }
  }

  // Snap a fractional span to whole cells, but make it cost `spanHysteresis`
  // of a cell to leave the span we are already on.
  function spanStep(want, current, lo, hi) {
    var next = root.clamp(Math.round(want), lo, hi)
    if (next !== current && Math.abs(want - current) < 0.5 + root.spanHysteresis) return current
    return next
  }

  // `pxW`/`pxH` are the card size the pointer is asking for, in grid units.
  // The grid lives under `zoomHost`, which carries the scale, so those pixels
  // already match `cellWidth` -- multiplying by the zoom here would count it
  // twice and make the drag over- or under-sensitive at every zoom stop.
  function updateResize(id, pxW, pxH) {
    if (root.resizeLive.id !== id) return
    var wantCols = (pxW + root.gridGap) / (root.cellWidth + root.gridGap)
    var wantRows = (pxH + root.gridGap) / (root.cellHeight + root.gridGap)
    var span = root.resizeLive.span
    var cols = root.spanStep(wantCols, span.cols, 1, 3)
    var rows = root.spanStep(wantRows, span.rows, 1, 2)
    if (cols === span.cols && rows === span.rows) return
    root.resizeLive = { id: id, span: { cols: cols, rows: rows } }
    // Reflow while the drag is live so the neighbours slide out of the way
    // instead of being overlapped and then snapped on release.
    root.computeFlow()
  }

  function endResize(id) {
    if (root.resizeLive.id !== id) return
    root.cardSizes[id] = { cols: root.resizeLive.span.cols, rows: root.resizeLive.span.rows }
    root.resizeLive = { id: "", span: { cols: 1, rows: 1 } }
    root.computeFlow()
    root.persistSizes()
  }

  function toggleResizeMode() {
    root.resizeMode = !root.resizeMode
    if (!root.resizeMode && root.resizeLive.id !== "") root.endResize(root.resizeLive.id)
  }

  function loadZoom() {
    var z = parseFloat(setting("zoom", "1"))
    root.zoom = root.clamp(isNaN(z) ? 1 : z, root.zoomMin, root.zoomMax)
  }

  function beginPanelZoom(my) {
    root.zoomPressY = my
    root.zoomStartZoom = root.zoom
  }

  // The vertical drag alone drives the zoom, at exactly the rate the grip
  // moves: the card hangs from a fixed top edge, so its bottom -- and the grip
  // on it -- travels one `zoomHost.height` per zoom unit. 454px down is +1.00,
  // and the grip stays under the pointer for the whole drag.
  //
  // The horizontal drag is deliberately ignored. The card is pinned to the
  // right edge of the screen and grows leftwards, so its right edge cannot
  // follow the pointer; feeding `mx` in only adds zoom that the grip has to
  // express downwards, and the corner then runs away from the cursor (a 150px
  // diagonal drag overshot by 122px). The old 0.005/px gain on `dx + dy` had
  // both faults at once, and crossed the whole 0.75..1.6 range in 85px --
  // which is how the zoom ended up parked on a limit.
  function updatePanelZoom(my) {
    var baseH = zoomHost.height
    if (baseH <= 0) return
    root.zoom = root.clamp(root.zoomStartZoom + (my - root.zoomPressY) / baseH,
      root.zoomMin, root.zoomMax)
  }

  function endPanelZoom() {
    root.persistSettings({ zoom: root.zoom })
  }

  // ------------------------------------------------------------- settings view
  function toggleSettingsView() {
    if (root.viewMode !== "dashboard") {
      root.viewMode = "dashboard"
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      root.populateSettingsView()
      root.viewMode = "settings"
      Qt.callLater(function() { townField.forceActiveFocus() })
    }
  }

  // ------------------------------------------------------------ card picker
  // Enabling, disabling and reordering all land in the same `cards` list, so
  // the DASHBOARD group in the gear view is a view of that list rather than a
  // second source of truth.

  // The cards still off the dashboard, in registry order: the AVAILABLE chips.
  readonly property var manageAvailableRows: (function() {
    var out = []
    var all = Model.knownIds()
    for (var j = 0; j < all.length; j++) {
      if (root.cardOrder.indexOf(all[j]) === -1) out.push(all[j])
    }
    return out
  })()

  readonly property var manageRows: (function() {
    var rows = []
    var order = root.cardOrder
    for (var i = 0; i < order.length; i++) rows.push({ id: order[i], on: true, at: i })
    var all = Model.knownIds()
    for (var j = 0; j < all.length; j++) {
      if (order.indexOf(all[j]) === -1) rows.push({ id: all[j], on: false, at: -1 })
    }
    return rows
  })()

  readonly property var manageEnabledCount: root.cardOrder.length
  readonly property var manageAvailableCount: root.manageRows.length - root.manageEnabledCount

  function manageMissing(id) {
    return Model.missingNeeds(id, {
      weatherTown: root.weatherTown,
      calendarIcalUrl: root.calendarUrl,
      companiesHouseNumber: root.companyNumber,
      repoPaths: root.repoPathsRaw,
      // Without these two the picker refuses to ever turn vpn or containers
      // on, however well configured they are.
      vpnBackend: root.vpnBackend,
      dockerBin: root.dockerBin
    })
  }

  function manageToggle(id) {
    if (root.manageRows.length === 0) return
    var missing = root.manageMissing(id)
    if (missing !== "" && root.cardOrder.indexOf(id) === -1) return
    var next = Model.toggleCard(root.cardOrder, id)
    if (JSON.stringify(next) === JSON.stringify(root.cardOrder)) return
    root.setCardOrder(next)
  }

  function manageMove(id, delta) {
    var next = Model.moveCard(root.cardOrder, id, delta)
    if (JSON.stringify(next) === JSON.stringify(root.cardOrder)) return
    root.setCardOrder(next)
  }

  // The drag-and-drop half of manageMove: a chip dropped on another chip lands
  // at that chip's index instead of stepping one place.
  function manageReorder(id, toIndex) {
    var next = Model.reorderCard(root.cardOrder, id, toIndex)
    if (JSON.stringify(next) === JSON.stringify(root.cardOrder)) return
    root.setCardOrder(next)
  }

  function populateSettingsView() {
    townField.text = setting("weatherTown", "")
    symbolsField.text = setting("symbols", Model.DEFAULT_SYMBOLS)
    companyField.text = setting("companiesHouseNumber", "")
    icalField.text = setting("calendarIcalUrl", "")
    refreshField.text = String(root.refreshIntervalSec)
    root.readBarLocation()
  }

  // ------------------------------------------------------------- bar face
  // The bar face is BarWidget.qml; this panel only owns the editing UI for it
  // and the shell.json keys behind it. Item choice and order persist through
  // persistSettings; the *position* of the slot in the bar is layout state, so
  // it goes through the bar's own move verb.
  readonly property var barSections: ["left", "center", "right"]
  readonly property var barItems: Model.parseBarItems(setting("barItems", null))
  readonly property var barSymbols: Model.parseBarSymbols(
    setting("barSymbols", ""), root.settingSymbols, 2)
  readonly property var barSymbolPool: Model.splitList(root.settingSymbols)
  property string barSection: ""
  property int barIndex: 0
  property string barMoveNote: ""
  readonly property bool barLocated: root.barSection !== ""
  readonly property int barSlotCount: {
    var config = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    var entries = config && root.barSection ? config[root.barSection] : null
    return Array.isArray(entries) ? entries.length : 0
  }

  function barEntryId(entry) {
    if (typeof entry === "string") return entry
    if (entry && typeof entry === "object" && "id" in entry) return String(entry.id)
    return ""
  }

  // Re-read on demand rather than caching: layoutConfig is a snapshot the bar
  // republishes, and a stale one would show the wrong slot.
  function readBarLocation() {
    var config = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    root.barSection = ""
    root.barIndex = 0
    if (!config) return
    for (var s = 0; s < root.barSections.length; s++) {
      var entries = config[root.barSections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (root.barEntryId(entries[i]) !== root.moduleName) continue
        root.barSection = root.barSections[s]
        root.barIndex = i
        return
      }
    }
  }

  // `bar-widget` plugins have no API for writing the layout, only for reading
  // it, so placement is a `omarchy bar move`. The registry finds the entry
  // itself and takes the target index after the removal, so no from-* is
  // needed and a stale index cannot move the wrong widget.
  function moveBarWidget(section, index) {
    if (!root.bar || typeof root.bar.run !== "function") return
    if (root.barSections.indexOf(section) === -1) return
    var target = Math.max(0, parseInt(index, 10) || 0)
    root.bar.run("omarchy bar move " + Util.shellQuote(root.moduleName)
      + " --section " + Util.shellQuote(section)
      + " --index " + target)
    root.barSection = section
    root.barIndex = target
    root.barMoveNote = "moved to " + section + " " + (target + 1)
    barMoveTimer.restart()
  }

  function nudgeBarSlot(delta) {
    if (!root.barLocated) return
    root.moveBarWidget(root.barSection, root.barIndex + delta)
  }

  function toggleBarItem(id) {
    root.persistSettings({ barItems: Model.toggleBarItem(root.barItems, id) })
  }

  function moveBarItem(id, delta) {
    root.persistSettings({ barItems: Model.moveBarItem(root.barItems, id, delta) })
  }

  function reorderBarItem(id, toIndex) {
    root.persistSettings({ barItems: Model.reorderBarItem(root.barItems, id, toIndex) })
  }

  function toggleBarSymbol(symbol) {
    var next = root.barSymbols.slice()
    var at = next.indexOf(symbol)
    if (at !== -1) {
      next.splice(at, 1)
    } else {
      if (next.length >= Model.MAX_BAR_SYMBOLS) return
      next.push(symbol)
    }
    root.persistSettings({ barSymbols: next })
  }

  function saveSettings() {
    var next = {
      weatherTown: townField.text.trim(),
      symbols: symbolsField.text.trim(),
      companiesHouseNumber: companyField.text.trim(),
      calendarIcalUrl: icalField.text.trim(),
      refreshIntervalSec: root.clamp(parseInt(refreshField.text, 10) || 300, 60, 7200)
    }
    if (next.weatherTown !== root.weatherTown) {
      next.weatherCoords = ""
      root.weatherCoords = ""
    }
    root.weatherTown = next.weatherTown
    root.settingSymbols = next.symbols
    root.companyNumber = next.companiesHouseNumber
    root.calendarUrl = next.calendarIcalUrl
    root.refreshIntervalSec = next.refreshIntervalSec
    root.viewMode = "dashboard"
    root.persistSettings(next)
    root.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Written through the bar's shell.json entry so card order and toggles
  // survive a restart; without a writable entry it stays a session preference.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A fetch that read nothing back is a failure, not an answer: assigning the
  // empty parse would wipe a card the user could still read a minute ago. The
  // test is the raw output, not the parsed result -- "no reminders" and "no VPN
  // profiles" are real answers and must be shown as such.
  function keepOnEmpty(id, raw, value) {
    if (raw === null || raw === undefined || String(raw).trim() === "") {
      if (root.failedFetches.indexOf(id) === -1) root.failedFetches.push(id)
      return
    }
    root.failedFetches = root.failedFetches.filter(function(f) { return f !== id })
    root.setCardData(id, value)
  }

  function setCardData(id, value) {
    if (id === "calendar") root.calendar = value
    else if (id === "reminders") root.reminders = value
    else if (id === "inbox") root.inboxRows = value
    else if (id === "vpn") root.vpnConnections = value
  }

  // ------------------------------------------------------------- lifecycle
  function open() {
    root.controller.show()
    root.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  // ------------------------------------------------------------- refresh
  // Only what the dashboard actually shows, and only the cards with something
  // to fetch. The per-card pollers below pick up from here once a card is live.
  function refresh() {
    if (root.cardLive("weather") && root.weatherTown !== "") startWeather()
    if (root.cardLive("market") && root.settingSymbols.trim() !== "") startMarket()
    if (root.cardLive("companies") && root.companyNumbers.length > 0) startCompany()
    if (root.cardLive("calendar") && root.calendarUrl !== "") startCalendar()
    if (root.cardLive("system")) startSystem()
    if (root.cardLive("reminders")) startReminders()
    if (root.cardLive("media")) refreshMedia()
    if (root.cardLive("inbox")) startInbox()
    if (root.cardLive("vpn")) startVpn()
    if (root.cardLive("containers")) startContainers()
    if (root.cardLive("repos")) startRepos()
  }

  function startWeather() {
    if (root.weatherTown === "") { root.weather = ({}); return }
    if (root.weatherCoords !== "") { fetchCurrentWeather(); return }
    var url = "https://geocoding-api.open-meteo.com/v1/search?name="
      + encodeURIComponent(root.weatherTown) + "&count=1&language=en&format=json"
    geocodeProc.command = ["curl", "-fsS", "--max-time", "6", url]
    geocodeProc.running = true
  }

  function fetchCurrentWeather() {
    var parts = String(root.weatherCoords).split(",")
    var lat = parseFloat(parts[0])
    var lon = parseFloat(parts[1])
    if (isNaN(lat) || isNaN(lon)) return
    var url = "https://api.open-meteo.com/v1/forecast?latitude=" + lat + "&longitude=" + lon
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=4&timezone=auto"
    weatherProc.command = ["curl", "-fsS", "--max-time", "6", url]
    weatherProc.running = true
  }

  function startMarket() {
    var symbols = root.settingSymbols.split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
    if (symbols.length === 0) { root.market = ({ symbols: [], checkedAt: "" }); return }
    var url = "https://query1.finance.yahoo.com/v8/finance/spark?symbols="
      + symbols.join(",") + "&range=1d&interval=1d"
    yahooProc.command = ["curl", "-fsS", "--max-time", "8", "-A", "Mozilla/5.0", url]
    yahooProc.running = true
  }

  function togglePreset(presetKey) {
    var next = Model.toggleSymbolsPreset(root.settingSymbols, presetKey)
    root.settingSymbols = next
    root.persistSettings({ symbols: next })
    root.startMarket()
  }

  function startCompany() {
    var numbers = root.companyNumbers
    if (numbers.length === 0) { root.companies = []; return }
    var steps = []
    for (var i = 0; i < numbers.length; i++) {
      steps.push("printf '@@CH@NEXT@@\\n'; curl -fsS --max-time 8 -A 'Mozilla/5.0' 'http://data.companieshouse.gov.uk/doc/company/"
        + numbers[i] + ".json'")
    }
    chProc.command = ["bash", "-lc", steps.join("; ")]
    chProc.running = true
  }

  function startCalendar() {
    if (root.calendarUrl.trim() === "") { root.calendar = ({ events: [], checkedAt: "" }); return }
    calProc.command = ["curl", "-fsS", "--max-time", "10", root.calendarUrl.trim()]
    calProc.running = true
  }

  function startSystem() {
    if (sysProc.running) return
    sysProc.command = ["bash", "-lc",
      "omarchy-system-stats --bar-widget"
      + "; df -h / | tail -n 1 | awk -v OFS='\\t' '{print \"disk\\t\"$2\"\\t\"$3\"\\t\"$5}'"
      + "; printf 'temp\\t%s\\n' \"$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || printf '0')\""]
    sysProc.running = true
  }

  function startReminders() {
    if (reminderProc.running) return
    reminderProc.running = true
  }

  // ------------------------------------------------------------- the six newer cards
  // Everything below follows the same two rules: nothing polls for a card that
  // is not on the dashboard, and nothing polls at all while the panel is shut.
  function cardLive(id) {
    return root.opened && root.cardOrder.indexOf(id) !== -1
  }

  readonly property var mediaService: root.bar && root.bar.shell
    ? root.bar.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var notificationService: root.bar && root.bar.shell
    ? root.bar.shell.firstPartyServiceFor("omarchy.notifications") : null

  // --- media
  // Nothing to fetch: Mpris is already a service, so the card is a view of it.
  // Refresh only re-snapshots, which is what the Enter key means here.
  function refreshMedia() {
    root.snapshotMedia()
  }

  function snapshotMedia() {
    var service = root.mediaService
    var player = service ? service.activePlayer : null
    if (!player) { root.mediaPlayer = null; return }
    var title = String(player.trackTitle || "")
    var artist = String(player.trackArtist || "")
    if (title === "" && artist === "") { root.mediaPlayer = null; return }
    root.mediaPlayer = {
      title: title,
      artist: artist,
      album: String(player.trackAlbum || ""),
      playing: player.isPlaying === true,
      position: Number(player.position || 0) / 1000000,
      length: Number(player.length || 0) / 1000000,
      canNext: player.canGoNext === true,
      canPrev: player.canGoPrevious === true,
      canToggle: player.canPlay === true || player.canPause === true,
      key: service.playerKey(player),
      label: service.labelFor(player)
    }
    root.stampCard("media", root.nowMs)
  }

  function mediaAction(action) {
    var service = root.mediaService
    if (!service || !root.mediaPlayer) return
    // targetKey keeps the action on the player this card is showing, so a
    // second player joining mid-song cannot steal the button.
    service.runAction(action, false, root.mediaPlayer.key)
    root.snapshotMedia()
  }

  function cycleMediaPlayer() {
    var service = root.mediaService
    if (!service || !root.mediaPlayer) return
    var players = service.sourcePlayers
    if (!players || players.length < 2) return
    var index = 0
    for (var i = 0; i < players.length; i++)
      if (service.playerKey(players[i]) === root.mediaPlayer.key) index = i
    var next = players[(index + 1) % players.length]
    service.runAction("play", false, service.playerKey(next))
    Qt.callLater(root.snapshotMedia)
  }

  // --- inbox
  function inboxDir() {
    var service = root.notificationService
    if (service && String(service.historyDir || "") !== "") return String(service.historyDir)
    return Quickshell.env("XDG_STATE_HOME") + "/omarchy/notifications/history/"
  }

  function startInbox() {
    if (inboxProc.running) return
    root.inboxDnd = root.notificationService ? root.notificationService.doNotDisturb === true : false
    inboxProc.command = ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.inboxDir()]
    inboxProc.running = true
  }

  function toggleDnd() {
    var service = root.notificationService
    if (!service) return
    service.setDoNotDisturb(!service.doNotDisturb)
    root.inboxDnd = service.doNotDisturb === true
  }

  function clearInbox() {
    var service = root.notificationService
    if (!service) return
    service.clearHistory()
    root.inboxRows = []
    root.stampCard("inbox", root.nowMs)
  }

  // --- vpn
  // One call, both backends: nmcli for NetworkManager profiles, a systemd probe
  // for nordvpnd, split on a marker so the parser can tell them apart.
  function startVpn() {
    if (vpnProc.running) return
    var script = "if command -v nmcli >/dev/null 2>&1; then"
      + " printf 'openvpn\\n';"
      + " nmcli -t -f NAME,TYPE,STATE con show"
      + " | sed -n 's/^\\(.*\\)\\:vpn\\:\\(.*\\)$/\\1|openvpn|\\2/p'; fi"
      + "; if systemctl --user is-active --quiet nordvpnd 2>/dev/null || command -v nordvpn >/dev/null 2>&1; then"
      + " printf '@@VPN@@\\nnordvpn\\n'; fi"
    vpnProc.command = ["bash", "-lc", script]
    vpnProc.running = true
  }

  function toggleVpn(conn) {
    if (!conn || vpnActionProc.running) return
    var script
    if (conn.kind === "nordvpn")
      script = "systemctl --user restart nordvpnd"
    else
      script = (conn.active ? "down" : "up") + " id " + Util.shellQuote(conn.name)
    vpnActionProc.command = ["bash", "-lc", script]
    vpnActionProc.running = true
    // Bring the list back promptly, then let the poll take over.
    Qt.callLater(function() { Qt.callLater(root.startVpn) })
  }

  // --- containers
  function startContainers() {
    if (containersProc.running) return
    containersProc.command = ["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"]
    containersProc.running = true
  }

  // --- repos
  // Serial in one shell rather than one process per repo: the repos check out
  // at different times, so nothing spikes, and one Process covers any count.
  function startRepos() {
    if (reposProc.running) return
    var paths = root.repoPaths
    if (paths.length === 0) { root.repos = []; return }
    var steps = []
    for (var i = 0; i < paths.length; i++)
      steps.push("printf '@@REPO@@%s\\n' " + Util.shellQuote(paths[i])
        + "; git -C " + Util.shellQuote(paths[i]) + " status --porcelain=v2 --branch 2>&1")
    reposProc.command = ["bash", "-lc", steps.join("; ")]
    reposProc.running = true
  }

  // --- timer
  readonly property int timerTotal: Model.timerMode(root.timerModeId).seconds
  readonly property int timerSessions: Model.timerMode(root.timerModeId).sessions
  readonly property int timerSeconds: root.timerModeId === "stopwatch"
    ? root.stopwatchBase + (root.timerRunning ? Math.floor((root.nowMs - root.stopwatchStartedAt) / 1000) : 0)
    : root.timerLeft
  readonly property real timerProgress: root.timerTotal > 0
    ? Math.max(0, Math.min(1, 1 - root.timerLeft / root.timerTotal)) : 0

  function loadTimer() {
    var state = Model.parseTimerState(setting("timerState", ""))
    root.timerModeId = state.mode
    root.timerRunning = state.running
    root.timerLeft = state.remaining
    root.timerDone = state.done
    root.stopwatchBase = state.elapsed
    root.stopwatchStartedAt = Date.now()
    root.timerEndsAt = state.running ? Date.now() + state.remaining * 1000 : 0
    root.timerLeftAtLastPause = state.remaining
  }

  // Written on transitions only: the deadline makes a stale value still correct.
  function persistTimer() {
    root.persistSettings({ timerState: JSON.stringify({
      mode: root.timerModeId,
      running: root.timerRunning,
      remaining: root.timerModeId === "stopwatch" ? root.timerLeftAtLastPause : root.timerLeft,
      endsAt: root.timerEndsAt,
      elapsed: root.stopwatchBase,
      done: root.timerDone
    }) })
  }

  function toggleTimer() {
    if (root.timerModeId === "stopwatch") {
      root.timerRunning = !root.timerRunning
      if (root.timerRunning) root.stopwatchStartedAt = Date.now()
      root.persistTimer()
      return
    }
    if (root.timerRunning) {
      root.timerRunning = false
      root.timerEndsAt = 0
      root.timerLeftAtLastPause = root.timerLeft
    } else {
      if (root.timerLeft <= 0) root.timerLeft = root.timerTotal
      root.timerRunning = true
      root.timerEndsAt = Date.now() + root.timerLeft * 1000
    }
    root.persistTimer()
  }

  function resetTimer() {
    if (root.timerModeId === "stopwatch") {
      root.timerRunning = false
      root.stopwatchBase = 0
      root.stopwatchStartedAt = Date.now()
      root.timerLeftAtLastPause = 0
    } else {
      root.timerRunning = false
      root.timerEndsAt = 0
      root.timerLeft = root.timerTotal
      root.timerLeftAtLastPause = root.timerTotal
    }
    root.persistTimer()
  }

  function cycleTimerMode() {
    var modes = Model.TIMER_MODES
    var index = 0
    for (var i = 0; i < modes.length; i++) if (modes[i].id === root.timerModeId) index = i
    var next = modes[(index + 1) % modes.length]
    root.timerModeId = next.id
    root.timerRunning = false
    root.timerEndsAt = 0
    root.timerLeft = next.seconds
    root.timerLeftAtLastPause = next.seconds
    root.persistTimer()
  }

  function timerTick() {
    if (!root.timerRunning) return
    if (root.timerModeId === "stopwatch") { root.nowMs = Date.now(); return }
    var left = Math.max(0, Math.ceil((root.timerEndsAt - Date.now()) / 1000))
    root.timerLeft = left
    if (left <= 0) root.completeTimer()
  }

  // A finished session is announced, not silent: the count moves on, the card
  // drops to the other mode ready to start, and the state survives a restart.
  function completeTimer() {
    root.timerRunning = false
    root.timerEndsAt = 0
    root.timerDone = root.timerDone + 1
    var wasFocus = root.timerModeId === "focus"
    var next = Model.timerMode(wasFocus ? "break" : "focus")
    root.timerModeId = next.id
    root.timerLeft = next.seconds
    root.timerLeftAtLastPause = next.seconds
    root.persistTimer()
    chimeProc.command = ["bash", "-lc",
      "pw-play " + Util.shellQuote("/usr/share/sounds/freedesktop/stereo/complete.oga") + " 2>/dev/null || true"]
    chimeProc.running = true
    notifyProc.command = ["bash", "-lc",
      "command -v notify-send >/dev/null 2>&1 && notify-send -a 'Control Station' "
      + Util.shellQuote(wasFocus ? "Focus session done" : "Break over") + " || true"]
    notifyProc.running = true
  }

  // ------------------------------------------------------------- weather editing
  function startEditingLocation() {
    root.editingLocation = true
    root.locationSuggestions = []
    root.suggestionIndex = 0
    Qt.callLater(function() {
      if (!locField) return
      locField.text = root.weatherTown
      locField.selectAll()
      locField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    root.editingLocation = false
    root.locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function requestGeocode() {
    var query = locField ? locField.text.trim() : ""
    if (query.length < 2) { root.locationSuggestions = []; return }
    root.geocodePending = query
    if (!geocodeProc.running) startPickerGeocode()
  }

  function startPickerGeocode() {
    root.geocodeActive = root.geocodePending
    geocodeProc.command = ["curl", "-fsS", "--max-time", "6",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(root.geocodeActive)
      + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function pickSuggestion(s) {
    if (!s) return
    root.editingLocation = false
    root.locationSuggestions = []
    root.weatherTown = s.name
    root.weatherCoords = s.latitude + "," + s.longitude
    root.persistSettings({ weatherTown: s.name, weatherCoords: root.weatherCoords })
    root.fetchCurrentWeather()
  }

  // ------------------------------------------------------------- formatting
  function formatPrice(v) {
    var n = Number(v)
    return isFinite(n) ? n.toFixed(2) : "\u2014"
  }

  function formatPct(v) {
    var n = Number(v)
    if (!isFinite(n)) return ""
    return (n > 0 ? "+" : "") + n.toFixed(1) + "%"
  }

  function reminderCountdown(rem) {
    var at = Number(rem && rem.at || 0)
    var seconds = 0
    if (at > 0) seconds = Math.round(at - root.nowMs / 1000)
    else seconds = Number(rem && rem.remainingSeconds || 0)
    return seconds > 0 ? Model.formatCountdown(seconds) : "now"
  }

  function reminderLabel(rem) {
    return String((rem && (rem.label || rem.message)) || "").trim()
  }

  function reminderAtText(rem) {
    return root.reminderLabel(rem) === "" ? "reminder" : root.reminderLabel(rem)
  }

  // ------------------------------------------------------------- derived
  readonly property bool marketAlarming: (function() {
    var arr = root.market && root.market.symbols || []
    for (var i = 0; i < arr.length; i++) if (arr[i] && arr[i].isDown) return true
    return false
  })()
  readonly property bool companyDueSoon: (function() {
    var cs = root.companies || []
    for (var i = 0; i < cs.length; i++)
      if (cs[i] && (cs[i].accountsUrgent === true || cs[i].returnsUrgent === true)) return true
    return false
  })()
  readonly property bool alarming: root.marketAlarming || root.companyDueSoon || (root.reminders ? root.reminders.count > 0 : false)

  readonly property int columns: 3
  readonly property int cellWidth: Style.space(170)
  readonly property int cellHeight: Style.space(204)
  readonly property int gridGap: Style.space(10)
  readonly property int gridWidth: columns * cellWidth + (columns - 1) * gridGap

  // Resizable bento: span of every card (in grid units) + auto-flow layout.
  property var cardSizes: ({})
  // The laid-out cells, one row per card. A Repeater rebuilds every delegate
  // when its model is *reassigned*, so this is a ListModel that `computeFlow`
  // edits in place -- otherwise a resize, a reorder or a swap would destroy
  // and recreate all twelve cards, their Loaders and their bodies.
  ListModel { id: cellPlans }
  property int gridHeight: 2 * cellHeight + gridGap
  readonly property int panelContentHeight: root.toolbarHeight + Style.space(10) + root.gridHeight

  // ------------------------------------------------------------- timing
  // The Behaviours on the cells stay off until the first layout has settled.
  Timer {
    id: settleCells
    interval: 160
    repeat: false
    onTriggered: root.cellsAnimate = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  // The move is a detached command, so the numbers on screen are optimistic
  // until the bar republishes its layout; settle back onto the real slot.
  Timer {
    id: barMoveTimer
    interval: 800
    onTriggered: {
      root.readBarLocation()
      root.barMoveNote = ""
    }
  }

  onSettingsChanged: { root.loadLayout(); root.loadSizes(); root.loadZoom(); root.loadTimer() }
  Component.onCompleted: { root.loadLayout(); root.loadSizes(); root.loadZoom(); root.loadTimer() }

  // ============================================================= backend
  // Long enough for a frame, short enough that a shell script does not notice.
  Timer {
    id: measureTimer
    interval: 700
    repeat: false
    onTriggered: {
      if (!root.measurePending) return
      // The shell dismisses a popout on the next click outside, so an open
      // panel is not a given 700ms later. Retrying beats handing back a
      // snapshot of a panel that was already gone.
      if (!root.opened && root.measureTries < 6) {
        root.measureTries++
        root.open()
        measureTimer.restart()
        return
      }
      root.measurePending = false
      root.measureJson = auditCaller.buildAudit()
    }
  }

  Process {
    id: dockerProbe
    command: ["sh", "-lc", "command -v docker >/dev/null 2>&1 && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dockerBin = String(text || "").trim() === "yes"
    }
    running: true
  }
  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var suggestions = Model.parseGeocodingResults(text)
        if (root.editingLocation) {
          root.locationSuggestions = suggestions
          root.suggestionIndex = 0
          if (root.geocodePending !== root.geocodeActive) Qt.callLater(root.startPickerGeocode)
        } else if (suggestions.length > 0) {
          var best = suggestions[0]
          root.weatherCoords = best.latitude + "," + best.longitude
          root.persistSettings({ weatherCoords: root.weatherCoords })
          root.fetchCurrentWeather()
        }
      }
    }
  }

  Process {
    id: weatherProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseWeatherCurrent(text, root.weatherTown)
        if (parsed.weather) root.weather = parsed.weather
      }
    }
  }

  Process {
    id: yahooProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var orderList = root.settingSymbols.split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
        var parsed = Model.parseYahooSpark(text, orderList)
        if (parsed.symbols.length > 0) root.market = parsed
      }
    }
  }

  Process {
    id: chProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseCompaniesHouseBatch(text)
        if (parsed.companies.length > 0) root.companies = parsed.companies
      }
    }
  }

  Process {
    id: calProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.keepOnEmpty("calendar", text, Model.parseICal(text))
      }
    }
  }

  Process {
    id: sysProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSystemOutput(text)
        if (parsed.cpuPercent >= 0 || parsed.tempCelsius >= 0) {
          root.system = parsed
          root.systemAt = Model.formatTimeNow()
        }
      }
    }
  }

  Process {
    id: reminderProc
    command: ["omarchy-reminder", "show", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.keepOnEmpty("reminders", text, Model.parseRemindersJson(text))
      }
    }
  }

  Process {
    id: inboxProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.keepOnEmpty("inbox", text, Model.parseInboxHistory(text, 5))
        root.stampCard("inbox", Date.now())
      }
    }
  }

  Process {
    id: vpnProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.keepOnEmpty("vpn", text, Model.parseVpnListings(text).connections)
        root.stampCard("vpn", Date.now())
      }
    }
  }

  // Fire and forget: the list comes back from the next probe, so this one only
  // reports the command that ran.
  Process {
    id: vpnActionProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: containersProc
    property string lastError: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.containersError = ""
        root.containers = Model.parseDockerPs(text)
        root.stampCard("containers", Date.now())
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: containersProc.lastError = text
    }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      // No daemon, no permission, docker absent: the card says so instead of
      // pretending there are zero containers.
      root.containers = null
      root.containersError = Model.dockerErrorText(containersProc.lastError, exitCode)
      root.stampCard("containers", Date.now())
    }
  }

  Process {
    id: reposProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.repos = Model.parseRepoBatch(text)
        root.reposError = ""
        root.stampCard("repos", Date.now())
      }
    }
  }

  Process {
    id: chimeProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: notifyProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // The poll cadences are per card and only run when the card is up: a slow
  // steady beat, a fast one while something is in motion.
  Timer {
    id: mediaPoll
    interval: 1000
    running: root.mediaPlayer !== null && root.mediaPlayer.playing && root.cardLive("media")
    repeat: true
    onTriggered: root.snapshotMedia()
  }

  // Mpris is a live service, so the card subscribes instead of polling: a track
  // change lands here even while paused, which a 1s timer would miss.
  Connections {
    target: root.mediaService ? root.mediaService.activePlayer : null
    ignoreUnknownSignals: true
    function onTrackTitleChanged() { if (root.cardLive("media")) root.snapshotMedia() }
    function onTrackArtistChanged() { if (root.cardLive("media")) root.snapshotMedia() }
    function onIsPlayingChanged() { if (root.cardLive("media")) root.snapshotMedia() }
  }

  Timer {
    id: timerTickTimer
    interval: 1000
    running: root.timerRunning && root.cardLive("timer")
    repeat: true
    onTriggered: root.timerTick()
  }

  Timer {
    id: inboxPoll
    interval: 30000
    running: root.cardLive("inbox")
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startInbox()
  }

  Timer {
    id: vpnPoll
    interval: root.vpnSettling ? 5000 : 30000
    running: root.cardLive("vpn")
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startVpn()
  }

  Timer {
    id: containersPoll
    interval: root.containersSettling ? 10000 : 60000
    running: root.cardLive("containers")
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startContainers()
  }

  Timer {
    id: reposPoll
    interval: 60000
    running: root.cardLive("repos")
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startRepos()
  }

  // A container mid-transition (restarting, pausing, dying) is worth a faster
  // look; a healthy running one settles back to the slow beat.
  readonly property bool containersSettling: root.containers && root.containers.rows.some(function(row) {
    var state = String(row.state || "")
    return state.indexOf("restart") !== -1 || state.indexOf("paus") !== -1
      || state.indexOf("dead") !== -1 || state.indexOf("remov") !== -1
  })
  readonly property bool vpnSettling: vpnActionProc.running
    || root.vpnConnections.some(function(c) { return c && c.activating === true })

  IpcHandler {
    id: auditCaller
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function measure(): string {
      root.measureJson = ""
      root.measurePending = true
      root.measureTries = 0
      root.open()
      measureTimer.restart()
      return "measuring"
    }

    // Geometry audit: the honest way to check a card fits. Every Text reports
    // whether it outgrew its box, and every card reports the worst overflow of
    // its subtree, so clipping and eliding are numbers instead of a squint.
    function audit(): string {
      if (root.measureJson !== "") return root.measureJson
      return buildAudit()
    }

    function buildAudit(): string {
      var cards = []

      function hex(color) {
        var c = color || {}
        function part(v) { return ("0" + Math.round((v || 0) * 255).toString(16)).slice(-2) }
        return "#" + part(c.r) + part(c.g) + part(c.b)
      }

      function isText(item) {
        return item instanceof Text || (item.font !== undefined && item.implicitWidth !== undefined
          && item.elide !== undefined)
      }

      function walk(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
          var kid = kids[i]
          if (kid.visible === false) continue
          // implicitWidth only means "too wide" for a single-line text. A
          // wrapping paragraph is *supposed* to have an implicitWidth wider
          // than its box, and an elided one is supposed to be clipped, so
          // flagging either would be a false positive on every card.
          var wraps = kid.wrapMode !== undefined && kid.wrapMode !== Text.NoWrap
          if (isText(kid) && !wraps && kid.elide === Text.ElideNone && kid.implicitWidth > kid.width + 1)
            out.push({ kind: "text-overflow", text: String(kid.text).substring(0, 48),
                       over: Math.round(kid.implicitWidth - kid.width),
                       px: Math.round(kid.font.pixelSize) })
          walk(kid, out)
        }
      }

      // The lowest bottom edge in the subtree: what a clipped cell would hide.
      function depth(item) {
        var acc = 0
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
          var kid = kids[i]
          if (kid.visible === false) continue
          var bottom = kid.y + kid.height
          if (kid.children && kid.children.length > 0) {
            var nested = kid.y + depth(kid)
            if (nested > bottom) bottom = nested
          }
          if (bottom > acc) acc = bottom
        }
        return acc
      }

      // With no cards there is nothing in `cards` to measure, and the empty
      // state is the whole panel -- so measure it instead of reporting nothing.
      if (root.cardOrder.length === 0 && emptyDashboard) {
        var emptyIssues = []
        walk(emptyDashboard, emptyIssues)
        if (emptyDashboard.visible === false) emptyIssues = []
        cards.push({ card: "(empty state)", loaded: true, used: Math.round(depth(emptyDashboard)),
                     issues: emptyIssues })
      }

      for (var c = 0; c < root.cardOrder.length; c++) {
        var id = root.cardOrder[c]
        var loader = root.loaders[id]
        if (!loader || !loader.item) { cards.push({ card: id, loaded: false }); continue }
        var issues = []
        walk(loader.item, issues)
        var used = Math.round(depth(loader.item))
        var box = Math.round(loader.height)
        if (used > box + 1) issues.push({ kind: "vertical-overflow", over: used - box, used: used, box: box })
        cards.push({
          card: id,
          loaded: true,
          cell: Math.round(loader.width) + "x" + box,
          used: used,
          issues: issues
        })
      }
      return JSON.stringify({
        order: root.cardOrder,
        cards: cards,
        // The gear view builds its card chips through Repeaters, so "is it
        // populated" is a real question, not an assumption.
        cards_picker: {
          view: root.viewMode,
          enabled: root.manageEnabledCount,
          available: root.manageAvailableRows,
          rows: root.manageRows.length,
          built: (function() {
            if (!settingsView) return -1
            var n = 0
            var walk = function(item) {
              for (var i = 0; i < item.children.length; i++) {
                if (String(item.children[i]).indexOf("DragChip") !== -1) n++
                walk(item.children[i])
              }
            }
            walk(settingsView)
            return n
          })(),
          // A needs-gated card says why instead of silently refusing the click.
          gated: root.manageAvailableRows.filter(function(id) { return root.manageMissing(id) !== "" })
        },
        // The other half of "is it working": what each fetcher actually parsed.
        // `opened` and the live set are here because a card showing stale data
        // is usually one of these two being false, not a broken parser.
        opened: root.opened,
        failedFetches: root.failedFetches,
        // The raw setting, because a QML sequence type is not a JS Array and
        // that has broken "is this set?" logic before.
        rawCards: { value: root.setting("cards", null), type: typeof root.setting("cards", null),
                    isArray: Array.isArray(root.setting("cards", null)) },
        bar: root.barChipsProvider ? {
          items: root.barChipsProvider.barItems,
          chips: (root.barChipsProvider.chips || []).map(function(chip) {
            return { id: chip.id, text: chip.text, urgent: chip.urgent }
          }),
          // Every requested chip with its verdict, so "no chips" can be told
          // apart from "every chip decided it has nothing to say".
          attempted: root.barChipsProvider.barItems.map(function(id) {
            var chip = Model.barChip(id, Model.barData(root.barChipsProvider.panel || {}), {})
            return { id: id, hasData: chip.hasData, text: chip.text }
          })
        } : null,
        // Resolved theme colors, so "themed" is checkable: switch themes and
        // these must change. A hard-coded hex would not.
        theme: {
          face: hex(root.foreground),
          dim: hex(root.dim),
          track: hex(root.track),
          urgent: hex(root.urgent)
        },
        live: root.cardOrder.filter(function(id) { return root.cardLive(id) }),
        state: {
          repoPaths: root.repoPaths,
          // A setting that silently reads as "" disables its card with no
          // visible cause, so the inputs the fetchers gate on are reported.
          inputs: { calendarUrl: root.calendarUrl, symbols: root.settingSymbols,
                    companies: root.companyNumbers.length, weatherTown: root.weatherTown },
          fetchers: { calProc: calProc.running, calProcCmd: calProc.command, calProcExit: calProc.exitCode },
          // The original six, as one number each. A chip or a card that looks
          // empty is otherwise indistinguishable from a fetcher that never ran.
          weather: root.weather && root.weather.temp !== undefined ? root.weather.temp : null,
          market: root.market && root.market.symbols ? root.market.symbols.length : 0,
          calendar: root.calendar && root.calendar.events ? root.calendar.events.length : 0,
          companies: root.companies ? root.companies.length : 0,
          reminders: root.reminders ? Number(root.reminders.count || 0) : 0,
          systemCpu: root.system && root.system.cpuPercent !== undefined ? root.system.cpuPercent : null,
          media: root.mediaPlayer
            ? { title: root.mediaPlayer.title, artist: root.mediaPlayer.artist, playing: root.mediaPlayer.playing }
            : null,
          timer: { mode: root.timerModeId, running: root.timerRunning, left: root.timerLeft, done: root.timerDone },
          inbox: { dnd: root.inboxDnd, count: root.inboxRows.length,
                   top: root.inboxRows.length > 0 ? root.inboxRows[0].summary : "" },
          vpn: root.vpnConnections.map(function(c) { return c.name + ":" + c.state }),
          containers: root.containers ? { running: root.containers.running, total: root.containers.total } : null,
          containersError: root.containersError,
          repos: root.repos.map(function(r) {
            return r.name + ":" + (r.error !== "" ? r.error : (r.branch || "?") + (r.ahead ? " +" + r.ahead : "") + (r.behind ? " -" + r.behind : "") + (r.untracked ? " ?" + r.untracked : "") + (r.changed ? " *" + r.changed : ""))
          })
        }
      })
    }
  }

  // ============================================================= bar + popup
  // The button is the anchor and the only bar affordance when this panel runs
  // on its own. Hosted by BarWidget.qml, that widget paints the bar face and
  // this button steps aside so the slot is not doubled up.
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0e4"
    tooltipText: "Control Station \u2014 click to open, middle or right-click to refresh"
    active: root.alarming
    visible: !root.hostWidget
    interactive: !root.hostWidget
    pressable: !root.hostWidget
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // `fittedContentHeight` adds the card's padding and borders for us;
    // `fittedContentWidth` does not, so the inset is added here -- without it
    // the content box was 32px narrower than `zoomHost` and the grid spilled
    // over the card's border on both sides at every zoom stop.
    contentWidth: panel.fittedContentWidth(Style.space(560) * root.zoom + panel.verticalContentInset)
    contentHeight: panel.fittedContentHeight(root.panelContentHeight * root.zoom)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation || root.viewMode === "settings"

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.refreshFocused()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        // `m` from the dashboard, matching the gear in the toolbar, so the
        // card picker is reachable without a mouse. Escape comes back, since
        // the settings view blocks this handler while a field has focus.
        else if ((t === "m" || t === "M") && root.viewMode === "dashboard" && !root.resizeMode) {
          root.toggleSettingsView()
        }
      }

      Item {
        id: zoomHost
        width: Style.space(560)
        height: root.panelContentHeight
        scale: root.zoom
        // Scale about the top edge, not the centre. The card grows downwards
        // from a fixed top, so a centred origin slides the content up by
        // height * (zoom - 1) / 2 -- at zoom 1.6 that painted the toolbar and
        // the top of the first card row 136px above the card and left the same
        // gap of dead space at the bottom. With `Top` the painted box is
        // exactly 0..height*zoom, which is what the card was sized for.
        transformOrigin: Item.Top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top

      Item {
        id: toolbarRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        height: root.toolbarHeight

        Text {
          textFormat: Text.PlainText
          text: root.viewMode === "settings" ? "PLUGIN SETTINGS"
            : root.resizeMode ? "RESIZE MODE"
            : "CONTROL STATION"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: root.viewMode === "settings"
          text: root.manageEnabledCount + " card" + (root.manageEnabledCount === 1 ? "" : "s")
            + " on · " + root.manageAvailableCount + " available · esc back"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.left: parent.left
          anchors.leftMargin: Style.space(130)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: root.viewMode === "dashboard" && root.resizeMode
          text: "drag card corners or panel grip"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.left: parent.left
          anchors.leftMargin: Style.space(130)
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          // Sizes and settings: the card picker lives in the gear now.
          Button {
            text: ""
            tooltipText: "Resize cards \u2014 drag a card's corner handle to change its span"
            selected: root.resizeMode
            hasCursor: root.cursorActive && root.viewMode === "dashboard"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX - 8
            verticalPadding: 3
            onClicked: root.toggleResizeMode()
          }

          Button {
            text: "\uf013"
            tooltipText: "Settings \u2014 dashboard cards, sources, card headers, and the bar face"
            selected: root.viewMode === "settings"
            hasCursor: root.cursorActive && root.viewMode === "dashboard"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX - 8
            verticalPadding: 3
            onClicked: root.toggleSettingsView()
          }
        }
      }

      Flickable {
        id: bentoScroll
        anchors.top: toolbarRow.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: root.gridHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Item {
          id: gridItem
          width: root.gridWidth
          height: root.gridHeight
          anchors.horizontalCenter: parent.horizontalCenter

          Repeater {
            model: cellPlans
            delegate: GridCell {}
          }

          // An empty dashboard is reachable on purpose -- `cards: []` means no
          // cards -- so it gets a way out instead of a blank panel.
          Item {
            id: emptyDashboard
            anchors.fill: parent
            visible: root.cardOrder.length === 0

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(40)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: "No cards on the dashboard"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: "Pick the cards you want in SETTINGS \u2014 weather, market, calendar and the rest are all opt-in."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                wrapMode: Text.WordWrap
              }

              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Open SETTINGS"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: 3
                onClicked: root.toggleSettingsView()
              }
            }
          }
        }
      }

      Item {
        id: settingsView
        visible: root.viewMode === "settings"
        anchors.top: toolbarRow.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(8)
        clip: true

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: root.surface
          border.color: root.alpha(root.foreground, 0.14)
          border.width: 1

          // Scrollable: the card picker and the bar groups below push this past
          // the panel height on a small screen or at the low zoom stops.
          Flickable {
            id: settingsFlick
            anchors.fill: parent
            anchors.margins: Style.space(12)
            contentWidth: width
            contentHeight: settingsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height

            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "PLUGIN SETTINGS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              textFormat: Text.PlainText
              text: "Saved through the bar layout entry so it survives a restart."
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            SettingsField { label: "TOWN"
              TextField {
                id: townField
                width: parent.width - Style.space(96) - parent.spacing
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "City name"
                Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.toggleSettingsView(); event.accepted = true } }
              }
            }
            SettingsField { label: "SYMBOLS"
              TextField {
                id: symbolsField
                width: parent.width - Style.space(96) - parent.spacing
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "AAPL,MSFT,ETH-USD (order = display)"
                Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.toggleSettingsView(); event.accepted = true } }
              }
            }
            SettingsField { label: "COMPANIES"
              TextField {
                id: companyField
                width: parent.width - Style.space(96) - parent.spacing
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "00012345,00067890"
                Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.toggleSettingsView(); event.accepted = true } }
              }
            }
            SettingsField { label: "HEADERS"
              Button {
                width: parent.width - Style.space(96) - parent.spacing
                height: Style.spacing.controlHeight
                text: root.showHeaders ? "On \u2013 card name + checked time" : "Off \u2013 bodies fill the cards"
                selected: root.showHeaders
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX - 4
                verticalPadding: 2
                onClicked: {
                  root.showHeaders = !root.showHeaders
                  root.persistSettings({ showHeaders: root.showHeaders })
                }
              }
            }
            SettingsField { label: "ICAL URL"
              TextField {
                id: icalField
                width: parent.width - Style.space(96) - parent.spacing
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "https://calendar.google.com/calendar/ical/..."
                Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.toggleSettingsView(); event.accepted = true } }
              }
            }
            SettingsField { label: "REFRESH (s)"
              TextField {
                id: refreshField
                width: parent.width - Style.space(96) - parent.spacing
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "300"
                Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.toggleSettingsView(); event.accepted = true } }
              }
            }

            // ----------------------------------------------------- dashboard
            Text {
              textFormat: Text.PlainText
              text: "DASHBOARD"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              topPadding: Style.space(6)
            }

            Text {
              textFormat: Text.PlainText
              text: "Two chip lists, one setting. The first is the dashboard and its order \u2014 "
                  + "drag a chip onto another to rearrange. Click a chip to take it off; "
                  + "click one below to put it on."
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "ON DASHBOARD"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              width: parent.width
              topPadding: Style.space(6)
            }

            ChipStrip {
              id: dashboardChips
              onReordered: function(from, to) {
                if (from >= 0 && from < root.cardOrder.length) root.manageReorder(root.cardOrder[from], to)
              }

              Repeater {
                model: root.cardOrder

                delegate: DragChip {
                  required property string modelData
                  required property int index
                  chipIndex: index
                  strip: dashboardChips
                  label: Model.cardById(modelData) ? Model.cardById(modelData).title : modelData
                  checked: true
                  draggable: root.cardOrder.length > 1
                  onToggled: root.manageToggle(modelData)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "AVAILABLE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              width: parent.width
              topPadding: Style.space(10)
              visible: root.manageAvailableRows.length > 0
            }

            ChipStrip {
              id: availableChips

              Repeater {
                model: root.manageAvailableRows

                delegate: DragChip {
                  required property string modelData
                  required property int index
                  chipIndex: index
                  strip: availableChips
                  label: Model.cardById(modelData) ? Model.cardById(modelData).title : modelData
                  // A card that is missing a setting says so in its tooltip
                  // and refuses the click, rather than vanishing from the list.
                  note: root.manageMissing(modelData)
                  locked: root.manageMissing(modelData) !== ""
                  onToggled: root.manageToggle(modelData)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Every card is off. The dashboard keeps this state; nothing is added back for you."
              visible: root.manageEnabledCount === 0
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            // ------------------------------------------------------ bar face
            Text {
              textFormat: Text.PlainText
              text: "BAR FACE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              topPadding: Style.space(6)
            }

            Text {
              textFormat: Text.PlainText
              text: "Pick what the bar shows. Order here is order on the bar. "
                  + "None selected leaves the plain icon."
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: Model.BAR_ITEM_IDS

                delegate: SettingsToggle {
                  required property string modelData
                  barLabel: Model.barItemLabel(modelData)
                  checked: root.barItems.indexOf(modelData) !== -1
                  onToggled: root.toggleBarItem(modelData)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: root.barItems.length > 1

              Text {
                textFormat: Text.PlainText
                text: "ORDER"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              // Left to right is bar order; a chip dragged onto another takes
              // its place. Clicking one takes it off the bar, same as the
              // picker above it.
              ChipStrip {
                id: barOrderChips
                width: parent.width - Style.space(96) - parent.spacing
                onReordered: function(from, to) {
                  if (from >= 0 && from < root.barItems.length) root.reorderBarItem(root.barItems[from], to)
                }

                Repeater {
                  model: root.barItems

                  delegate: DragChip {
                    required property string modelData
                    required property int index
                    chipIndex: index
                    strip: barOrderChips
                    label: Model.barItemLabel(modelData)
                    checked: true
                    draggable: root.barItems.length > 1
                    onToggled: root.toggleBarItem(modelData)
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: root.barSymbolPool.length > 0 && root.barItems.indexOf("market") !== -1

              Text {
                textFormat: Text.PlainText
                text: "BAR SYMBOLS"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Flow {
                width: parent.width - Style.space(96) - parent.spacing
                spacing: Style.space(6)

                Repeater {
                  model: root.barSymbolPool

                  delegate: SettingsToggle {
                    required property string modelData
                    barLabel: modelData
                    checked: root.barSymbols.indexOf(modelData) !== -1
                    locked: root.barSymbols.indexOf(modelData) === -1
                          && root.barSymbols.length >= Model.MAX_BAR_SYMBOLS
                    onToggled: root.toggleBarSymbol(modelData)
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "First " + Model.MAX_BAR_SYMBOLS + " of the symbols above reach the bar."
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
              visible: root.barItems.indexOf("market") !== -1 && root.barSymbolPool.length > 0
            }

            // ------------------------------------------------------ placement
            Text {
              textFormat: Text.PlainText
              text: "PLACEMENT"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              topPadding: Style.space(6)
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.barSections

                delegate: SettingsToggle {
                  required property string modelData
                  barLabel: modelData.toUpperCase()
                  checked: root.barSection === modelData
                  onToggled: root.moveBarWidget(modelData, 0)
                }
              }

              Item { width: Style.space(8); height: 1 }

              SettingsToggle {
                text: "\uf0d2"
                tooltip: "Move one slot earlier"
                locked: !root.barLocated || root.barIndex <= 0
                onToggled: root.nudgeBarSlot(-1)
              }
              SettingsToggle {
                text: "\uf0d3"
                tooltip: "Move one slot later"
                locked: !root.barLocated || root.barIndex >= root.barSlotCount - 1
                onToggled: root.nudgeBarSlot(1)
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.barLocated
                ? "Slot " + (root.barIndex + 1) + " of " + root.barSlotCount
                  + " in " + root.barSection + (root.barMoveNote !== "" ? " \u2013 " + root.barMoveNote : "")
                : "Not on the bar \u2013 enable it with `omarchy bar put " + root.moduleName + "`"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Save"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX - 4
                verticalPadding: 3
                onClicked: root.saveSettings()
              }

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX - 4
                verticalPadding: 3
                onClicked: root.toggleSettingsView()
              }
            }
            }
          }
        }
      }
      }

      Rectangle {
        id: panelGrip
        visible: root.viewMode === "dashboard" && root.resizeMode
        width: Style.space(18)
        height: Style.space(18)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(2)
        radius: 3
        color: root.track
        border.color: root.alpha(root.foreground, 0.5)
        border.width: 1
        z: 40

        MouseArea {
          anchors.fill: parent
          // Vertical: `updatePanelZoom` only reads the up/down drag, because
          // that is the only axis the grip itself can travel along.
          cursorShape: Qt.SizeVerCursor
          preventStealing: true
          // Screen coordinates: the card grows downwards and its origin
          // shifts as the zoom changes, so the grip -- and every frame
          // inside the panel -- moves under the cursor. The screen does not.
          onPressed: function(mouse) {
            root.beginPanelZoom(panelGrip.mapToGlobal(mouse.x, mouse.y).y)
          }
          onPositionChanged: function(mouse) {
            root.updatePanelZoom(panelGrip.mapToGlobal(mouse.x, mouse.y).y)
          }
          onReleased: root.endPanelZoom()
          onCanceled: root.endPanelZoom()
        }
      }
    }
  }

  // ============================================================= card chrome
  component SettingsField: Row {
    id: fieldRow
    required property string label
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: fieldRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      width: Style.space(96)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Toggle button for the bar-face groups: `checked` is the state, `locked` is
  // a dimmed dead end (first item can't move earlier, fourth symbol is over
  // the cap) so the rule is visible instead of silently ignored.
  component SettingsToggle: Button {
    id: toggle
    property string barLabel: ""
    property bool checked: false
    property bool locked: false
    property string tooltip: ""

    text: barLabel
    tooltipText: tooltip
    selected: checked
    bordered: true
    enabled: !locked
    opacity: locked ? 0.45 : 1
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    hasCursor: root.cursorActive && root.viewMode === "dashboard"
    horizontalPadding: Style.spacing.controlPaddingX - 6
    verticalPadding: 2

    onClicked: toggle.toggled()
    signal toggled()
  }

  // A wrapping row of chips that can be rearranged by dragging one onto
  // another. The strip owns the drag because a chip cannot see its neighbours:
  // it hit-tests its own children, so the drop target is whichever chip the
  // pointer is over, wrapped lines included. `chipIndex` is both the position
  // and the marker that tells a chip apart from the Repeater sharing `children`.
  component ChipStrip: Flow {
    id: strip

    // Index being dragged, and the index it would land on. -1 for neither.
    property int dragFrom: -1
    property int dropAt: -1

    readonly property bool dragging: strip.dragFrom >= 0

    // from and to are positions in the list the caller handed the Repeater.
    signal reordered(int from, int to)

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    function chipIndexAt(px, py) {
      for (var i = 0; i < strip.children.length; i++) {
        var chip = strip.children[i]
        // No visibility test: `visible` is the *effective* one, so it reads
        // false whenever the popup window itself is unmapped, and a chip the
        // pointer is over is on screen by definition.
        if (chip.chipIndex === undefined || chip.chipIndex < 0) continue
        if (px >= chip.x && px <= chip.x + chip.width
            && py >= chip.y && py <= chip.y + chip.height) return chip.chipIndex
      }
      return -1
    }

    function beginDrag(from) {
      strip.dragFrom = from
      strip.dropAt = from
    }

    // Off the strip entirely keeps the last target rather than snapping back:
    // a pointer that strays into the gap between two chips mid-drag should not
    // throw the drop away.
    function updateDrag(px, py) {
      var at = strip.chipIndexAt(px, py)
      if (at >= 0) strip.dropAt = at
    }

    function endDrag() {
      var from = strip.dragFrom
      var to = strip.dropAt
      strip.cancelDrag()
      if (from >= 0 && to >= 0 && from !== to) strip.reordered(from, to)
    }

    function cancelDrag() {
      strip.dragFrom = -1
      strip.dropAt = -1
    }
  }

  // One chip of a ChipStrip: the same bordered toggle the bar face uses, with
  // the press handling lifted into a MouseArea above it. Button owns its own
  // MouseArea and would swallow the drag, so this one sits on top and decides
  // between a click and a drag itself.
  component DragChip: Item {
    id: chip
    required property int chipIndex
    property ChipStrip strip: null
    property string label: ""
    property string note: ""
    property bool checked: false
    property bool locked: false
    property bool draggable: false

    signal toggled()

    readonly property bool isDragSource: chip.strip !== null && chip.strip.dragFrom === chip.chipIndex
    readonly property bool isDropTarget: chip.strip !== null && chip.strip.dragging
      && chip.strip.dropAt === chip.chipIndex && !chip.isDragSource

    implicitWidth: face.implicitWidth
    implicitHeight: face.implicitHeight
    width: implicitWidth
    height: implicitHeight
    opacity: chip.isDragSource ? 0.45 : (chip.locked ? 0.45 : 1)

    Button {
      id: face
      anchors.fill: parent
      text: chip.label
      tooltipText: chip.note !== "" ? chip.note
        : (chip.draggable ? "Drag onto another chip to reorder" : "")
      selected: chip.checked
      bordered: true
      hasCursor: chipMouse.containsMouse && !chip.locked
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.spacing.controlPaddingX - 6
      verticalPadding: 2
    }

    // Where the chip would land: the edge it is being inserted against, so a
    // drop reads as "in front of this one" rather than "swap with this one".
    Rectangle {
      visible: chip.isDropTarget
      width: Style.space(2)
      radius: 1
      color: root.foreground
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.left: chip.strip !== null && chip.strip.dropAt < chip.strip.dragFrom ? parent.left : undefined
      anchors.right: chip.strip !== null && chip.strip.dropAt < chip.strip.dragFrom ? undefined : parent.right
      anchors.leftMargin: -Style.space(2)
      anchors.rightMargin: -Style.space(2)
      z: 5
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      preventStealing: true
      cursorShape: chip.draggable
        ? (chipMouse.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        : Qt.PointingHandCursor

      property bool dragging: false
      property real pressX: 0
      property real pressY: 0

      onPressed: function(mouse) {
        chipMouse.pressX = mouse.x
        chipMouse.pressY = mouse.y
        chipMouse.dragging = false
      }

      // A few pixels of slop before a press becomes a drag, so a click on a
      // chip that moves a hair still toggles the card.
      onPositionChanged: function(mouse) {
        if (!chip.draggable || !chipMouse.pressed || chip.strip === null) return
        if (!chipMouse.dragging) {
          var moved = Math.abs(mouse.x - chipMouse.pressX) + Math.abs(mouse.y - chipMouse.pressY)
          if (moved < Style.space(5)) return
          chipMouse.dragging = true
          chip.strip.beginDrag(chip.chipIndex)
        }
        var point = chipMouse.mapToItem(chip.strip, mouse.x, mouse.y)
        chip.strip.updateDrag(point.x, point.y)
      }

      onReleased: {
        if (chipMouse.dragging) {
          chipMouse.dragging = false
          chip.strip.endDrag()
        } else if (!chip.locked) {
          chip.toggled()
        }
      }

      onCanceled: {
        if (!chipMouse.dragging) return
        chipMouse.dragging = false
        chip.strip.cancelDrag()
      }
    }
  }

  component GridCell: Item {
    id: gridCell
    required property var model
    required property int index

    readonly property string cardId: model.cardId
    readonly property bool isFocused: root.cursorActive && index === root.focusIndex

    // `computeFlow` runs while a resize is in flight, so the model already
    // carries the live span -- the cell just follows it, and the Behaviours
    // turn the reflow into a slide instead of a teleport.
    x: model.x
    y: model.y
    width: model.w
    height: model.h

    Behavior on x { enabled: root.cellsAnimate; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: root.cellsAnimate; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: root.cellsAnimate; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: root.cellsAnimate; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    CellBox {
      id: box
      cellId: gridCell.cardId
      cellTitle: root.cardTitle(gridCell.cardId)
      checkedAtText: root.checkedAtFor(gridCell.cardId)
      cellCursor: gridCell.isFocused
      cellOrder: root.cardIndexFor(gridCell.cardId)
      cellUrgent: root.cardUrgent(gridCell.cardId)

      width: parent.width
      height: parent.height

      Loader {
        id: bodyLoader
        objectName: "body-" + gridCell.cardId
        anchors.top: box.headerItem.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.space(2)
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        anchors.bottomMargin: Style.space(8)
        clip: true
        sourceComponent: root.cardComponent(gridCell.cardId)

        Component.onCompleted: root.registerLoader(gridCell.cardId, bodyLoader)
        Component.onDestruction: root.registerLoader(gridCell.cardId, null)
      }
    }

    Rectangle {
      id: resizeHandle
      visible: root.resizeMode && !root.editingLocation
      anchors.right: gridCell.right
      anchors.bottom: gridCell.bottom
      anchors.rightMargin: Style.space(1)
      anchors.bottomMargin: Style.space(1)
      width: Style.space(14) / root.clamp(root.zoom, root.zoomMin, root.zoomMax)
      height: Style.space(14) / root.clamp(root.zoom, root.zoomMin, root.zoomMax)
      radius: 3
      color: root.resizeLive.id === gridCell.cardId ? root.foreground : root.track
      border.color: root.alpha(root.foreground, 0.45)
      border.width: 1
      z: 30

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.SizeFDiagCursor
        // Without this a downward drag hands the grab to `bentoScroll`
        // halfway through the resize.
        preventStealing: true

        // Both ends of the drag are read in `gridItem`, whose origin holds
        // still while the card -- and the handle anchored to it -- moves.
        // Mapping through it also survives the Flickable scrolling mid-drag.
        onPressed: function(mouse) {
          var p = resizeHandle.mapToItem(gridItem, mouse.x, mouse.y)
          root.beginResize(gridCell.cardId)
          root.resizePressGX = p.x
          root.resizePressGY = p.y
          // The model value, not the item's: mid-animation `width` is a
          // transient frame, and the drag should start from the settled size.
          root.resizeStartW = gridCell.model.w
          root.resizeStartH = gridCell.model.h
        }
        onPositionChanged: function(mouse) {
          var p = resizeHandle.mapToItem(gridItem, mouse.x, mouse.y)
          root.updateResize(gridCell.cardId,
            root.resizeStartW + (p.x - root.resizePressGX),
            root.resizeStartH + (p.y - root.resizePressGY))
        }
        onReleased: root.endResize(gridCell.cardId)
        onCanceled: root.endResize(gridCell.cardId)
      }
    }
  }

  component CellBox: BorderSurface {
    id: box
    property string cellId: ""
    property string cellTitle: ""
    property string checkedAtText: ""
    property bool cellCursor: false
    property bool cellUrgent: false
    // Position in the enable order, for the resize-mode badge. -1 means the
    // card is not on the dashboard.
    property int cellOrder: -1
    property bool cellDropTarget: false
    property Item headerItem: headerRow
    readonly property bool dragging: dragArea.drag.active

    width: parent.width
    height: parent.height
    color: root.surface
    borderSpec: Border.flat(root.alpha(root.foreground,
      box.dragging ? 0.55
      : box.cellDropTarget ? 0.75
      : box.cellCursor ? 0.5
      : box.cellUrgent ? 0.5
      : 0.14), 1)
    radius: Style.cornerRadius
    z: box.dragging ? 20 : 0

    Drag.active: box.dragging
    Drag.dragType: Drag.Automatic
    Drag.source: box
    Drag.hotSpot: Qt.point(dragArea.mouseX, dragArea.mouseY)

    DropArea {
      id: cellDrop
      anchors.fill: parent
      onEntered: function(drag) { if (root.resizeMode) return; if (drag.source !== box && drag.source && drag.source.cellId && drag.source.cellId !== box.cellId) box.cellDropTarget = true }
      onExited: function() { box.cellDropTarget = false }
      onDropped: function(drag) {
        box.cellDropTarget = false
        if (root.resizeMode) return
        if (drag.source && drag.source !== box && drag.source.cellId && drag.source.cellId !== box.cellId)
          root.swapCards(drag.source.cellId, box.cellId)
      }
    }

    MouseArea {
      id: dragArea
      anchors.fill: parent
      drag.target: root.resizeMode ? null : box
      drag.threshold: 12
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton

      onEntered: root.focusCard(root.cardIndexFor(box.cellId))
      onPressed: function(mouse) { root.focusCard(root.cardIndexFor(box.cellId)) }
      onReleased: function(mouse) {
        if (box.dragging) Qt.callLater(function() { box.x = 0; box.y = 0 })
      }
    }

    Item {
      id: headerRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      visible: root.showHeaders
      height: root.showHeaders ? Math.max(titleText.implicitHeight, checkedText.implicitHeight) : 0

      Text {
        id: titleText
        textFormat: Text.PlainText
        text: box.cellTitle
        color: box.cellUrgent ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: checkedText
        textFormat: Text.PlainText
        visible: box.checkedAtText !== ""
        text: box.checkedAtText
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // ============================================================= card bodies
  component WeatherBody: Column {
    id: weatherCol
    spacing: Style.space(6)

    Item {
      width: parent.width
      height: Style.space(50)

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.weather && root.weather.icon ? root.weather.icon : "\uf0c2"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }

      Column {
        id: wxRight
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.editingLocation
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: root.weather && root.weather.humidity !== undefined
            ? root.weather.humidity + "% RH" : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
        }

        Text {
          textFormat: Text.PlainText
          text: root.weather && root.weather.wind !== undefined
            ? Math.round(root.weather.wind) + " km/h" : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
        }
      }

      Column {
        id: wxMid
        anchors.left: parent.left
        anchors.leftMargin: Style.space(46)
        anchors.right: wxRight.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: root.weather && root.weather.temp !== undefined ? Math.round(root.weather.temp) + "\u00b0" : "\u2014"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          id: townLabel
          textFormat: Text.PlainText
          text: root.weatherTown !== "" ? root.weatherTown : "no location"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }

        TapHandler { onTapped: root.startEditingLocation() }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.weather && root.weather.forecast || []

        Item {
          required property var modelData
          width: Math.max(0, (parent.width - 2 * Style.space(6)) / 3)
          height: Style.space(28)

          Column {
            anchors.centerIn: parent
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              text: modelData.icon + " " + modelData.day
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.max + "\u00b0 / " + modelData.min + "\u00b0"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    Row {
      visible: root.editingLocation
      width: parent.width
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: "LOC"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }

      TextField {
        id: locField
        width: parent.width - Style.space(40)
        foreground: root.foreground
        font.family: root.fontFamily
        placeholderText: "Search city"
        onTextChanged: if (root.editingLocation) geocodeDebounce.restart()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.cancelEditingLocation(); event.accepted = true }
          else if (event.key === Qt.Key_Down) {
            if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (root.suggestionIndex > 0) root.suggestionIndex--
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.locationSuggestions.length > 0) root.pickSuggestion(root.locationSuggestions[root.suggestionIndex])
            else root.cancelEditingLocation()
            event.accepted = true
          }
        }
      }
    }

    Repeater {
      visible: root.editingLocation && root.locationSuggestions.length > 0
      model: root.locationSuggestions

      Rectangle {
        required property var modelData
        required property int index
        width: parent.width
        height: Style.space(18)
        radius: Style.cornerRadius
        color: index === root.suggestionIndex ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            visible: modelData.description !== ""
            text: modelData.description
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: Math.max(0, parent.width - Style.space(10))
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onPositionChanged: root.suggestionIndex = index
          onClicked: root.pickSuggestion(modelData)
        }
      }
    }
  }

  component MarketBody: Column {
    id: marketCol
    spacing: Style.space(3)

    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(marketCol) - Style.space(18) - Math.max(Style.spacing.controlHeight, Style.space(24))) / Style.space(20)),
      1, 12)
    readonly property var shownSymbols: (root.market && root.market.symbols || []).slice(0, maxShown)
    readonly property int shownExtra: Math.max(0, (root.market && root.market.symbols || []).length - maxShown)

    Repeater {
      model: shownSymbols

      Item {
        required property var modelData
        width: parent.width
        height: Style.space(17)

        Text {
          textFormat: Text.PlainText
          text: modelData.symbol
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(64)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: root.formatPrice(modelData.price)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.left: parent.left
          anchors.leftMargin: Style.space(72)
          anchors.right: pctText.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
        }

        Text {
          id: pctText
          textFormat: Text.PlainText
          text: root.formatPct(modelData.changePercent)
          color: modelData.isDown ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          horizontalAlignment: Text.AlignRight
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: shownExtra > 0
      text: "+" + shownExtra + " more"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: shownSymbols.length === 0
      text: "No data yet"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item { height: Style.space(2); width: parent.width }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Repeater {
        model: ["Stocks", "Crypto", "Metals"]

        Button {
          required property string modelData
          text: modelData
          selected: Model.isPresetActive(root.settingSymbols, modelData)
          hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "market"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX - 4
          verticalPadding: 2
          onClicked: root.togglePreset(modelData)
          onHovered: function(h) { if (h) root.cursorActive = true }
        }
      }
    }
  }

  component CompaniesBody: Column {
    id: companyCol
    spacing: Style.space(6)

    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(companyCol) - Style.space(16)) / Style.space(48)), 1, 5)
    readonly property var shownCompanies: (root.companies || []).slice(0, maxShown)
    readonly property int shownExtra: Math.max(0, (root.companies || []).length - maxShown)

    Repeater {
      model: shownCompanies

      Column {
        required property var modelData
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: modelData.companyName
          color: (modelData.accountsUrgent || modelData.returnsUrgent) ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.bold: true
          font.pixelSize: Style.font.body
          width: parent.width
          elide: Text.ElideRight
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            textFormat: Text.PlainText
            text: "ACCOUNTS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            width: Style.space(74)
          }
          Text {
            textFormat: Text.PlainText
            text: modelData.accountsNextDue ? Model.formatDateCh(modelData.accountsNextDue) : "\u2014"
            color: modelData.accountsUrgent ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: modelData.accountsUrgent === true
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            textFormat: Text.PlainText
            text: "RETURNS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            width: Style.space(74)
          }
          Text {
            textFormat: Text.PlainText
            text: modelData.returnsNextDue ? Model.formatDateCh(modelData.returnsNextDue) : "\u2014"
            color: modelData.returnsUrgent ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: modelData.returnsUrgent === true
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: shownExtra > 0
      text: "+" + shownExtra + " more"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: root.companyNumbers.length === 0
      text: "Set company numbers in plugin settings"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width
      wrapMode: Text.WordWrap
    }
  }

  component CalendarBody: Column {
    id: calendarCol
    spacing: Style.space(4)

    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(calendarCol) - Style.space(14)) / Style.space(22)), 1, 12)
    readonly property var shownRows: (root.calendar && root.calendar.events || []).slice(0, maxShown)
    readonly property int shownExtra: Math.max(0, (root.calendar && root.calendar.events || []).length - maxShown)

    Repeater {
      model: shownRows

      // An Item, not a Row: the summary is anchored to the trailing edge, and
      // a positioner cannot host left/right anchored children.
      Item {
        required property var modelData
        width: parent.width
        height: Style.space(18)

        Text {
          textFormat: Text.PlainText
          text: modelData.dateStr
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(52)
          height: parent.height
          verticalAlignment: Text.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          text: modelData.dtstartStr
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(38)
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          x: Style.space(58)
        }

        Text {
          textFormat: Text.PlainText
          text: modelData.summary
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          x: Style.space(96)
          width: Math.max(0, parent.width - Style.space(96))
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: shownExtra > 0
      text: "+" + shownExtra + " more"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: root.calendarUrl === "" && shownRows.length === 0
      text: "Set an iCal URL in plugin settings"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.calendarUrl !== "" && shownRows.length === 0 && !(root.calendar && root.calendar.events && root.calendar.events.length > 0)
      text: "No upcoming events"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component SystemBody: Column {
    id: systemCol
    spacing: Style.space(4)

    SysMeterRow { label: "CPU"; percent: root.system && root.system.cpuPercent || 0 }
    SysMeterRow { label: "MEM"; percent: root.system && root.system.memoryPercent || 0 }
    SysMeterRow { label: "DISK"; percent: root.system && root.system.diskPercent || 0; sub: root.system && root.system.diskPercent > 0
      ? root.system.diskUsed + " / " + root.system.diskTotal : "" }

    Row {
      width: parent.width
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        text: root.system && root.system.loadAverage > 0 ? "load " + root.system.loadAverage.toFixed(2) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: root.system && root.system.tempCelsius > 0 ? root.system.tempCelsius + "\u00b0C" : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component RemindersBody: Column {
    id: remindersCol
    spacing: Style.space(4)

    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(remindersCol) - Style.space(14)) / Style.space(22)), 1, 12)
    readonly property var shownRows: (root.reminders && root.reminders.reminders || []).slice(0, maxShown)
    readonly property int shownExtra: Math.max(0, (root.reminders && root.reminders.reminders || []).length - maxShown)

    Repeater {
      model: shownRows

      Row {
        required property var modelData
        width: parent.width
        height: Style.space(18)
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: root.reminderCountdown(modelData)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(48)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.reminderAtText(modelData)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(52)
          anchors.right: parent.right
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: shownExtra > 0
      text: "+" + shownExtra + " more"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: root.reminders.count === 0 && shownRows.length === 0
      text: "No reminders"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ============================================================ the six newer bodies
  // Each is an Item rather than a Column so it can hold a centred empty state
  // next to a top-aligned content column without anchors fighting a positioner.

  component MediaBody: Item {
    id: mediaBody
    readonly property var player: root.mediaPlayer
    readonly property bool has: root.mediaPlayer !== null
    readonly property bool hasLength: root.mediaPlayer !== null && root.mediaPlayer.length > 0
    readonly property real progress: mediaBody.hasLength
      ? root.clamp(root.mediaPlayer.position / root.mediaPlayer.length, 0, 1) : 0
    readonly property int sourceCount: root.mediaService && root.mediaService.sourcePlayers
      ? root.mediaService.sourcePlayers.length : 0

    // Nothing to control: say so plainly instead of drawing an empty transport.
    CardEmpty {
      text: "No media playing"
      sub: "A player shows up here on its own"
      visible: !mediaBody.has
      width: parent.width
      y: (parent.height - height) / 2
    }

    Column {
      id: mediaInfo
      visible: mediaBody.has
      width: parent.width
      anchors.top: parent.top
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: mediaBody.player ? mediaBody.player.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        width: parent.width
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: mediaBody.player ? mediaBody.player.artist : ""
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
        elide: Text.ElideRight
      }
    }

    Item {
      id: mediaProgress
      visible: mediaBody.has && mediaBody.hasLength
      width: parent.width
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      anchors.bottom: mediaTimes.top
      anchors.bottomMargin: Style.space(4)

      Meter { anchors.fill: parent; value: mediaBody.progress }
    }

    Row {
      id: mediaTimes
      visible: mediaBody.has && mediaBody.hasLength
      width: parent.width
      anchors.bottom: mediaTransport.top
      anchors.bottomMargin: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.formatClock(mediaBody.player ? mediaBody.player.position : 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item { width: Math.max(0, parent.width - left.width - right.width); height: 1 }

      Text {
        id: right
        textFormat: Text.PlainText
        text: Model.formatClock(mediaBody.player ? mediaBody.player.length : 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: mediaTransport
      width: parent.width
      anchors.bottom: parent.bottom
      spacing: Style.spacing.controlGap

      readonly property real buttonSize: Math.max(Style.spacing.controlHeight, Style.space(20))

      Button {
        iconText: "󰓮"
        tooltipText: "Previous track"
        iconSize: Style.font.body
        fontFamily: root.fontFamily
        foreground: root.dim
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "media"
        enabled: mediaBody.player ? mediaBody.player.canPrev : false
        onClicked: root.mediaAction("previous")
        implicitWidth: mediaTransport.buttonSize
        implicitHeight: mediaTransport.buttonSize
      }

      Button {
        iconText: mediaBody.player && mediaBody.player.playing ? "󰐊" : "󰏤"
        tooltipText: mediaBody.player && mediaBody.player.playing ? "Pause" : "Play"
        fontFamily: root.fontFamily
        foreground: root.foreground
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "media"
        enabled: mediaBody.player ? mediaBody.player.canToggle : false
        onClicked: root.mediaAction("playpause")
        implicitWidth: mediaTransport.buttonSize + Style.space(6)
        implicitHeight: mediaTransport.buttonSize
      }

      Button {
        iconText: "󰓭"
        tooltipText: "Next track"
        iconSize: Style.font.body
        fontFamily: root.fontFamily
        foreground: root.dim
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "media"
        enabled: mediaBody.player ? mediaBody.player.canNext : false
        onClicked: root.mediaAction("next")
        implicitWidth: mediaTransport.buttonSize
        implicitHeight: mediaTransport.buttonSize
      }

      Item { width: Math.max(0, parent.width - 3 * mediaTransport.buttonSize - Style.space(6)
        - 2 * Style.spacing.controlGap - Style.space(6)); height: 1 }

      // Only worth the space when there is a second player to switch to.
      Button {
        visible: mediaBody.sourceCount > 1
        text: mediaBody.player ? mediaBody.player.label : ""
        tooltipText: "Switch player"
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        foreground: root.dim
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "media"
        onClicked: root.cycleMediaPlayer()
        leftAlign: true
        horizontalPadding: 0
        verticalPadding: 0
      }
    }
  }

  component TimerBody: Item {
    id: timerBody

    readonly property bool stopwatch: root.timerModeId === "stopwatch"
    readonly property string clock: Model.formatClock(root.timerSeconds)
    readonly property string spentText: stopwatch
      ? Model.formatClock(root.timerSeconds) : Model.formatClock(root.timerLeft)
    readonly property string leftText: stopwatch
      ? Model.formatClock(root.timerSeconds) : Model.formatClock(root.timerTotal)

    // Mode is a button, not a label: cycling it is the fastest way to use the
    // card, and it keeps the card to three controls.
    Text {
      id: modeLabel
      textFormat: Text.PlainText
      text: Model.timerMode(root.timerModeId).label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter

      TapHandler {
        onTapped: root.cycleTimerMode()
      }
    }

    Text {
      id: clockText
      textFormat: Text.PlainText
      text: timerBody.clock
      color: root.timerRunning ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -Style.space(6)
    }

    // One dot per planned session, filled as they land: the only "progress" a
    // focus timer needs beyond the bar below.
    Row {
      id: dots
      spacing: Style.space(4)
      anchors.top: clockText.bottom
      anchors.topMargin: Style.space(4)
      anchors.horizontalCenter: parent.horizontalCenter
      visible: !timerBody.stopwatch

      Repeater {
        model: root.timerSessions

        Rectangle {
          required property int index
          width: Style.space(5)
          height: width
          radius: width / 2
          color: index < root.timerDone ? root.foreground : root.track
        }
      }
    }

    Item {
      id: timerBar
      visible: !timerBody.stopwatch
      width: parent.width
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      anchors.bottom: timerTimes.top
      anchors.bottomMargin: Style.space(4)

      Meter { anchors.fill: parent; value: root.timerProgress }
    }

    Row {
      id: timerTimes
      visible: !timerBody.stopwatch
      width: parent.width
      anchors.bottom: timerControls.top
      anchors.bottomMargin: Style.space(6)

      Text {
        id: spent
        textFormat: Text.PlainText
        text: timerBody.spentText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item { width: Math.max(0, parent.width - spent.width - total.width); height: 1 }

      Text {
        id: total
        textFormat: Text.PlainText
        text: timerBody.leftText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: timerControls
      width: parent.width
      anchors.bottom: parent.bottom
      spacing: Style.spacing.controlGap

      Button {
        iconText: "󰑕"
        tooltipText: "Reset timer"
        fontFamily: root.fontFamily
        foreground: root.dim
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "timer"
        onClicked: root.resetTimer()
        implicitWidth: Style.spacing.controlHeight
        implicitHeight: Style.spacing.controlHeight
      }

      Button {
        iconText: root.timerRunning ? "󰐊" : "󰏤"
        tooltipText: root.timerRunning ? "Pause timer" : "Start timer"
        fontFamily: root.fontFamily
        foreground: root.foreground
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "timer"
        onClicked: root.toggleTimer()
        implicitWidth: Style.spacing.controlHeight + Style.space(6)
        implicitHeight: Style.spacing.controlHeight
      }

      Item { width: Math.max(0, parent.width - 2 * Style.spacing.controlHeight - Style.space(6)
        - Style.spacing.controlGap); height: 1 }

      Text {
        textFormat: Text.PlainText
        text: timerBody.stopwatch ? (root.timerRunning ? "RUNNING" : "PAUSED") : root.timerDone + "/" + root.timerSessions
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  component InboxBody: Item {
    id: inboxBody

    readonly property var rows: root.inboxRows || []
    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(inboxBody) - Style.space(30)) / Style.space(20)), 1, 8)

    CardEmpty {
      text: root.inboxDnd ? "Do not disturb" : "Inbox zero"
      sub: root.inboxDnd ? "Nothing lands while DND is on" : "Notifications will collect here"
      visible: inboxBody.rows.length === 0
      width: parent.width
      y: (parent.height - height) / 2
    }

    Row {
      id: inboxActions
      width: parent.width
      anchors.top: parent.top

      Text {
        textFormat: Text.PlainText
        text: inboxBody.rows.length === 0 ? "" : inboxBody.rows.length + " waiting"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      Item { width: Math.max(0, parent.width - dnd.width - clear.width - 2 * Style.spacing.controlGap); height: 1 }

      Button {
        id: dnd
        iconText: root.inboxDnd ? "󰂛" : "󰂚"
        tooltipText: root.inboxDnd ? "Turn do not disturb off" : "Turn do not disturb on"
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        foreground: root.inboxDnd ? root.urgent : root.dim
        active: root.inboxDnd
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "inbox"
        onClicked: root.toggleDnd()
        implicitWidth: Style.space(22)
        implicitHeight: Style.space(18)
      }

      Button {
        id: clear
        text: "Clear"
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        foreground: root.dim
        visible: inboxBody.rows.length > 0
        hasCursor: root.cursorActive && root.cardOrder[root.focusIndex] === "inbox"
        onClicked: root.clearInbox()
        horizontalPadding: 0
        verticalPadding: 0
        implicitHeight: Style.space(18)
      }
    }

    Column {
      id: inboxList
      visible: inboxBody.rows.length > 0
      width: parent.width
      anchors.top: inboxActions.bottom
      anchors.topMargin: Style.space(6)
      spacing: Style.space(2)
      clip: true
      height: Math.min(implicitHeight, parent.height - y - Style.space(2))

      Repeater {
        model: inboxBody.rows.slice(0, inboxBody.maxShown)

        Item {
          required property var modelData
          width: inboxList.width
          height: Style.space(18)

          Rectangle {
            id: urgencyDot
            width: Style.space(4)
            height: width
            radius: width / 2
            color: modelData.urgency >= 2 ? root.urgent : root.dim
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: modelData.summary
            color: modelData.urgency >= 2 ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: urgencyDot.right
            anchors.leftMargin: Style.space(6)
            anchors.right: stamp.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
          }

          Text {
            id: stamp
            textFormat: Text.PlainText
            text: Model.relativeTime(modelData.at, root.nowMs)
            color: Qt.darker(root.dim, 1.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }

  component VpnBody: Item {
    id: vpnBody

    readonly property var connections: root.vpnConnections || []

    CardEmpty {
      text: root.vpnBackend === "nordvpn" ? "No NordVPN" : "No VPN profiles"
      sub: "Add one in Network settings"
      visible: vpnBody.connections.length === 0
      width: parent.width
      y: (parent.height - height) / 2
    }

    Column {
      width: parent.width
      anchors.top: parent.top
      spacing: Style.space(2)
      clip: true
      height: parent.height

      Repeater {
        model: vpnBody.connections

        CardRow {
          required property var modelData
          readonly property bool up: modelData.active
          glyph: modelData.kind === "nordvpn" ? "󰒢" : "󰒣"
          label: modelData.name
          value: modelData.activating ? "…" : (up ? "UP" : "DOWN")
          valueColor: modelData.activating ? root.dim : (up ? root.foreground : Qt.darker(root.dim, 1.1))
          muted: !up
          hint: modelData.activating ? "Connecting…"
            : (up ? "Disconnect " + modelData.name : "Connect " + modelData.name)

          TapHandler {
            onTapped: root.toggleVpn(modelData)
          }
        }
      }
    }
  }

  component ContainersBody: Item {
    id: containersBody

    readonly property var dock: root.containers
    readonly property var rows: dock && dock.rows ? dock.rows : []
    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(containersBody) - Style.space(34)) / Style.space(20)), 1, 8)

    // Docker missing, daemon down, socket locked: each is its own message, and
    // none of them is "0 containers".
    CardEmpty {
      text: root.containersError !== "" ? root.containersError : "Docker unavailable"
      sub: "Card waits for a reachable daemon"
      visible: containersBody.dock === null
      width: parent.width
      y: (parent.height - height) / 2
    }

    CardEmpty {
      text: "No containers"
      sub: "Nothing created on this host"
      visible: containersBody.dock !== null && containersBody.rows.length === 0
      width: parent.width
      y: (parent.height - height) / 2
    }

    Item {
      id: containersContent
      visible: containersBody.dock !== null && containersBody.rows.length > 0
      width: parent.width
      height: parent.height

      CardStat {
        id: containerStat
        value: (containersBody.dock ? containersBody.dock.running : 0) + ""
        suffix: "/" + (containersBody.dock ? containersBody.dock.total : 0)
        caption: "RUNNING"
        anchors.top: parent.top
        width: parent.width
        y: 0
      }

      Column {
        id: containerList
        width: parent.width
        anchors.top: containerStat.bottom
        anchors.topMargin: Style.space(6)
        spacing: Style.space(2)
        clip: true
        height: Math.min(implicitHeight, parent.height - y - Style.space(2))

        Repeater {
          model: containersBody.rows.slice(0, containersBody.maxShown)

          CardRow {
            required property var modelData
            readonly property bool up: modelData.running
            label: modelData.name
            value: up ? "UP" : (modelData.state === "exited" ? "EXIT" : modelData.state.toUpperCase())
            valueColor: up ? root.foreground : root.dim
            muted: !up
          }
        }
      }
    }
  }

  component ReposBody: Item {
    id: reposBody

    readonly property var rows: root.repos || []
    readonly property int configured: root.repoPaths.length
    readonly property int maxShown: root.clamp(
      Math.floor((root.bodyHeight(reposBody) - Style.space(10)) / Style.space(20)), 1, 10)

    CardEmpty {
      text: reposBody.configured === 0 ? "No repos" : "No repo yet"
      sub: reposBody.configured === 0 ? "Add paths in Settings" : "First check still running"
      visible: reposBody.rows.length === 0
      width: parent.width
      y: (parent.height - height) / 2
    }

    Column {
      visible: reposBody.rows.length > 0
      width: parent.width
      anchors.top: parent.top
      spacing: Style.space(2)
      clip: true
      height: parent.height

      Repeater {
        model: reposBody.rows.slice(0, reposBody.maxShown)

        CardRow {
          required property var modelData
          readonly property bool behind: modelData.behind > 0
          readonly property bool ahead: modelData.ahead > 0
          readonly property bool edited: modelData.changed + modelData.untracked > 0
          label: modelData.error !== "" ? modelData.name : (modelData.branch || modelData.name)
          value: modelData.error !== "" ? modelData.error
            : (behind ? "↓" + modelData.behind : (ahead ? "↑" + modelData.ahead
            : (modelData.untracked > 0 ? "+" + modelData.untracked
            : (modelData.changed > 0 ? "✎" + modelData.changed : "✓"))))
          valueColor: modelData.error !== "" ? root.dim : (behind ? root.urgent : root.foreground)
          muted: !modelData.dirty
          glyph: modelData.name.substring(0, 1).toUpperCase()
        }
      }
    }
  }

  // The three pieces every new card is built from, so a card body is layout
  // and nothing else: no card redraws its own empty state or row metrics.
  // None of them anchor themselves: a card body may be a Column, and anchors
  // inside a positioner are a QML error, so centring is the caller's job.
  component CardEmpty: Column {
    id: cardEmpty
    property string text: ""
    property string sub: ""

    spacing: Style.space(3)
    width: parent ? parent.width : 0

    Text {
      id: emptyText
      textFormat: Text.PlainText
      text: cardEmpty.text
      visible: text !== ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      text: cardEmpty.sub
      visible: text !== ""
      color: Qt.darker(root.dim, 1.25)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
    }
  }

  // A dot, a name, and a value on the right. The dot is the only place colour
  // is spent, so a card's status reads at a glance without a colour key.
  component CardRow: Item {
    id: cardRow
    property string glyph: ""
    property string label: ""
    property string value: ""
    property string hint: ""
    property color valueColor: root.foreground
    property bool muted: false
    property real dotSize: 5

    width: parent ? parent.width : 0
    height: Style.space(18)

    readonly property bool usesDot: glyph === "" || glyph === "•"
    readonly property real leftEdge: usesDot ? dot.width + Style.space(6) : glyphText.width + Style.space(6)

    Rectangle {
      id: dot
      width: cardRow.dotSize
      height: width
      radius: width / 2
      color: cardRow.valueColor
      visible: cardRow.usesDot
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      opacity: cardRow.muted ? 0.35 : 1
    }

    Text {
      id: glyphText
      textFormat: Text.PlainText
      text: cardRow.usesDot ? "" : cardRow.glyph
      visible: text !== ""
      color: cardRow.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: cardRow.label
      color: cardRow.muted ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.leftMargin: cardRow.leftEdge
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideLeft
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      text: cardRow.value
      color: cardRow.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    PanelToolTip {
      visible: cardRow.hint !== "" && hintHover.containsMouse
      text: cardRow.hint
      fontFamily: root.fontFamily
    }

    HoverHandler {
      id: hintHover
      enabled: cardRow.hint !== ""
    }
  }

  // A number worth being large, with a caption under it.
  component CardStat: Column {
    id: cardStat
    property string value: ""
    property string caption: ""
    property string suffix: ""
    property color valueColor: root.foreground
    property int pixelSize: Style.font.heading

    spacing: Style.space(1)
    width: parent ? parent.width : 0

    Text {
      textFormat: Text.PlainText
      text: cardStat.value + cardStat.suffix
      visible: text !== ""
      color: cardStat.valueColor
      font.family: root.fontFamily
      font.pixelSize: cardStat.pixelSize
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      text: cardStat.caption
      visible: text !== ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
    }
  }

  component SysMeterRow: Item {
    id: sysRow
    property string label: ""
    property real percent: 0
    property string sub: ""

    width: parent.width
    height: Style.space(17)

    Text {
      textFormat: Text.PlainText
      text: sysRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      width: Style.space(42)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Meter {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(46)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(38)
      anchors.verticalCenter: parent.verticalCenter
      value: root.clamp(sysRow.percent / 100, 0, 1)
      alarming: sysRow.percent >= 90
    }

    Text {
      textFormat: Text.PlainText
      text: sysRow.sub !== "" ? sysRow.sub : Math.round(sysRow.percent) + "%"
      color: sysRow.percent >= 90 ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}