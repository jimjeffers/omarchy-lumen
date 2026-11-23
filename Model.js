// Pure helpers for the Lumen bar panel. No QML here, so Node can test them
// (tests/model.test.js).

// Parses `lumen-ddc state` output (0.3+) into a list of monitors, each
// with the controls its profile gives it. Bad input gives no monitors.
// `outdated` is set when the output comes from an older Lumen without
// profiles.
function parseState(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return { monitors: [], error: "", contribute: "", outdated: false }
  }
  if (!parsed || typeof parsed !== "object") return { monitors: [], error: "", contribute: "", outdated: false }
  var list = Array.isArray(parsed.monitors) ? parsed.monitors : []
  var monitors = []
  var outdated = false
  for (var i = 0; i < list.length && i < 16; i++) {
    var m = list[i]
    if (!m || typeof m !== "object") continue
    if (!Array.isArray(m.controls)) { outdated = true; continue }
    var profile = m.profile && typeof m.profile === "object" ? m.profile : {}
    var controls = []
    for (var c = 0; c < m.controls.length && c < 32; c++) {
      var control = parseControl(m.controls[c])
      if (control) controls.push(control)
    }
    monitors.push({
      index: i,
      connector: clip(m.connector, 32),
      serial: clip(m.serial, 64),
      make: clip(m.make, 16),
      model: clip(m.model, 64),
      ready: m.ready === true,
      error: clip(m.error, 200),
      profile: { id: clip(profile.id, 64), name: clip(profile.name, 64), supported: profile.supported === true },
      controls: controls
    })
  }
  return { monitors: monitors, error: clip(parsed.error, 200), contribute: safeUrl(parsed.contribute), outdated: outdated }
}

function parseControl(c) {
  if (!c || typeof c !== "object") return null
  var type = c.type === "slider" || c.type === "choice" || c.type === "toggle" ? c.type : ""
  var id = clip(c.id, 32)
  if (type === "" || id === "") return null
  var options = []
  var raw = Array.isArray(c.options) ? c.options : []
  for (var i = 0; i < raw.length && i < 32; i++) {
    var o = raw[i]
    if (!o || !isFinite(o.value)) continue
    options.push({ value: Number(o.value), label: clip(o.label, 40) })
  }
  return {
    id: id,
    label: clip(c.label, 40) || id,
    type: type,
    value: isFinite(c.value) ? Number(c.value) : -1,
    max: isFinite(c.max) && Number(c.max) > 0 ? Number(c.max) : 100,
    options: options,
    panel: c.panel !== false,
    note: clip(c.note, 200)
  }
}

// Only https links are opened from the panel.
function safeUrl(value) {
  var s = clip(value, 300)
  return /^https:\/\/[^\s]+$/.test(s) ? s : ""
}

function clip(value, max) {
  return String(value === undefined || value === null ? "" : value).slice(0, max)
}

// A monitor's control by id, or null.
function control(monitor, id) {
  if (!monitor || !monitor.controls) return null
  for (var i = 0; i < monitor.controls.length; i++)
    if (monitor.controls[i].id === id) return monitor.controls[i]
  return null
}

// The controls the bar panel shows for a monitor, in profile order.
function panelControls(monitor) {
  var out = []
  if (!monitor || !monitor.controls) return out
  for (var i = 0; i < monitor.controls.length; i++) {
    var c = monitor.controls[i]
    if (!c.panel) continue
    if (c.type === "slider" && c.value < 0) continue
    if (c.type !== "slider" && c.options.length === 0) continue
    out.push(c)
  }
  return out
}

// For a toggle: whether it's on (its first option is "on").
function toggleOn(c) {
  return !!c && c.options.length > 0 && c.value === c.options[0].value
}

// Readable label for an option list's current value, or "".
function currentLabel(c) {
  if (!c) return ""
  for (var i = 0; i < c.options.length; i++)
    if (c.options[i].value === c.value) return c.options[i].label
  return ""
}

// Some labels use hyphens ("Coding-Dark"); show spaces.
function prettyLabel(label) {
  var s = String(label || "")
  if (/^0x[0-9a-f]+$/i.test(s)) return s
  return s.replace(/-/g, " ")
}

