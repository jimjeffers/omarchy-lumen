// Run with: node plugin/tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")

const state = JSON.stringify({
  monitors: [
    {
      connector: "DP-2", serial: "AAA", model: "BenQ RD320U", ready: true, error: "",
      brightness: { value: 36, max: 100 }, contrast: { value: 50, max: 100 }, volume: { value: 30, max: 50 },
      temp: { value: 11, options: [{ value: 5, label: "6500K" }, { value: 11, label: "User 1" }] },
      mode: { value: 48, options: [{ value: 48, label: "Coding-Dark" }, { value: 10, label: "sRGB" }] }
    },
    {
      connector: "DP-8", serial: "BBB", model: "BenQ RD320U", ready: true, error: "",
      brightness: { value: 20, max: 100 }, contrast: { value: 50, max: 100 }, volume: { value: -1, max: 100 },
      temp: { value: 11, options: [] }, mode: { value: 48, options: [{ value: 48, label: "Coding-Dark" }] }
    }
  ]
})

let tests = 0
function test(name, fn) { fn(); tests++ }

test("parses lumen state", () => {
  const s = M.parseState(state)
  assert.strictEqual(s.monitors.length, 2)
  assert.strictEqual(s.monitors[0].brightness.value, 36)
  assert.strictEqual(s.monitors[0].volume.max, 50)
  assert.strictEqual(s.monitors[1].volume.value, -1)
  assert.strictEqual(M.currentLabel(s.monitors[0].mode), "Coding-Dark")
})

test("survives garbage and huge input", () => {
  assert.deepStrictEqual(M.parseState("not json").monitors, [])
  assert.deepStrictEqual(M.parseState("null").monitors, [])
  const big = { monitors: Array.from({ length: 100 }, () => ({ model: "x".repeat(1000) })) }
  const s = M.parseState(JSON.stringify(big))
  assert.strictEqual(s.monitors.length, 16)
  assert.strictEqual(s.monitors[0].model.length, 64)
})

test("keeps markup-shaped text as plain data", () => {
  const s = M.parseState(JSON.stringify({ monitors: [{ model: "<img src='https://example.invalid/x'>", mode: { value: 1, options: [{ value: 1, label: "<b>x</b>" }] } }] }))
  assert.strictEqual(s.monitors[0].model.startsWith("<img"), true)  // shown via Text.PlainText
  assert.strictEqual(M.currentLabel(s.monitors[0].mode), "<b>x</b>")
})

test("pretty labels swap hyphens but keep hex", () => {
  assert.strictEqual(M.prettyLabel("Coding-Dark"), "Coding Dark")
  assert.strictEqual(M.prettyLabel("0x30"), "0x30")
})

test("linked shows one group, unlinked one per monitor", () => {
  const ms = M.parseState(state).monitors
  assert.deepStrictEqual(M.groups(ms, true).map(g => g.target), ["all"])
  assert.deepStrictEqual(M.groups(ms, false).map(g => g.position), ["left", "right"])
  assert.deepStrictEqual(M.groups([ms[0]], true).map(g => g.position), ["only"])
})

test("rows skip settings a monitor lacks", () => {
  const ms = M.parseState(state).monitors
  const unlinked = M.rows(M.groups(ms, false), 2)
  assert.strictEqual(unlinked[0].kind, "link")
  const second = unlinked.filter(r => r.group === 1).map(r => r.setting)
  assert.deepStrictEqual(second, ["brightness", "contrast", "mode"])
})

test("local changes follow linking", () => {
  const ms = M.parseState(state).monitors
  const all = M.applyLocal(ms, "all", "brightness", 70)
  assert.deepStrictEqual(all.map(m => m.brightness.value), [70, 70])
  const one = M.applyLocal(ms, "BBB", "brightness", 10)
  assert.deepStrictEqual(one.map(m => m.brightness.value), [36, 10])
  assert.strictEqual(ms[0].brightness.value, 36)  // original untouched
})

test("clamp", () => {
  assert.strictEqual(M.clamp(140, 0, 100), 100)
  assert.strictEqual(M.clamp("x", 0, 100), 0)
})

console.log(`${tests} tests passed`)
