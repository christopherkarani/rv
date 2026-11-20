// End-to-end smoke test against a running app and dev stack:
//   scripts/dev-stack.sh up && npm run build && npm start   (APP_URL=http://localhost:3000)
//   node e2e/smoke.mjs
// Drives the real flows: magic-link sign-in (via Mailpit), org creation,
// enrollment, machines posting rv-format and OCSF events plus rv.report.v1,
// signed policy upload, invites and roles, revocation. Exits non-zero on failure.
import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const { chromium } = require("playwright")

const APP = process.env.APP_URL ?? "http://localhost:3000"
const MAIL = process.env.MAILPIT_URL ?? "http://127.0.0.1:54324"
const OUT = process.env.E2E_OUT ?? path.resolve(".dev-stack/e2e")
fs.mkdirSync(OUT, { recursive: true })

const run = crypto.randomBytes(3).toString("hex")
const OWNER = `owner-${run}@example.test`
const VIEWER = `viewer-${run}@example.test`
const consoleErrors = []
let step = 0
const log = (m) => console.log(`${String(++step).padStart(2)}. ${m}`)
function assert(cond, msg) {
  if (!cond) throw new Error(`assertion failed: ${msg}`)
}

// ---------------------------------------------------------------- mail
async function magicLink(email) {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)
    const list = await res.json()
    const msg = list.messages?.[0]
    if (msg) {
      const full = await (await fetch(`${MAIL}/api/v1/message/${msg.ID}`)).json()
      const body = `${full.HTML ?? ""} ${full.Text ?? ""}`
      const m = /https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/.exec(body)
      if (m) return m[0].replace(/&amp;/g, "&")
    }
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`no magic link for ${email}`)
}

async function signIn(page, email) {
  await page.goto(`${APP}/`)
  assert(page.url().includes("/login"), "signed-out visit redirects to /login")
  await page.fill("#email", email)
  await page.click("button:has-text('Continue with email')")
  await page.waitForSelector("text=Check your email")
  await page.goto(await magicLink(email))
  await page.waitForLoadState("networkidle")
}

// ---------------------------------------------------------------- fake machine
const sha = (s) => crypto.createHash("sha256").update(s).digest("hex")
const HOSTS = ["claude", "cursor", "codex"]
const RULES = ["core.git:reset-hard", "core.filesystem:rm-rf-general", "core.git:push-force-long", "core.git:clean-force", "infrastructure.terraform:destroy"]

function rvEvents(count, { startHead = null, observe = false, offsetDays = 0 } = {}) {
  let prev = startHead
  const out = []
  for (let i = 0; i < count; i++) {
    const host = HOSTS[i % HOSTS.length]
    const t = new Date(Date.now() - offsetDays * 86_400_000 - (count - i) * 600_000)
    const event = {
      agent: host,
      decision: observe ? "info" : "denied",
      detail: { category: "git", host, tool: "Bash", ...(observe ? { would_be: i % 5 === 0 ? "ask" : "deny" } : {}) },
      kind: observe ? "command.observed" : "command.denied",
      ...(prev ? { prev } : {}),
      schema: "rv.audit.v1",
      source: "audit.jsonl",
      subject: RULES[i % RULES.length],
      time: t.toISOString().replace(/\.\d{3}Z$/, "Z"),
    }
    const head = sha(JSON.stringify(event))
    out.push({ ...event, chainHead: head })
    prev = head
  }
  return out
}

function report(name, overrides = {}) {
  const base = JSON.parse(fs.readFileSync(new URL("../tests/fixtures/report.json", import.meta.url), "utf8"))
  return { ...base, generatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), host: { ...base.host, name }, ...overrides }
}