// Where each monitor sits, left to right as Hyprland arranges them.
function position(index, count) {
  if (count === 1) return "only"
  if (index === 0) return "left"
  if (index === count - 1) return "right"
  return "middle"
}

// The monitor the panel is editing: "all", or a serial that is connected.
// Anything else (a monitor that was unplugged, a garbled saved value) falls
// back to "all".
function resolveSelection(monitors, selection) {
  var s = String(selection || "all")
  for (var i = 0; i < (monitors || []).length; i++)
    if (s !== "" && monitors[i].serial === s) return s
  return "all"
}

// The single group of controls the panel shows: every monitor at once, or
// the selected one. Values come from that monitor (the first one for "all").
// A lone monitor is targeted by serial, so changes never fan out.
function groups(monitors, selection) {
  if (!monitors || monitors.length === 0) return []
  var s = resolveSelection(monitors, selection)
  if (monitors.length === 1)
    return [{ target: monitors[0].serial || monitors[0].connector, monitor: monitors[0], position: "only" }]
  if (s === "all") return [{ target: "all", monitor: monitors[0], position: "all" }]
  for (var i = 0; i < monitors.length; i++)
    if (monitors[i].serial === s)
      return [{ target: s, monitor: monitors[i], position: position(i, monitors.length) }]
  return []
}

// Choices for the monitor picker: "all" first, then each monitor by where it
// sits. Labels are keys the panel translates.
function targets(monitors) {
  var list = [{ value: "all", position: "all", index: -1 }]
  for (var i = 0; i < (monitors || []).length; i++)
    if (monitors[i].serial !== "")
      list.push({ value: monitors[i].serial, position: position(i, monitors.length), index: i })
  return list
}

// Keyboard rows, top to bottom: the monitor picker (only when there is more
// than one monitor), then one row per control the panel shows.
function rows(groupList, monitorCount) {
  var list = []
  if (monitorCount > 1) list.push({ kind: "target", group: -1 })
  for (var g = 0; g < groupList.length; g++) {
    var controls = panelControls(groupList[g].monitor)
    for (var i = 0; i < controls.length; i++) {
      var c = controls[i]
      if (c.type === "slider") list.push({ kind: "slider", setting: c.id, group: g })
      else if (c.type === "toggle") list.push({ kind: "toggle", setting: c.id, group: g })
      else list.push({ kind: "pills", setting: c.id, group: g, count: c.options.length })
    }
  }
  return list
}

// Models in a group that have no profile yet, for the "add your monitor" note.
function unsupportedModels(monitors, group) {
  var out = []
  if (!group) return out
  var list = group.target === "all" ? monitors : [group.monitor]
  for (var i = 0; i < list.length; i++)
    if (!list[i].profile.supported && out.indexOf(list[i].model) < 0) out.push(list[i].model)
  return out
}

function clamp(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  return Math.max(min, Math.min(max, Math.round(n)))
}

// Applies a change locally so the panel reacts before the monitor answers,
// following the same rules as lumen-ddc: "all" reaches every monitor with the
// control, but choices and toggles only reach monitors with the same profile.
// Returns a new monitor list.
function applyLocal(monitors, target, id, value) {
  var source = null
  for (var i = 0; i < monitors.length; i++)
    if (target === "all" || monitors[i].serial === target || monitors[i].connector === target) { source = monitors[i]; break }
  var sourceControl = control(source, id)
  var out = []
  for (var j = 0; j < monitors.length; j++) {
    var m = monitors[j]
    var c = control(m, id)
    var hit = !!c && (target === "all" || m.serial === target || m.connector === target)
    if (hit && target === "all" && sourceControl && sourceControl.type !== "slider" && m.profile.id !== source.profile.id) hit = false
    if (!hit) { out.push(m); continue }
    var copy = JSON.parse(JSON.stringify(m))
    var cc = control(copy, id)
    cc.value = cc.type === "slider" ? clamp(value, 0, cc.max) : value
    out.push(copy)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parseState: parseState,
    control: control,
    panelControls: panelControls,
    toggleOn: toggleOn,
    unsupportedModels: unsupportedModels,
    currentLabel: currentLabel,
    prettyLabel: prettyLabel,
    position: position,
    resolveSelection: resolveSelection,
    groups: groups,
    targets: targets,
    rows: rows,
    clamp: clamp,
    applyLocal: applyLocal
  }
}
