import assert from "node:assert/strict"
import { existsSync } from "node:fs"
import path from "node:path"
import { after, before, test } from "node:test"
import { fileURLToPath } from "node:url"
import { createRendererServer } from "../../vendor/poster_renderer/server.mjs"

const fixture = fileURLToPath(
  new URL("../fixtures/scripts/fake_poster_renderer.mjs", import.meta.url),
)
// Echoes stdin and its arguments, standing in for rsvg-convert.
const fakeConverter = [
  process.execPath,
  "-e",
  "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>process.stdout.write(process.argv.slice(1).join(' ')+'|'+d))",
  "--",
]

let server
let baseUrl

function start(overrides = {}) {
  return new Promise((resolve) => {
    const instance = createRendererServer({
      posterCommand: [process.execPath, fixture],
      posterSupported: true,
      svgCommand: fakeConverter,
      posterTimeoutMs: 2000,
      svgTimeoutMs: 2000,
      maxConcurrentPosters: 2,
      ...overrides,
    })
    instance.listen(0, "127.0.0.1", () => resolve(instance))
  })
}

const job = (title = "Berlin") => ({
  view: { lat: 52.5, lon: 13.4, distance: 5000 },
  size: { width: 10, height: 10, ratio: 1 },
  text: { title },
  output: {
    png: "/etc/passwd",
    pdf: "/etc/shadow",
    widthMm: 300,
    heightMm: 400,
  },
  tilesUrl: "http://169.254.169.254/{z}/{x}/{y}",
})

const postJob = (body, url = baseUrl) =>
  fetch(`${url}/posters`, { method: "POST", body: JSON.stringify(body) })

before(async () => {
  server = await start()
  baseUrl = `http://127.0.0.1:${server.address().port}`
})

after(() => server.close())

test("reports health", async () => {
  const response = await fetch(`${baseUrl}/health`)
  assert.equal(response.status, 200)
  assert.equal((await response.json()).status, "ok")
})

test("renders a poster and returns PNG and PDF as base64", async () => {
  const response = await postJob(job())
  assert.equal(response.status, 200)
  const body = await response.json()
  const rendered = JSON.parse(Buffer.from(body.png, "base64").toString())

  assert.equal(rendered.text.title, "Berlin")
  assert.equal(Buffer.from(body.pdf, "base64").toString(), "PDF:Berlin")
})

test("writes outputs only to its own temp dir and drops a caller tile URL", async () => {
  const body = await (await postJob(job())).json()
  const rendered = JSON.parse(Buffer.from(body.png, "base64").toString())

  assert.notEqual(rendered.output.png, "/etc/passwd")
  assert.notEqual(rendered.output.pdf, "/etc/shadow")
  assert.equal(rendered.tilesUrl, undefined)
  assert.equal(
    existsSync(path.dirname(rendered.output.png)),
    false,
    "temp dir is cleaned up",
  )
})

test("returns the renderer's error output when it fails", async () => {
  const response = await postJob(job("fail"))
  assert.equal(response.status, 500)
  assert.match((await response.json()).error, /renderer exploded/)
})

test("stops a renderer that exceeds the timeout", async () => {
  const quick = await start({ posterTimeoutMs: 200 })
  try {
    const response = await postJob(
      job("hang"),
      `http://127.0.0.1:${quick.address().port}`,
    )
    assert.equal(response.status, 504)
    assert.match((await response.json()).error, /timed out/)
  } finally {
    quick.close()
  }
})

test("rejects a job that is not JSON", async () => {
  const response = await fetch(`${baseUrl}/posters`, {
    method: "POST",
    body: "nope",
  })
  assert.equal(response.status, 400)
})

test("answers 503 for posters where the native binding is unavailable", async () => {
  const unsupported = await start({ posterSupported: false })
  try {
    const response = await postJob(
      job(),
      `http://127.0.0.1:${unsupported.address().port}`,
    )
    assert.equal(response.status, 503)
  } finally {
    unsupported.close()
  }
})

test("converts SVG with the requested size", async () => {
  const response = await fetch(`${baseUrl}/svg?width=1200&height=630`, {
    method: "POST",
    body: "<svg/>",
  })
  assert.equal(response.status, 200)
  assert.equal(response.headers.get("content-type"), "image/png")
  assert.equal(await response.text(), "-f png -w 1200 -h 630|<svg/>")
})

test("rejects SVG sizes outside the allowed range", async () => {
  const response = await fetch(`${baseUrl}/svg?width=0&height=99999`, {
    method: "POST",
    body: "<svg/>",
  })
  assert.equal(response.status, 400)
})
