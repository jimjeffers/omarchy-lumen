import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Lumen in the Omarchy bar: monitor settings over DDC/CI. Which controls a
// monitor has comes from its lumen profile (picture modes, backlights, …);
// models without one get the standard controls and a note on adding them.
// All monitor work goes through the `lumen` command (lumen state / lumen
// set), which owns the DDC queueing and the safeguard that turns a hub
// monitor back on.
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
  property bool outdated: false
  property string contributeUrl: ""
  // Which monitor the controls edit: "all" or a serial. Remembered across
  // restarts in the shell's state folder, not in shell.json, so picking a
  // monitor never rewrites the user's config.
  property string selection: "all"
  readonly property string activeSelection: Model.resolveSelection(monitors, selection)
  readonly property string stateDirectory: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/lumen"

  readonly property var groupList: Model.groups(monitors, selection)
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

  function control(monitor, id) { return Model.control(monitor, id) }

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
    outdated = parsed.outdated
    if (parsed.contribute !== "") contributeUrl = parsed.contribute
    if (parsed.monitors.length > 0 || parsed.error !== "") {
      monitors = parsed.monitors
      error = parsed.error
    }
    loaded = true
    clampCursor()
  }

  function targetLabel(t) {
    if (t.position === "all") return strings.t("all", "All monitors")
    if (t.position === "left") return strings.t("left", "Left monitor")
    if (t.position === "right") return strings.t("right", "Right monitor")
    return strings.t("numbered", "Monitor %1").arg(t.index + 1)
  }

  function targetOptions() {
    var list = Model.targets(monitors)
    var out = []
    for (var i = 0; i < list.length; i++) out.push({ value: list[i].value, label: targetLabel(list[i]) })
    return out
  }

  function select(value) {
    selection = value === "" ? "all" : value
    selectionFile.setText(selection + "\n")
  }

  // Standard controls get translated labels; a profile's own controls keep
  // the label the profile gives them.
  function controlLabel(c) {
    var known = { brightness: "Brightness", contrast: "Contrast", volume: "Speaker volume",
                  mode: "Picture mode", temp: "Color temperature" }
    return known[c.id] !== undefined ? strings.t(c.id, known[c.id]) : c.label
  }

  function unsupportedText(models) {
    return strings.t("unsupported", "%1 has no Lumen profile yet, so only standard controls are shown. Add one so everyone with this monitor gets its full controls.")
      .arg(models.join(", "))
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
    var c = control(groupList[row.group].monitor, row.setting)
    if (!c) return 0
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
      var l = control(g.monitor, r.setting)
      if (l) change(g.target, r.setting, Model.clamp(l.value + dx * 5, 0, l.max))
    } else if (r.kind === "toggle") {
      toggleControl(r)
    } else if (r.kind === "pills") {
      cursorCol = Math.max(0, Math.min(r.count - 1, cursorCol + dx))
    }
  }

  function activateCursor() {
    var r = rowList[cursorRow]
    if (!r) return
    if (r.kind === "target") {
      var picker = panel.loadedContent ? panel.loadedContent.targetPicker : null
      if (picker) picker.open()
      return
    }
    if (r.kind === "toggle") { toggleControl(r); return }
    if (r.kind === "pills") {
      var g = groupList[r.group]
      var c = control(g.monitor, r.setting)
      var option = c ? c.options[cursorCol] : null
      if (option) change(g.target, r.setting, option.value)
    }
  }

  function toggleControl(row) {
    var g = groupList[row.group]
    var c = control(g.monitor, row.setting)
    if (!c || c.options.length < 2) return
    change(g.target, row.setting, Model.toggleOn(c) ? c.options[1].value : c.options[0].value)
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
    if (outdated) return strings.t("outdated", "This panel needs lumen 0.3 or newer. Update the lumen app.")
    if (!loaded) return strings.t("reading", "Reading settings…")
    if (monitors.length === 0) return strings.t("noMonitors", "No monitors with DDC/CI found")
    var m = groupList.length > 0 ? groupList[0].monitor : monitors[0]
    var mode = Model.prettyLabel(Model.currentLabel(control(m, "mode")))
    var brightness = control(m, "brightness")
    var parts = []
    if (mode !== "") parts.push(mode)
    if (brightness && brightness.value >= 0) parts.push(Commons.I18n.formatNumber(brightness.value) + "%")
    return parts.join(" · ").toUpperCase()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: percent }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    // The saved selection lives here; made early so the first save lands.
    Quickshell.execDetached(["mkdir", "-p", stateDirectory])
    refresh()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorRow = 0
      cursorCol = 0
    } else if (panel.loadedContent) {
      // The monitor menu is a popup of its own; close it with the panel.
      panel.loadedContent.targetPicker.close()
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

  FileView {
    id: selectionFile
    path: root.stateDirectory + "/bar-selection"
    atomicWrites: true
    printErrors: false
    // Every bar has its own copy of this panel; watching the file keeps
    // them on the same monitor.
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var saved = String(text() || "").trim()
      root.selection = saved === "" ? "all" : saved.slice(0, 64)
    }
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
    // Scrolling on the icon nudges brightness of whatever the panel edits
    // (every monitor, or the selected one).
    onWheelMoved: function(delta) {
      if (root.groupList.length === 0) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var g = root.groupList[0]
      var l = root.control(g.monitor, "brightness")
      if (!l || l.value < 0) return
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
      property alias targetPicker: targetPicker
      blocked: targetPicker.popupOpen
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
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, targetPicker.visible ? targetPicker.implicitHeight : 0)

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
              anchors.right: targetPicker.visible ? targetPicker.left : parent.right
              anchors.rightMargin: targetPicker.visible ? Style.space(12) : 0
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
                color: root.error !== "" || root.outdated ? Commons.Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: root.error !== "" ? 0 : 1.2
                wrapMode: root.error !== "" ? Text.Wrap : Text.NoWrap
                elide: root.error !== "" ? Text.ElideNone : Text.ElideRight
                width: parent.width
              }
            }

            // Which monitor the controls edit, remembered between sessions.
            // Only shown when there is more than one monitor.
            MonitorPicker {
              id: targetPicker
              visible: root.monitors.length > 1
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              options: root.targetOptions()
              value: root.activeSelection
              hasCursor: root.isCursor("target", undefined, -1)
              onPicked: function(v) { root.select(v) }
              onHovered: function(h) { if (h) root.setCursor("target", undefined, -1) }
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(targetPicker)
            }
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

              Text {
                textFormat: Text.PlainText
                visible: section.monitor.error !== ""
                text: section.monitor.error
                color: Commons.Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: parent.width
              }

              // A monitor without a profile: say so, and point at how to add one.
              Column {
                id: unsupportedNote
                readonly property var models: Model.unsupportedModels(root.monitors, section.group)
                visible: models.length > 0
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.unsupportedText(unsupportedNote.models)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  width: parent.width
                }

                Button {
                  visible: root.contributeUrl !== ""
                  text: strings.t("contribute", "How to add your monitor")
                  iconText: "󰈈"
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: {
                    root.close()
                    Qt.openUrlExternally(root.contributeUrl)
                  }
                }
              }

              // The monitor's controls, in its profile's order.
              Repeater {
                model: Model.panelControls(section.monitor)

                Loader {
                  required property var modelData
                  width: section.width
                  sourceComponent: modelData.type === "slider" ? sliderComponent
                    : modelData.type === "toggle" ? toggleComponent
                    : pillsComponent

                  Component {
                    id: sliderComponent
                    SliderRow { control: modelData; group: section.group; groupIndex: section.index }
                  }
                  Component {
                    id: pillsComponent
                    PillRow { control: modelData; group: section.group; groupIndex: section.index }
                  }
                  Component {
                    id: toggleComponent
                    ToggleRow { control: modelData; group: section.group; groupIndex: section.index }
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Footer: launch the full app.
          Item {
            width: parent.width
            implicitHeight: openButton.implicitHeight

            Button {
              id: openButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
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
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // A labelled slider for one continuous setting.
  component SliderRow: Column {
    id: sliderRow
    required property var control
    required property var group
    required property int groupIndex
    readonly property string setting: control.id
    readonly property var level: control

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(sliderHeader.implicitHeight, sliderValue.implicitHeight)
      PanelSectionHeader {
        id: sliderHeader
        text: root.controlLabel(sliderRow.control)
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
    required property var control
    required property var group
    required property int groupIndex
    readonly property string setting: control.id
    readonly property var choice: control
    readonly property int columns: Math.min(3, choice.options.length)

    spacing: Style.space(8)

    PanelSectionHeader {
      text: root.controlLabel(pillRow.control)
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

  // An on/off setting, such as a backlight: label and switch on one line.
  // The profile's note hides behind an info icon, shown on hover.
  component ToggleRow: CursorSurface {
    id: toggleRow
    required property var control
    required property var group
    required property int groupIndex

    implicitHeight: Math.max(toggleLabel.implicitHeight, toggleSwitch.implicitHeight) + Style.spacing.controlGap
    hasCursor: root.isCursor("toggle", control.id, groupIndex)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(toggleRow)
    foreground: root.foreground
    outline: true

    // The whole row toggles; the info icon above it only shows its tooltip.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("toggle", toggleRow.control.id, toggleRow.groupIndex)
      onClicked: root.toggleControl({ group: toggleRow.groupIndex, setting: toggleRow.control.id })
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      PanelSectionHeader {
        id: toggleLabel
        text: root.controlLabel(toggleRow.control)
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: toggleRow.control.note !== ""
        textFormat: Text.PlainText
        text: "󰋽"
        color: infoMouse.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          id: infoMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
        }

        PanelToolTip {
          visible: infoMouse.containsMouse
          text: toggleRow.control.note
          fontFamily: root.fontFamily
          width: Math.min(implicitWidth, Style.space(260))
        }
      }
    }

    ToggleSwitch {
      id: toggleSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      checked: Model.toggleOn(toggleRow.control)
      interactive: false
      foreground: root.foreground
      accent: Commons.Color.accent
    }
  }

  // Chooses which monitor the controls edit: a button showing the current
  // choice, with a menu below it.
  component MonitorPicker: Item {
    id: picker
    property var options: []
    property string value: "all"
    property bool hasCursor: false
    property int menuIndex: 0
    readonly property bool popupOpen: menu.opened

    signal picked(string value)
    signal hovered(bool isHovered)

    function open() { menu.open() }
    function close() { menu.close() }

    function indexOfValue() {
      for (var i = 0; i < options.length; i++) if (options[i].value === value) return i
      return 0
    }
    function currentLabel() {
      var i = indexOfValue()
      return options.length > 0 ? options[i].label : ""
    }
    function choose(i) {
      if (i < 0 || i >= options.length) return
      menu.close()
      picked(options[i].value)
    }

    implicitWidth: trigger.implicitWidth
    implicitHeight: trigger.implicitHeight

    Button {
      id: trigger
      anchors.right: parent.right
      text: picker.currentLabel() + "  󰅀"
      fontSize: Style.font.caption
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      hasCursor: picker.hasCursor
      onClicked: menu.opened ? menu.close() : menu.open()
      onHovered: function(h) { picker.hovered(h) }
    }

    Popup {
      id: menu
      width: Math.max(trigger.width, menuColumn.implicitWidth + leftPadding + rightPadding)
      x: trigger.x + trigger.width - width
      y: trigger.height + Style.spacing.xxs
      padding: Style.spacing.xs
      closePolicy: Popup.CloseOnPressOutsideParent | Popup.CloseOnEscape
      focus: true

      background: BorderSurface {
        color: Commons.Color.popups.background
        borderSpec: Border.localOrSurfaceSpec("popups", "border", Commons.Color.popups.border, Commons.Color.popups.border, Style.normalBorderWidth)
        radius: Style.cornerRadius
      }

      onOpened: {
        picker.menuIndex = picker.indexOfValue()
        menuColumn.forceActiveFocus()
      }

      contentItem: Column {
        id: menuColumn
        spacing: Style.spacing.labelGap
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { menu.close(); event.accepted = true }
          else if (event.key === Qt.Key_Down || event.text === "j") {
            picker.menuIndex = Math.min(picker.options.length - 1, picker.menuIndex + 1); event.accepted = true
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            picker.menuIndex = Math.max(0, picker.menuIndex - 1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            picker.choose(picker.menuIndex); event.accepted = true
          }
        }

        Repeater {
          model: picker.options

          Button {
            required property var modelData
            required property int index
            width: menuColumn.width
            leftAlign: true
            text: modelData.label
            fontSize: Style.font.caption
            foreground: root.foreground
            fontFamily: root.fontFamily
            active: modelData.value === picker.value
            hasCursor: index === picker.menuIndex
            onClicked: picker.choose(index)
            onHovered: function(h) { if (h) picker.menuIndex = index }
          }
        }
      }
    }
  }
}
