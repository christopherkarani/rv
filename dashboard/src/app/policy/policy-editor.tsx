"use client"

import { useMemo, useState } from "react"
import { CheckIcon, CopyIcon, DownloadIcon, LockIcon } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Separator } from "@/components/ui/separator"
import { Switch } from "@/components/ui/switch"
import { Textarea } from "@/components/ui/textarea"
import { Mono } from "@/components/shared"
import { CURRENT_SERIAL, PACKS, SECRET_SOURCES } from "@/lib/data"

const CORE = PACKS.filter((p) => p.defaultOn).map((p) => p.id)

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-6 py-3">
      <div className="space-y-0.5">
        <div className="text-sm font-medium">{label}</div>
        {hint && <div className="text-xs text-muted-foreground">{hint}</div>}
      </div>
      <div className="shrink-0">{children}</div>
    </div>
  )
}

export function PolicyEditor() {
  const [org, setOrg] = useState("Acme Engineering")
  const [packs, setPacks] = useState<string[]>([...CORE, "cloud.aws", "infrastructure.terraform"])
  const [gate, setGate] = useState(true)
  const [strict, setStrict] = useState(false)
  const [requireSandbox, setRequireSandbox] = useState(true)
  const [allowDirect, setAllowDirect] = useState(false)
  const [blocked, setBlocked] = useState("filesystem-*\nshell-*")
  const [defaultDecision, setDefaultDecision] = useState<"allow" | "ask" | "deny">("ask")
  const [sources, setSources] = useState<string[]>(["keychain", "onePassword", "vault"])
  const [envDelivery, setEnvDelivery] = useState(false)
  const [forward, setForward] = useState(true)
  const [copied, setCopied] = useState(false)

  const policy = useMemo(() => {
    const p: Record<string, unknown> = { version: 1, organization: org, serial: CURRENT_SERIAL + 1 }
    p.mcp = {
      blocked: blocked.split("\n").map((s) => s.trim()).filter(Boolean),
      allowDirect,
      requireSandbox,
      defaultDecision,
    }
    p.secrets = { allowedSources: sources, allowEnvironmentDelivery: envDelivery }
    if (forward) {
      p.audit = {
        forward: {
          url: "https://ingest.rv.cloud/v1/events",
          headers: { Authorization: "Bearer ${secret:RV_CLOUD}" },
        },
      }
    }
    if (gate) p.gate = { requirePacks: packs, ...(strict ? { safety: "strict" } : {}) }
    return p
  }, [org, packs, gate, strict, requireSandbox, allowDirect, blocked, defaultDecision, sources, envDelivery, forward])

  const json = JSON.stringify(policy, null, 2)
  const toggle = (list: string[], set: (v: string[]) => void, id: string) =>
    set(list.includes(id) ? list.filter((x) => x !== id) : [...list, id])

  function download() {
    const url = URL.createObjectURL(new Blob([json + "\n"], { type: "application/json" }))
    const a = Object.assign(document.createElement("a"), { href: url, download: "policy.json" })
    a.click()
    URL.revokeObjectURL(url)
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(json)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // Clipboard can be blocked; the download still works.
    }
  }

  const categories = [...new Set(PACKS.map((p) => p.category))]

  return (
    <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,1fr)_400px]">
      <div className="min-w-0 space-y-6">
        <Card>
          <CardHeader>
            <CardTitle>Organization</CardTitle>
            <CardDescription>
              The next revision is serial {CURRENT_SERIAL + 1}. Machines refuse a serial lower than one they already accepted.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Label htmlFor="org" className="mb-2">
              Name
            </Label>
            <Input id="org" value={org} onChange={(e) => setOrg(e.target.value)} className="max-w-sm" />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Gate</CardTitle>
            <CardDescription>
              Packs every agent runs under, whatever the user&apos;s own pack config says. A gate also pins enforce: observe mode is refused on machines under it.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="divide-y">
              <Field label="Include a gate" hint="Turn off to collect audit and posture without pinning enforce.">
                <Switch checked={gate} onCheckedChange={setGate} />
              </Field>
              <Field label="Require strict safety" hint="Users cannot relax safety to normal.">
                <Switch checked={strict} onCheckedChange={setStrict} disabled={!gate} />
              </Field>
            </div>
            <Separator />
            <div className={gate ? "space-y-4" : "pointer-events-none space-y-4 opacity-50"}>
              {categories.map((cat) => (
                <div key={cat}>
                  <div className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">{cat}</div>
                  <div className="grid gap-2 sm:grid-cols-2">
                    {PACKS.filter((p) => p.category === cat).map((p) => {
                      const locked = CORE.includes(p.id)
                      return (
                        <label key={p.id} className="flex cursor-pointer items-center gap-2.5 rounded-lg border px-3 py-2 text-sm hover:bg-muted/40 has-[[data-checked]]:border-foreground/30">
                          <Checkbox checked={packs.includes(p.id)} disabled={locked} onCheckedChange={() => toggle(packs, setPacks, p.id)} />
                          <span className="min-w-0 flex-1">
                            <span className="block truncate">{p.name}</span>
                            <Mono className="block truncate text-xs text-muted-foreground">{p.id}</Mono>
                          </span>
                          {locked && <LockIcon className="size-3.5 text-muted-foreground" />}
                        </label>
                      )
                    })}
                  </div>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>MCP servers</CardTitle>
            <CardDescription>Applies to every MCP server routed through the rv gateway.</CardDescription>
          </CardHeader>
          <CardContent className="divide-y">
            <Field label="Require a sandbox" hint="On Linux without the cage, every local server is refused.">
              <Switch checked={requireSandbox} onCheckedChange={setRequireSandbox} />
            </Field>
            <Field label="Allow direct servers" hint="When off, the user's mcp.json direct list is ignored.">
              <Switch checked={allowDirect} onCheckedChange={setAllowDirect} />
            </Field>
            <Field label="Default decision" hint="For tools no rule matches.">
              <Select value={defaultDecision} onValueChange={(v) => setDefaultDecision(v as typeof defaultDecision)}>
                <SelectTrigger className="w-28">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="allow">allow</SelectItem>
                  <SelectItem value="ask">ask</SelectItem>
                  <SelectItem value="deny">deny</SelectItem>
                </SelectContent>
              </Select>
            </Field>
            <div className="space-y-2 py-3">
              <div className="text-sm font-medium">Blocked server globs</div>
              <Textarea value={blocked} onChange={(e) => setBlocked(e.target.value)} className="font-mono text-xs" rows={3} />
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Secrets</CardTitle>
            <CardDescription>Where secret values may come from.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="flex flex-wrap gap-2">
              {SECRET_SOURCES.map((s) => (
                <button key={s} type="button" onClick={() => toggle(sources, setSources, s)}>
                  <Badge variant={sources.includes(s) ? "default" : "outline"} className="cursor-pointer font-mono font-normal">
                    {s}
                  </Badge>
                </button>
              ))}
            </div>
            <Field label="Allow environment-variable delivery" hint="When off, secrets reach a runtime only as gateway placeholders.">
              <Switch checked={envDelivery} onCheckedChange={setEnvDelivery} />
            </Field>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Audit forwarding</CardTitle>
            <CardDescription>Sends every machine&apos;s hash-chained audit events to rv Cloud.</CardDescription>
          </CardHeader>
          <CardContent>
            <Field label="Forward to rv Cloud" hint="The token is a secret reference, resolved on each machine.">
              <Switch checked={forward} onCheckedChange={setForward} />
            </Field>
          </CardContent>
        </Card>
      </div>

      <div className="min-w-0 space-y-4 lg:sticky lg:top-32 lg:self-start">
        <Card className="gap-0 overflow-hidden py-0">
          <div className="flex items-center justify-between border-b px-4 py-2.5">
            <span className="font-mono text-xs text-muted-foreground">policy.json · unsigned</span>
            <Button variant="ghost" size="icon-sm" onClick={copy} aria-label="Copy policy">
              {copied ? <CheckIcon /> : <CopyIcon />}
            </Button>
          </div>
          <pre className="max-h-[420px] overflow-auto bg-muted/30 p-4 font-mono text-xs leading-relaxed">{json}</pre>
        </Card>
        <Button className="w-full" onClick={download}>
          <DownloadIcon />
          Download unsigned policy.json
        </Button>
        <Card size="sm">
          <CardHeader>
            <CardTitle className="text-sm">Sign it off this server</CardTitle>
            <CardDescription>rv Cloud never holds your signing key.</CardDescription>
          </CardHeader>
          <CardContent>
            <ol className="space-y-2 text-xs text-muted-foreground">
              <li>
                1. <Mono className="text-foreground">rv managed sign policy.json --key org-key</Mono>
              </li>
              <li>
                2. <Mono className="text-foreground">rv managed verify .</Mono>
              </li>
              <li>3. Upload policy.json and policy.json.sig below, then push them with your MDM.</li>
            </ol>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
