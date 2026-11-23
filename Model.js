// Pure helpers for the Lumen bar panel. No QML here, so Node can test them
// (tests/model.test.js).

// Parses `lumen state` output into a list of monitors. Bad input gives [].
function parseState(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return { monitors: [], error: "" }
  }
  if (!parsed || typeof parsed !== "object") return { monitors: [], error: "" }
  var list = Array.isArray(parsed.monitors) ? parsed.monitors : []
  var monitors = []
  for (var i = 0; i < list.length && i < 16; i++) {
    var m = list[i]
    if (!m || typeof m !== "object") continue
    monitors.push({
      index: i,
      connector: clip(m.connector, 32),
      serial: clip(m.serial, 64),
      model: clip(m.model, 64),
      ready: m.ready === true,
      error: clip(m.error, 200),
      brightness: level(m.brightness),
      contrast: level(m.contrast),
      volume: level(m.volume),
      temp: choice(m.temp),
      mode: choice(m.mode),
      halo: m.halo ? choice(m.halo) : null,
      haloCode: m.halo && isFinite(m.halo.code) ? Number(m.halo.code) : -1
    })
  }
  return { monitors: monitors, error: clip(parsed.error, 200) }
}

function clip(value, max) {
  return String(value === undefined || value === null ? "" : value).slice(0, max)
}

function level(v) {
  var value = v && isFinite(v.value) ? Number(v.value) : -1
  var max = v && isFinite(v.max) && Number(v.max) > 0 ? Number(v.max) : 100
  return { value: value, max: max }
}

function choice(v) {
  var options = []
  var raw = v && Array.isArray(v.options) ? v.options : []
  for (var i = 0; i < raw.length && i < 32; i++) {
    var o = raw[i]
    if (!o || !isFinite(o.value)) continue
    options.push({ value: Number(o.value), label: clip(o.label, 40) })
  }
  return { value: v && isFinite(v.value) ? Number(v.value) : -1, options: options }
}

// Readable label for an option list's current value, or "".
function currentLabel(c) {
  if (!c) return ""
  for (var i = 0; i < c.options.length; i++)
    if (c.options[i].value === c.value) return c.options[i].label
  return ""
}

// Mode names in the code file use hyphens ("Coding-Dark"); show spaces.
function prettyLabel(label) {
  var s = String(label || "")
  if (/^0x[0-9a-f]+$/i.test(s)) return s
  return s.replace(/-/g, " ")
}

// The groups of controls the panel shows: one for every monitor when
// unlinked, or a single group driving all of them when linked. Values come
// from the first monitor in the group.
function groups(monitors, linked) {
  if (!monitors || monitors.length === 0) return []
  if (linked && monitors.length > 1)
    return [{ target: "all", monitor: monitors[0], position: "all" }]
  var out = []
  for (var i = 0; i < monitors.length; i++) {
    var position = monitors.length === 1 ? "only"
      : i === 0 ? "left" : i === monitors.length - 1 ? "right" : "middle"
    out.push({ target: monitors[i].serial || monitors[i].connector, monitor: monitors[i], position: position })
  }
  return out
}

// Keyboard rows, top to bottom. Each row is one slider or one row of pills.
function rows(groupList, monitorCount) {
  var list = []
  if (monitorCount > 1) list.push({ kind: "link", group: -1 })
  for (var g = 0; g < groupList.length; g++) {
    var m = groupList[g].monitor
    if (m.brightness.value >= 0) list.push({ kind: "slider", setting: "brightness", group: g })
    if (m.contrast.value >= 0) list.push({ kind: "slider", setting: "contrast", group: g })
    if (m.mode.options.length > 0) list.push({ kind: "pills", setting: "mode", group: g, count: m.mode.options.length })
    if (m.temp.options.length > 0) list.push({ kind: "pills", setting: "temp", group: g, count: m.temp.options.length })
    if (m.halo && m.halo.options.length > 0) list.push({ kind: "pills", setting: "halo", group: g, count: m.halo.options.length })
    if (m.volume.value >= 0) list.push({ kind: "slider", setting: "volume", group: g })
  }
  return list
}

function clamp(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  return Math.max(min, Math.min(max, Math.round(n)))
}

// Applies a change locally so the panel reacts before the monitor answers.
// Returns a new monitor list; linked changes reach every monitor that has the
// setting (and, for mode/halo, the same model).
function applyLocal(monitors, target, setting, value) {
  var source = null
  for (var i = 0; i < monitors.length; i++)
    if (target === "all" || monitors[i].serial === target || monitors[i].connector === target) { source = monitors[i]; break }
  var out = []
  for (var j = 0; j < monitors.length; j++) {
    var m = monitors[j]
    var hit = target === "all" ? true : (m.serial === target || m.connector === target)
    if (hit && target === "all" && (setting === "mode" || setting === "halo") && source && m.model !== source.model) hit = false
    if (!hit) { out.push(m); continue }
    var copy = JSON.parse(JSON.stringify(m))
    if (copy[setting] && typeof copy[setting] === "object") copy[setting].value = value
    out.push(copy)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parseState: parseState,
    currentLabel: currentLabel,
    prettyLabel: prettyLabel,
    groups: groups,
    rows: rows,
    clamp: clamp,
    applyLocal: applyLocal
  }
}
