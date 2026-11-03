// HTTP front of the renderer sidecar image (docker/Dockerfile, target
// "renderer"). The Distroless app image has no Node, Mesa or rsvg-convert, so
// Rails sends render work here when RENDERER_URL is set.
//
//   POST /posters        job JSON (see render.mjs) -> { png, pdf } as base64
//   POST /svg?width&height  SVG document -> PNG via rsvg-convert
//   GET  /health         -> { status: "ok" }
//
// Each poster renders in a fresh render.mjs child process, like the CLI path,
// so a crash or leak never outlives one job. The server must not be published:
// it has no authentication and is meant for the app on the internal network.
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import fs from "node:fs/promises"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const DIR = path.dirname(fileURLToPath(import.meta.url))
const MAX_BODY_BYTES = 32 * 1024 * 1024
const MAX_SVG_DIMENSION = 4096
const TERMINATE_GRACE_MS = 5000

function splitCommand(value) {
  return value?.trim() ? value.trim().split(/\s+/) : null
}

export function defaultOptions(env = process.env) {
  return {
    posterCommand: splitCommand(env.POSTER_RENDER_CMD) ?? [
      process.execPath,
      "--import",
      path.join(DIR, "register.mjs"),
      path.join(DIR, "render.mjs"),
    ],
    // Without the maplibre-native binding (armv7 builds) posters are
    // unavailable, but achievement images still render.
    posterSupported:
      Boolean(env.POSTER_RENDER_CMD) ||
      existsSync(path.join(DIR, "node_modules/@maplibre/maplibre-gl-native")),
    svgCommand: splitCommand(env.SVG_CONVERT_CMD) ?? ["rsvg-convert"],
    posterTimeoutMs: Number.parseInt(env.POSTER_TIMEOUT_MS ?? "180000", 10),
    svgTimeoutMs: Number.parseInt(env.SVG_TIMEOUT_MS ?? "10000", 10),
    maxConcurrentPosters: Number.parseInt(env.RENDERER_CONCURRENCY ?? "2", 10),
  }
}

class HttpError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

// Runs a command in its own process group so a timeout can stop the whole
// tree (xvfb children, node workers), not just the leader.
function run(command, args, { input, timeoutMs, env }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], [...command.slice(1), ...args], {
      detached: true,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    })
    const stdout = []
    const stderr = []
    let timedOut = false

    const killGroup = (signal) => {
      try {
        process.kill(-child.pid, signal)
      } catch {
        // already gone
      }
    }
    const timer = setTimeout(() => {
      timedOut = true
      killGroup("SIGTERM")
      setTimeout(() => killGroup("SIGKILL"), TERMINATE_GRACE_MS).unref()
    }, timeoutMs)

    child.stdout.on("data", (chunk) => stdout.push(chunk))
    child.stderr.on("data", (chunk) => stderr.push(chunk))
    child.on("error", (error) => {
      clearTimeout(timer)
      reject(error)
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      if (timedOut) {
        reject(new HttpError(504, `timed out after ${timeoutMs / 1000} seconds`))
        return
      }
      resolve({ code, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr).toString() })
    })

    child.stdin.on("error", () => {})
    child.stdin.end(input)
  })
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    request.on("data", (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new HttpError(413, "request body too large"))
        request.destroy()
        return
      }
      chunks.push(chunk)
    })
    request.on("end", () => resolve(Buffer.concat(chunks)))
    request.on("error", reject)
  })
}

// Bounds how many posters render at once; each one is a full software-GL
// render of a 2400x3200 canvas.
function createLimiter(max) {
  let active = 0
  const waiting = []
  return async (task) => {
    if (active >= max) await new Promise((resolve) => waiting.push(resolve))
    active += 1
    try {
      return await task()
    } finally {
      active -= 1
      waiting.shift()?.()
    }
  }
}