async function api(pathname, body, credential) {
  const res = await fetch(`${APP}${pathname}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(credential ? { authorization: `Bearer ${credential}` } : {}) },
    body: JSON.stringify(body),
  })
  return { status: res.status, json: await res.json().catch(() => null) }
}

// ---------------------------------------------------------------- policy signing (same encoding as rv managed)
function keygen() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519")
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url")
  return { pub: raw.toString("base64"), privateKey }
}

// ---------------------------------------------------------------- run
const browser = await chromium.launch()
const shots = []
async function shot(page, name) {
  await page.waitForLoadState("networkidle")
  const file = path.join(OUT, `${name}.png`)
  await page.screenshot({ path: file, fullPage: true })
  shots.push(file)
}
function watch(page) {
  page.on("console", (m) => m.type() === "error" && consoleErrors.push(`${page.url()}: ${m.text()}`))
  page.on("pageerror", (e) => consoleErrors.push(`${page.url()}: ${e}`))
}

try {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: "dark" })
  const page = await ctx.newPage()
  watch(page)

  await signIn(page, OWNER)
  assert(page.url().includes("/onboarding"), `new user lands on onboarding (got ${page.url()})`)
  log("magic-link sign-in works and a new user is sent to onboarding")

  await page.fill("#name", `Acme ${run}`)
  await page.click("button:has-text('Create organization')")
  await page.waitForURL(/\/settings/)
  log("org created; redirected to settings")

  await page.fill("#token-label", "e2e laptops")
  await page.click("button:has-text('Create token')")
  const tokenText = await page.locator("pre").first().textContent()
  const token = tokenText.trim()
  assert(/^rvc_enr_/.test(token), "token shown once")
  await shot(page, "settings-token")
  log("enrollment token created and shown once with setup commands")

  // Three machines: two rv-format, one OCSF; one with a broken report.
  const machines = []
  for (const name of ["mbp-ana", "dev-chen", "mbp-sam"]) {
    const r = await api("/api/v1/enroll", { token, name, platform: name.startsWith("mbp") ? "macos" : "linux", rvVersion: "0.2.2" })
    assert(r.status === 201, `enroll ${name}: ${r.status}`)
    machines.push({ name, ...r.json })
  }
  log("3 machines enrolled through the API")

  const [ana, chen, sam] = machines
  let r = await api("/api/v1/report", report("mbp-ana"), ana.credential)
  assert(r.status === 202 && r.json.compliant === true, "compliant report accepted")
  r = await api("/api/v1/report", report("dev-chen", { rv: { version: "0.2.1", platform: "linux" }, audit: { ...report("x").audit, chainIntact: false } }), chen.credential)
  assert(r.status === 202 && r.json.compliant === false, "broken-chain report marked non-compliant")
  r = await api("/api/v1/report", report("mbp-sam", { hosts: { claude: "block", cursor: "observe", codex: "off" }, packs: ["core.git"] }), sam.credential)
  assert(r.status === 202, "report with host modes accepted")
  log("rv.report.v1 documents accepted; compliance computed like rv")

  const anaBatch = rvEvents(40)
  r = await api("/api/v1/events", anaBatch, ana.credential)
  assert(r.status === 200 && r.json.inserted === 40, `ana events: ${JSON.stringify(r.json)}`)
  r = await api("/api/v1/events", anaBatch, ana.credential)
  assert(r.json.duplicates === 40 && r.json.inserted === 0, "resend is idempotent")
  const cont = rvEvents(10, { startHead: anaBatch.at(-1).chainHead })
  r = await api("/api/v1/events", cont, ana.credential)
  assert(r.json.gaps === 0, "continuing batch has no gap")
  r = await api("/api/v1/events", rvEvents(25, { observe: true }), sam.credential)
  assert(r.status === 200, "observe events accepted")
  const chenFirst = rvEvents(5)
  await api("/api/v1/events", chenFirst, chen.credential)
  r = await api("/api/v1/events", rvEvents(5, { startHead: "f".repeat(64) }), chen.credential)
  assert(r.json.gaps === 1, "rewritten log detected as a gap")
  const ocsf = JSON.parse(fs.readFileSync(new URL("../tests/fixtures/forward-ocsf.json", import.meta.url), "utf8"))
  r = await api("/api/v1/events", ocsf, sam.credential)
  assert(r.status === 200 && r.json.inserted === 2, "OCSF batch accepted")
  log("events ingested: idempotent resend, continuous chain, gap detected, OCSF accepted")

  r = await api("/api/v1/events", [], "rvc_mch_" + "x".repeat(43))
  assert(r.status === 401, "unknown credential refused")

  for (const [route, name] of [
    ["/", "overview"],
    ["/machines", "machines"],
    [`/machines/${chen.machineId}`, "machine-chen"],
    ["/activity", "activity"],
    ["/rollout", "rollout"],
    ["/audit", "audit"],
  ]) {
    await page.goto(`${APP}${route}`)
    await shot(page, name)
  }
  // Streamed sections: wait for the text rather than reading too early.
  const expectText = async (route, text) => {
    await page.goto(`${APP}${route}`)
    await page.waitForSelector(`text=${text}`, { timeout: 10_000 })
  }
  await expectText("/", "core.git:reset-hard")
  await expectText("/machines", "Non-compliant")
  await expectText("/audit", "Gap in forwarded chain")
  log("overview, machines, machine detail, activity, rollout and audit render real data")

  // Policy: pin a key, upload a signed bundle, then refuse a tampered one.
  const key = keygen()
  await page.goto(`${APP}/policy`)
  await page.fill("#publicKey", key.pub)
  await page.fill("#label", "e2e key")
  await page.click("button:has-text('Pin key')")
  await page.waitForSelector("text=e2e key")
  const policyText = JSON.stringify({ version: 1, organization: `Acme ${run}`, serial: 1, gate: { requirePacks: ["core.git", "core.filesystem", "system.disk"] } }, null, 2) + "\n"
  const sig = crypto.sign(null, Buffer.from(policyText), key.privateKey).toString("base64")
  const upload = async (text, signature) => {
    await page.setInputFiles("#policy", { name: "policy.json", mimeType: "application/json", buffer: Buffer.from(text) })
    await page.setInputFiles("#signature", { name: "policy.json.sig", mimeType: "text/plain", buffer: Buffer.from(signature + "\n") })
    await page.click("button:has-text('Verify and upload')")
  }
  await upload(policyText.replace('"serial": 1', '"serial": 2'), sig)
  await page.waitForSelector("text=does not verify")
  log("tampered policy refused")
  await upload(policyText, sig)
  await page.waitForSelector("text=verified and stored")
  await page.goto(`${APP}/policy`)
  await shot(page, "policy")
  const dl = await page.request.get(`${APP}/api/policy/1?file=policy.json`)
  assert((await dl.text()) === policyText, "download returns the exact signed bytes")
  log("signed policy verified, stored and downloadable byte-for-byte")

  // Invite a viewer, who signs in and gets read-only access.
  await page.goto(`${APP}/settings`)
  await page.fill("#invite-email", VIEWER)
  await page.click("button:has-text('Invite')")
  await page.waitForSelector(`text=Invited ${VIEWER}`)
  const vctx = await browser.newContext({ viewport: { width: 1280, height: 800 } })
  const vpage = await vctx.newPage()
  watch(vpage)
  await signIn(vpage, VIEWER)
  assert(!vpage.url().includes("/onboarding"), "invitee joins the org on sign-in")
  const vtext = await vpage.textContent("main")
  assert(!vtext.includes("Enroll machines") && !vtext.includes("Admin log"), "viewer cannot see tokens or admin log")
  await vpage.goto(`${APP}/machines/${ana.machineId}`)
  await vpage.waitForSelector("text=Recent events")
  assert((await vpage.locator("button:has-text('Revoke credential')").count()) === 0, "viewer cannot revoke")
  log("invite accepted on sign-in; viewer is read-only")

  // Revoke a machine; its credential stops working.
  await page.goto(`${APP}/machines/${ana.machineId}`)
  await page.click("button:has-text('Revoke credential')")
  await page.click("button:has-text('Revoke'):not(:has-text('credential'))")
  await page.waitForSelector("text=Revoked")
  r = await api("/api/v1/events", rvEvents(1), ana.credential)
  assert(r.status === 401, "revoked credential refused")
  log("revoked machine can no longer send data")

  // Exports.
  const csv = await page.request.get(`${APP}/api/export/machines`)
  assert((await csv.text()).split("\r\n").length >= 4, "machines CSV has rows")
  const jsonl = await page.request.get(`${APP}/api/export/events`)
  assert((await jsonl.text()).trim().split("\n").length >= 80, "events export streams every event")
  await page.goto(`${APP}/settings`)
  await shot(page, "settings")
  log("CSV and JSONL exports work")

  // Mobile layout: no horizontal scroll.
  const mctx = await browser.newContext({ ...require("playwright").devices["iPhone 13"], storageState: await ctx.storageState() })
  const mpage = await mctx.newPage()
  for (const route of ["/", "/machines", "/activity", "/policy", "/settings"]) {
    await mpage.goto(`${APP}${route}`)
    await mpage.waitForLoadState("networkidle")
    const [sw, iw] = await mpage.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth])
    assert(sw <= iw, `${route} fits a phone (${sw} > ${iw})`)
  }
  await mpage.goto(`${APP}/`)
  await mpage.screenshot({ path: path.join(OUT, "mobile-overview.png") })
  log("every main page fits a 390px phone screen")

  assert(consoleErrors.length === 0, `browser console errors:\n${consoleErrors.join("\n")}`)
  log("no browser console errors")
  console.log(`\nPASS · screenshots in ${OUT}`)
} catch (e) {
  console.error(`\nFAIL at step ${step + 1}: ${e.message}`)
  if (consoleErrors.length) console.error(consoleErrors.join("\n"))
  process.exitCode = 1
} finally {
  await browser.close()
}
