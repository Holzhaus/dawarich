// Stand-in for vendor/poster_renderer/render.mjs in the renderer server test:
// writes the received job as the "PNG" and the title as the "PDF".
import fs from "node:fs"

const job = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
if (job.text?.title === "fail") {
  process.stderr.write("renderer exploded")
  process.exit(3)
}
if (job.text?.title === "hang") setTimeout(() => {}, 60_000)
else {
  fs.writeFileSync(job.output.png, JSON.stringify(job))
  if (job.output.pdf) fs.writeFileSync(job.output.pdf, `PDF:${job.text.title}`)
}
