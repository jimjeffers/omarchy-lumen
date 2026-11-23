import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Lumen in the Omarchy bar: brightness, contrast, picture mode, color
// temperature and volume for external monitors over DDC/CI. All monitor work
// goes through the `lumen` command (lumen state / lumen set), which owns the
// DDC queueing and the safeguard that turns a hub monitor back on.
Panel {
  id: root
  moduleName: "io.github.jimjeffers.lumen"
  ipcTarget: "lumen"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string lumen: {
    var path = String(setting("lumenPath", "") || "")
    return path !== "" ? path : "lumen"
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var monitors: []
  property string error: ""
  property bool loaded: false
  property bool linked: setting("linked", true) !== false

  readonly property var groupList: Model.groups(monitors, linked)
  readonly property var rowList: Model.rows(groupList, monitors.length)

  // Keyboard cursor, shared with hover like the stock panels.
  property int cursorRow: 0
  property int cursorCol: 0
  property bool cursorActive: false

  property real wheelAccumulator: 0

  // Pending `lumen set` calls, one at a time; a newer value for the same
  // setting replaces an older queued one.
  property var queue: []
  property var sliderPending: null

  function refresh() {
    if (!stateProc.running && !setProc.running && queue.length === 0) stateProc.running = true
  }

  function change(target, setting, value) {
    monitors = Model.applyLocal(monitors, target, setting, value)
    var q = []
    for (var i = 0; i < queue.length; i++)
      if (!(queue[i].target === target && queue[i].setting === setting)) q.push(queue[i])
    q.push({ target: target, setting: setting, value: value })
    queue = q
    pump()
  }

  function pump() {
    if (setProc.running || queue.length === 0) return
    var job = queue[0]
    queue = queue.slice(1)
    setProc.command = [root.lumen, "set", job.target, job.setting, String(job.value)]
    setProc.running = true
  }

  // Slider drags update the panel at once and reach the monitor after a
  // short pause, so a drag sends a handful of writes rather than dozens.
  function previewSlider(target, setting, value) {
    monitors = Model.applyLocal(monitors, target, setting, value)
    sliderPending = { target: target, setting: setting, value: value }
    sliderDebounce.restart()
  }

  function commitSlider(target, setting, value) {
    sliderDebounce.stop()
    sliderPending = null
    change(target, setting, value)
  }

  function applyState(text) {
    var parsed = Model.parseState(text)
    if (parsed.monitors.length > 0 || parsed.error !== "") {
      monitors = parsed.monitors
      error = parsed.error
    }
    loaded = true
    clampCursor()
  }

  function positionLabel(position, model) {
    if (position === "all") return strings.t("all", "All monitors")
    if (position === "left") return strings.t("left", "Left") + " · " + model
    if (position === "right") return strings.t("right", "Right") + " · " + model
    if (position === "middle") return strings.t("middle", "Middle") + " · " + model
    return model
  }

  function settingLabel(setting) {
    if (setting === "brightness") return strings.t("brightness", "Brightness")
    if (setting === "contrast") return strings.t("contrast", "Contrast")
    if (setting === "volume") return strings.t("volume", "Speaker volume")
    if (setting === "mode") return strings.t("mode", "Picture mode")
    if (setting === "temp") return strings.t("temp", "Color temperature")
    if (setting === "halo") return strings.t("halo", "Backlight")
    return setting
  }

  // ---- keyboard cursor ----
  function isCursor(kind, setting, group) {
    if (!cursorActive) return false
    var r = rowList[cursorRow]
    return r !== undefined && r.kind === kind && r.setting === setting && r.group === group
  }

  function setCursor(kind, setting, group, col) {
    for (var i = 0; i < rowList.length; i++) {
      var r = rowList[i]
      if (r.kind === kind && r.setting === setting && r.group === group) {
        cursorActive = true
        cursorRow = i
        cursorCol = col === undefined ? 0 : col
        return
      }
    }
  }

  function clampCursor() {
    if (cursorRow > rowList.length - 1) cursorRow = Math.max(0, rowList.length - 1)
    var r = rowList[cursorRow]
    if (r && r.kind === "pills" && cursorCol > r.count - 1) cursorCol = r.count - 1
  }

  function pillIndexOfCurrent(row) {
    var c = groupList[row.group].monitor[row.setting]
    for (var i = 0; i < c.options.length; i++)
      if (c.options[i].value === c.value) return i
    return 0
  }

  function moveCursor(dx, dy) {
    if (rowList.length === 0) return
    if (dy !== 0) {
      cursorRow = Math.max(0, Math.min(rowList.length - 1, cursorRow + dy))
      var next = rowList[cursorRow]
      cursorCol = next.kind === "pills" ? pillIndexOfCurrent(next) : 0
      return
    }
    var r = rowList[cursorRow]
    if (!r) return
    if (r.kind === "slider") {
      var g = groupList[r.group]
      var l = g.monitor[r.setting]
      change(g.target, r.setting, Model.clamp(l.value + dx * 5, 0, l.max))
    } else if (r.kind === "pills") {
      cursorCol = Math.max(0, Math.min(r.count - 1, cursorCol + dx))
    }
  }

  function activateCursor() {
    var r = rowList[cursorRow]
    if (!r) return
    if (r.kind === "link") { linked = !linked; return }
    if (r.kind === "pills") {
      var g = groupList[r.group]
      var option = g.monitor[r.setting].options[cursorCol]
      if (option) change(g.target, r.setting, option.value)
    }
  }

  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var margin = 6
    if (pt.y < flick.contentY + margin) flick.contentY = Math.max(0, pt.y - margin)
    else if (pt.y + item.height > flick.contentY + flick.height - margin)
      flick.contentY = pt.y + item.height + margin - flick.height
  }

  function heroStatus() {
    if (error !== "") return error
    if (!loaded) return strings.t("reading", "Reading settings…")
    if (monitors.length === 0) return strings.t("noMonitors", "No monitors with DDC/CI found")
    var m = monitors[0]
    var mode = Model.prettyLabel(Model.currentLabel(m.mode))
    var parts = []
    if (mode !== "") parts.push(mode)
    if (m.brightness.value >= 0) parts.push(Commons.I18n.formatNumber(m.brightness.value) + "%")
    return parts.join(" · ").toUpperCase()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: percent }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorRow = rowList.length > 1 && rowList[0].kind === "link" ? 1 : 0
      cursorCol = 0
    }
  }
  onRowListChanged: clampCursor()

  // Picks up changes made elsewhere (the monitor's own buttons, the Lumen
  // window) while the panel is open.
  Timer {
    interval: 8000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: sliderDebounce
    interval: 220
    onTriggered: if (root.sliderPending)
      root.change(root.sliderPending.target, root.sliderPending.setting, root.sliderPending.value)
  }

  Process {
    id: stateProc
    command: [root.lumen, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "" && root.monitors.length === 0)
        root.error = String(text).trim().split("\n")[0].slice(0, 200)
    }
    onExited: function(code) {
      if (code !== 0 && root.monitors.length === 0 && root.error === "")
        root.error = strings.t("missing", "Could not run lumen. Install it from the lumen project with bin/install.")
      root.loaded = true
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      // Only trust the monitor's answer once nothing newer is queued, or a
      // slow reply would undo a change the user just made.
      onStreamFinished: if (root.queue.length === 0 && !root.sliderPending) root.applyState(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text).trim()
        root.error = t === "" ? "" : t.split("\n")[0].slice(0, 200)
      }
    }
    onRunningChanged: if (!running) root.pump()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃠"
    onPressed: function(b) { root.toggle() }
    // Scrolling on the icon nudges brightness of every monitor (or the left
    // one when unlinked), like the Display icon does for the focused monitor.
    onWheelMoved: function(delta) {
      if (root.groupList.length === 0) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var g = root.groupList[0]
      var l = g.monitor.brightness
      if (l.value < 0) return
      var value = Model.clamp(l.value + wheel.steps * 5, 0, l.max)
      root.previewSlider(g.target, "brightness", value)
      root.showBrightnessOsd(value)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰃠"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: strings.t("title", "Monitors")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.heroStatus()
                color: root.error !== "" ? Commons.Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: root.error !== "" ? 0 : 1.2
                wrapMode: root.error !== "" ? Text.Wrap : Text.NoWrap
                elide: root.error !== "" ? Text.ElideNone : Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Link ----------
          Toggle {
            id: linkToggle
            visible: root.monitors.length > 1
            width: parent.width
            label: strings.t("link", "Link monitors")
            description: strings.t("linkDescription", "Changes apply to every monitor")
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            checked: root.linked
            hasCursor: root.isCursor("link", undefined, -1)
            onClicked: root.linked = !root.linked
            onHovered: function(h) { if (h) root.setCursor("link", undefined, -1) }
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(linkToggle)
          }

          // ---------- One section per group ----------
          Repeater {
            model: root.groupList

            Column {
              id: section
              required property var modelData
              required property int index
              readonly property var group: modelData
              readonly property var monitor: modelData.monitor
              width: panelColumn.width
              spacing: Style.space(12)

              PanelSeparator { foreground: root.foreground }

              Item {
                width: parent.width
                implicitHeight: sectionHeader.implicitHeight
                PanelSectionHeader {
                  id: sectionHeader
                  text: root.positionLabel(section.group.position, section.monitor.model)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.left: parent.left
                }
                Text {
                  textFormat: Text.PlainText
                  visible: section.monitor.error !== ""
                  text: section.monitor.error
                  color: Commons.Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  width: parent.width / 2
                  horizontalAlignment: Text.AlignRight
                }
              }

              SliderRow { setting: "brightness"; group: section.group; groupIndex: section.index; width: parent.width }
              SliderRow { setting: "contrast"; group: section.group; groupIndex: section.index; width: parent.width }
              PillRow { setting: "mode"; group: section.group; groupIndex: section.index; width: parent.width }
              PillRow { setting: "temp"; group: section.group; groupIndex: section.index; width: parent.width }
              PillRow { setting: "halo"; group: section.group; groupIndex: section.index; width: parent.width }
              SliderRow { setting: "volume"; group: section.group; groupIndex: section.index; width: parent.width }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Button {
            text: strings.t("open", "Open Lumen")
            iconText: "󰍹"
            fontSize: Style.font.caption
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              root.close()
              Quickshell.execDetached(["uwsm-app", "--", root.lumen])
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // A labelled slider for one continuous setting.
  component SliderRow: Column {
    id: sliderRow
    required property string setting
    required property var group
    required property int groupIndex
    readonly property var level: group.monitor[setting]

    visible: level && level.value >= 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(sliderHeader.implicitHeight, sliderValue.implicitHeight)
      PanelSectionHeader {
        id: sliderHeader
        text: root.settingLabel(sliderRow.setting)
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: sliderValue
        textFormat: Text.PlainText
        text: Commons.I18n.formatNumber(Math.round(slider.dragging ? slider.liveValue : sliderRow.level.value))
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    CursorSurface {
      id: sliderSurface
      width: parent.width
      height: slider.implicitHeight + Style.spacing.controlGap
      hasCursor: root.isCursor("slider", sliderRow.setting, sliderRow.groupIndex)
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderSurface)
      foreground: root.foreground
      outline: true

      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: 0
        maximum: sliderRow.level.max
        step: 1
        integer: true
        value: sliderRow.level.value
        onMoved: function(v) { root.previewSlider(sliderRow.group.target, sliderRow.setting, Math.round(v)) }
        onReleased: function(v) { root.commitSlider(sliderRow.group.target, sliderRow.setting, Math.round(v)) }
      }

      HoverHandler {
        onHoveredChanged: if (hovered) root.setCursor("slider", sliderRow.setting, sliderRow.groupIndex)
      }
    }
  }

  // A labelled row of buttons for a setting with fixed values.
  component PillRow: Column {
    id: pillRow
    required property string setting
    required property var group
    required property int groupIndex
    readonly property var choice: group.monitor[setting]
    readonly property int columns: Math.min(3, choice ? choice.options.length : 1)

    visible: choice !== null && choice !== undefined && choice.options.length > 0
    spacing: Style.space(8)

    PanelSectionHeader {
      text: root.settingLabel(pillRow.setting)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Grid {
      id: pillGrid
      width: parent.width
      columns: Math.max(1, pillRow.columns)
      spacing: Style.spacing.xs
      readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

      Repeater {
        model: pillRow.choice ? pillRow.choice.options : []

        Button {
          required property var modelData
          required property int index
          width: pillGrid.cellWidth
          text: Model.prettyLabel(modelData.label)
          fontSize: Style.font.caption
          foreground: root.foreground
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: pillRow.choice.value === modelData.value
          hasCursor: root.isCursor("pills", pillRow.setting, pillRow.groupIndex) && root.cursorCol === index
          onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
          onClicked: root.change(pillRow.group.target, pillRow.setting, modelData.value)
          onHovered: function(h) { if (h) root.setCursor("pills", pillRow.setting, pillRow.groupIndex, index) }
        }
      }
    }
  }
}
