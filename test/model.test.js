// Guard tests for the bounded parser every untrusted string in the plugin goes
// through. Run with: node --test
//
// Model.js is a plain JS file that QML imports directly, so it has no exports;
// load it and hand back the function under test instead of adding a test seam
// to shipped plugin code.

const { test } = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const { parseJsonBounded } = new Function(`${source}\nreturn { parseJsonBounded };`)()

const CAP = 64

test("accepts a JSON object under the cap", () => {
  assert.deepStrictEqual(parseJsonBounded('{"races":[]}', CAP), { races: [] })
})

test("accepts an object exactly at the cap", () => {
  const body = JSON.stringify({ a: "x".repeat(CAP - JSON.stringify({ a: "" }).length) })
  assert.strictEqual(body.length, CAP)
  assert.ok(parseJsonBounded(body, CAP))
})

test("rejects a body over the cap without parsing it", () => {
  const body = JSON.stringify({ a: "x".repeat(CAP) })
  assert.ok(body.length > CAP)
  assert.strictEqual(parseJsonBounded(body, CAP), null)
})

test("rejects JSON that is not a plain object", () => {
  for (const body of ["[]", '[{"races":[]}]', "5", '"races"', "null", "true"])
    assert.strictEqual(parseJsonBounded(body, CAP), null, `accepted: ${body}`)
})

test("rejects malformed and empty text", () => {
  for (const body of ["", "   ", "{", "not json", "<html>502</html>"])
    assert.strictEqual(parseJsonBounded(body, CAP), null, `accepted: ${body}`)
})

test("fails closed when the cap is missing or nonsensical", () => {
  const body = '{"races":[]}'
  for (const cap of [undefined, null, 0, -1, NaN, "big"])
    assert.strictEqual(parseJsonBounded(body, cap), null, `accepted with cap ${String(cap)}`)
})
