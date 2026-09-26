import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Control Station — bar face.
//
// This entry point only *renders* the cards the user picked for the bar; every
// fetcher, card, and the settings editor live in Panel.qml, which this widget
// loads and drives. One plugin, one data owner, two entry points: switching the
// manifest to BarWidget.qml leaves the module id, the shell.json entry, and
// every running fetch untouched.
BarWidget {
  id: root
  moduleName: "justarieldotcom.control-station"

  // ------------------------------------------------------------- settings
  // Order is display order. A missing setting falls back to the manifest
  // default; an explicit empty array means "icon only". The symbol filter is a
  // subset of the panel's own list, empty meaning "the first two".
  readonly property var barItems: Model.parseBarItems(root.setting("barItems", null))
  readonly property var barSymbols: Model.parseBarSymbols(
    root.setting("barSymbols", ""),
    root.setting("symbols", Model.DEFAULT_SYMBOLS),
    2)

  // ------------------------------------------------------------- live face
  readonly property var panel: panelLoader.item
  readonly property var chips: {
    var out = []
    var panel = panelLoader.item
    if (!panel) return out
    var data = Model.barData(panel)
    for (var i = 0; i < root.barItems.length; i++) {
      var chip = Model.barChip(root.barItems[i], data, { symbols: root.barSymbols })
      if (chip.hasData) out.push(chip)
    }
    return out
  }
  readonly property bool showingChips: !root.vertical && root.chips.length > 0
  readonly property bool alarming: {
    for (var i = 0; i < root.chips.length; i++) {
      if (root.chips[i].urgent) return true
    }
    return false
  }
  readonly property color faceColor: {
    var urgent = root.bar ? root.bar.urgent : Color.urgent
    var normal = root.bar ? root.bar.barForeground : Color.foreground
    return (root.opened || root.alarming) ? urgent : normal
  }
  readonly property string tooltipText: root.chips.length > 0
    ? root.chips.map(function(chip) { return chip.text }).join("   ")
    : "Control Station"

  // ------------------------------------------------------------- panel handoff
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    // The popup needs a live bar-surface Item to place itself against and to
    // find its screen; the whole slot is more accurate than one glyph in it.
    if ("anchorItem" in target) target.anchorItem = root
    // Tells Panel.qml it is hosted, so it drops its own bar button.
    if ("hostWidget" in target) target.hostWidget = root
    // The chips are this file's job, but the IPC handler lives on the panel, so
    // the bar hands them over. That keeps one inspectable entry point for the
    // whole plugin instead of a second target that would collide with it.
    if ("barChipsProvider" in target) target.barChipsProvider = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // needs open/close/opened on the bar-widget root itself.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (!panelLoader.item) return
    if (panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: root.showingChips
    ? Math.max(Style.bar.iconSlot, row.implicitWidth + Style.spaceReal(9) * 2)
    : Style.bar.iconSlot
  implicitHeight: root.vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property real openPanelIndicatorWidth: root.vertical ? 0 : implicitWidth
  readonly property real openPanelIndicatorHeight: root.vertical ? implicitHeight : 0

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: face
    anchors.fill: parent
    bar: root.bar
    // The chips are painted by the Row below, so the built-in label stays empty
    // and the slot keeps its size even when every card is still empty.
    hasVisualContent: true
    labelVisible: false
    text: ""
    tooltipText: root.tooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Item {
      anchors.fill: parent

      Row {
        id: row
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showingChips
        spacing: Style.space(8)

        Repeater {
          model: root.chips

          delegate: Text {
            required property var modelData
            text: modelData.icon !== "" ? modelData.icon + " " + modelData.text : modelData.text
            color: root.faceColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering

            Behavior on color {
              enabled: !root.bar || root.bar.foregroundAnimationEnabled
              ColorAnimation { duration: 160 }
            }
          }
        }
      }

      Item {
        id: glyphCanvas
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        visible: !root.showingChips

        OpticalGlyph {
          anchors.fill: parent
          text: "\uf0e4"
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.bar.iconFont
          color: root.faceColor

          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 160 }
          }
        }
      }
    }
  }
}
