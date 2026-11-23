// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")

const benq = (connector, serial, brightness, volume) => ({
  connector, serial, make: "BNQ", model: "BenQ RD320U", ready: true, error: "",
  profile: { id: "benq-rd320u", name: "BenQ RD320U", supported: true },
  controls: [
    { id: "mode", label: "Picture mode", type: "choice", value: 48, options: [{ value: 48, label: "Coding Dark" }, { value: 10, label: "sRGB" }] },
    { id: "halo", label: "MoonHalo", type: "toggle", value: 33, options: [{ value: 33, label: "On" }, { value: 17, label: "Off" }], note: "Shape is set on the monitor." },
    { id: "brightness", label: "Brightness", type: "slider", value: brightness, max: 100 },
    { id: "volume", label: "Speaker volume", type: "slider", value: volume, max: 50 },
    { id: "temp", label: "Color temperature", type: "choice", value: 5, options: [{ value: 5, label: "6500K" }], panel: false }
  ]
})
const acme = {
  connector: "HDMI-A-1", serial: "CCC", make: "ACM", model: "ACME X1", ready: true, error: "",
  profile: { id: "generic", name: "Standard DDC/CI", supported: false },
  controls: [{ id: "brightness", label: "Brightness", type: "slider", value: 80, max: 100 }]
}
const state = JSON.stringify({
  monitors: [benq("DP-2", "AAA", 36, 30), benq("DP-8", "BBB", 20, -1)],
  contribute: "https://github.com/jimjeffers/lumen/blob/main/docs/adding-a-monitor.md"
})

let tests = 0
function test(name, fn) { fn(); tests++ }

test("parses monitors with their profile controls", () => {
  const s = M.parseState(state)
  assert.strictEqual(s.monitors.length, 2)
  assert.strictEqual(s.outdated, false)
  const m = s.monitors[0]
  assert.strictEqual(m.profile.supported, true)
  assert.strictEqual(M.control(m, "brightness").value, 36)
  assert.strictEqual(M.control(m, "volume").max, 50)
  assert.strictEqual(M.currentLabel(M.control(m, "mode")), "Coding Dark")
  assert.strictEqual(M.toggleOn(M.control(m, "halo")), true)
  assert.strictEqual(M.control(m, "temp").panel, false)
  assert.ok(s.contribute.startsWith("https://"))
})

test("flags output from an older lumen", () => {
  const old = M.parseState(JSON.stringify({ monitors: [{ connector: "DP-2", brightness: { value: 3, max: 100 } }] }))
  assert.strictEqual(old.outdated, true)
  assert.strictEqual(old.monitors.length, 0)
})

test("survives garbage, huge input and odd controls", () => {
  assert.deepStrictEqual(M.parseState("not json").monitors, [])
  assert.deepStrictEqual(M.parseState("null").monitors, [])
  const big = { monitors: Array.from({ length: 100 }, () => ({ model: "x".repeat(1000), controls: [] })) }
  const s = M.parseState(JSON.stringify(big))
  assert.strictEqual(s.monitors.length, 16)
  assert.strictEqual(s.monitors[0].model.length, 64)
  const odd = M.parseState(JSON.stringify({ monitors: [{ controls: [{ id: "x", type: "dial" }, { type: "slider" }, null] }] }))
  assert.strictEqual(odd.monitors[0].controls.length, 0)
})

test("keeps markup as plain data and only opens https links", () => {
  const s = M.parseState(JSON.stringify({ contribute: "javascript:alert(1)", monitors: [{ model: "<img src=x>", controls: [] }] }))
  assert.strictEqual(s.monitors[0].model, "<img src=x>")  // shown via Text.PlainText
  assert.strictEqual(s.contribute, "")
})

test("panel controls follow the profile and skip hidden or empty ones", () => {
  const ms = M.parseState(state).monitors
  assert.deepStrictEqual(M.panelControls(ms[0]).map(c => c.id), ["mode", "halo", "brightness", "volume"])
  assert.deepStrictEqual(M.panelControls(ms[1]).map(c => c.id), ["mode", "halo", "brightness"])
})

test("selection picks all or one monitor, falling back to all", () => {
  const ms = M.parseState(state).monitors
  assert.deepStrictEqual(M.groups(ms, "all").map(g => g.target), ["all"])
  assert.deepStrictEqual(M.groups(ms, "BBB").map(g => [g.target, g.position]), [["BBB", "right"]])
  assert.deepStrictEqual(M.groups(ms, "unplugged").map(g => g.target), ["all"])
  assert.deepStrictEqual(M.groups([ms[0]], "all").map(g => [g.target, g.position]), [["AAA", "only"]])
  assert.deepStrictEqual(M.targets(ms).map(t => [t.value, t.position]), [["all", "all"], ["AAA", "left"], ["BBB", "right"]])
})

test("rows start with the picker and follow the controls", () => {
  const ms = M.parseState(state).monitors
  assert.deepStrictEqual(M.rows(M.groups(ms, "all"), 2).map(r => r.kind + ":" + (r.setting || "")),
    ["target:", "pills:mode", "toggle:halo", "slider:brightness", "slider:volume"])
  assert.deepStrictEqual(M.rows(M.groups([ms[0]], "all"), 1).map(r => r.kind)[0], "pills")
})

test("unsupported models are named for the contribute note", () => {
  const ms = M.parseState(JSON.stringify({ monitors: [benq("DP-2", "AAA", 36, 30), acme] })).monitors
  assert.deepStrictEqual(M.unsupportedModels(ms, M.groups(ms, "all")[0]), ["ACME X1"])
  assert.deepStrictEqual(M.unsupportedModels(ms, M.groups(ms, "AAA")[0]), [])
  assert.deepStrictEqual(M.unsupportedModels(ms, M.groups(ms, "CCC")[0]), ["ACME X1"])
})

test("local changes follow lumen's linking rules", () => {
  const ms = M.parseState(JSON.stringify({ monitors: [benq("DP-2", "AAA", 36, 30), benq("DP-8", "BBB", 20, -1), acme] })).monitors
  const all = M.applyLocal(ms, "all", "brightness", 70)
  assert.deepStrictEqual(all.map(m => M.control(m, "brightness").value), [70, 70, 70])
  const halo = M.applyLocal(ms, "all", "halo", 17)
  assert.deepStrictEqual(halo.slice(0, 2).map(m => M.control(m, "halo").value), [17, 17])
  assert.strictEqual(M.control(halo[2], "halo"), null)
  const one = M.applyLocal(ms, "BBB", "brightness", 500)
  assert.deepStrictEqual(one.map(m => M.control(m, "brightness").value), [36, 100, 80])
  assert.strictEqual(M.control(ms[0], "brightness").value, 36)  // original untouched
})

test("pretty labels and clamp", () => {
  assert.strictEqual(M.prettyLabel("Coding-Dark"), "Coding Dark")
  assert.strictEqual(M.prettyLabel("0x30"), "0x30")
  assert.strictEqual(M.clamp(140, 0, 100), 100)
  assert.strictEqual(M.clamp("x", 0, 100), 0)
})

console.log(`${tests} tests passed`)