async function renderPoster(body, options) {
  if (!options.posterSupported) {
    throw new HttpError(503, "poster rendering is not available on this platform")
  }

  let job
  try {
    job = JSON.parse(body.toString("utf8"))
  } catch {
    throw new HttpError(400, "job is not valid JSON")
  }
  if (!job || typeof job !== "object" || !job.view || !job.size) {
    throw new HttpError(400, "job needs view and size")
  }

  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "poster-"))
  try {
    // Outputs always go to this job's temp dir, and a caller-chosen tile URL
    // is dropped, so the endpoint can neither write files elsewhere nor fetch
    // arbitrary URLs from inside the network.
    delete job.tilesUrl
    const wantsPdf = Boolean(job.output?.pdf)
    job.output = {
      ...job.output,
      png: path.join(dir, "poster.png"),
      pdf: wantsPdf ? path.join(dir, "poster.pdf") : undefined,
    }
    const jobPath = path.join(dir, "job.json")
    await fs.writeFile(jobPath, JSON.stringify(job))

    const result = await run(options.posterCommand, [jobPath], {
      timeoutMs: options.posterTimeoutMs,
      env: process.env,
    })
    if (result.code !== 0) {
      throw new HttpError(500, (result.stderr || result.stdout.toString()).trim())
    }

    const png = await fs.readFile(job.output.png)
    const pdf = wantsPdf ? await fs.readFile(job.output.pdf) : null
    return {
      png: png.toString("base64"),
      pdf: pdf ? pdf.toString("base64") : null,
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true })
  }
}

function dimension(params, name) {
  const value = Number.parseInt(params.get(name) ?? "", 10)
  if (!Number.isInteger(value) || value < 1 || value > MAX_SVG_DIMENSION) {
    throw new HttpError(400, `${name} must be an integer between 1 and ${MAX_SVG_DIMENSION}`)
  }
  return value
}

async function renderSvg(body, params, options) {
  const width = dimension(params, "width")
  const height = dimension(params, "height")
  // The vendored Ubuntu libraries (LD_LIBRARY_PATH) are only for the
  // maplibre-native binding; rsvg-convert must use Debian's own.
  const { LD_LIBRARY_PATH: _ignored, ...env } = process.env
  const result = await run(
    options.svgCommand,
    ["-f", "png", "-w", String(width), "-h", String(height)],
    { input: body, timeoutMs: options.svgTimeoutMs, env },
  )
  if (result.code !== 0) throw new HttpError(500, result.stderr.trim() || "svg conversion failed")
  return result.stdout
}

function send(response, status, body, type) {
  response.writeHead(status, { "Content-Type": type, "Content-Length": Buffer.byteLength(body) })
  response.end(body)
}

function sendJson(response, status, payload) {
  send(response, status, JSON.stringify(payload), "application/json")
}

export function createRendererServer(options = defaultOptions()) {
  const limitPosters = createLimiter(options.maxConcurrentPosters)

  return http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://renderer")
    try {
      if (request.method === "GET" && url.pathname === "/health") {
        sendJson(response, 200, { status: "ok", posters: options.posterSupported })
      } else if (request.method === "POST" && url.pathname === "/posters") {
        const body = await readBody(request)
        sendJson(response, 200, await limitPosters(() => renderPoster(body, options)))
      } else if (request.method === "POST" && url.pathname === "/svg") {
        const body = await readBody(request)
        send(response, 200, await renderSvg(body, url.searchParams, options), "image/png")
      } else {
        sendJson(response, 404, { error: "not found" })
      }
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500
      if (!response.headersSent) sendJson(response, status, { error: error.message })
    }
  })
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number.parseInt(process.env.PORT ?? "3100", 10)
  const server = createRendererServer()
  // No host: Node listens on :: when IPv6 is available, else on 0.0.0.0.
  server.listen(port, () => {
    process.stdout.write(`renderer listening on ${port}\n`)
  })
  const shutdown = () => server.close(() => process.exit(0))
  process.on("SIGTERM", shutdown)
  process.on("SIGINT", shutdown)
}
