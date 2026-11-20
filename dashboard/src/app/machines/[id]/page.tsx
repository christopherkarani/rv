import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeftIcon, CheckCircle2Icon, XCircleIcon } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { HostModeBadge, Mono, PageBody, Section, Status } from "@/components/shared"
import {
  CURRENT_SERIAL,
  EVENTS,
  HOST_LABEL,
  LATEST_VERSION,
  MACHINES,
  PLATFORM_LABEL,
  fmtTime,
  isOnline,
  machineById,
  timeAgo,
  type AgentHost,
  type HostMode,
} from "@/lib/data"

export function generateStaticParams() {
  return MACHINES.map((m) => ({ id: m.id }))
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 py-2.5 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right">{children}</span>
    </div>
  )
}

function Check({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 text-sm">
      {ok ? <CheckCircle2Icon className="size-4 text-success" /> : <XCircleIcon className="size-4 text-destructive" />}
      {children}
    </div>
  )
}

export default async function MachinePage({ params }: PageProps<"/machines/[id]">) {
  const { id } = await params
  const m = machineById(id)
  if (!m) notFound()
  const online = isOnline(m)
  const events = EVENTS.filter((e) => e.machineId === m.id).slice(0, 25)

  return (
    <>
      <div className="border-b bg-muted/30">
        <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6">
          <Button variant="ghost" size="sm" className="-ml-2 mb-4 text-muted-foreground" render={<Link href="/machines" />}>
            <ArrowLeftIcon />
            Machines
          </Button>
          <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <div className="flex items-center gap-3">
                <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{m.name}</h1>
                <Badge variant="outline" className="font-normal">
                  {m.team}
                </Badge>
              </div>
              <div className="mt-2 flex flex-wrap items-center gap-x-5 gap-y-1 text-sm text-muted-foreground">
                <Status tone={!online ? "neutral" : !m.compliant ? "error" : m.drift.length ? "warning" : "success"} pulse={online && m.compliant}>
                  {!online ? "Silent" : !m.compliant ? "Non-compliant" : m.drift.length ? "Drift" : "Healthy"}
                </Status>
                <span>{PLATFORM_LABEL[m.platform]}</span>
                <span>
                  rv <Mono>{m.rvVersion}</Mono>
                </span>
                <span>Last report {timeAgo(m.lastSeen)}</span>
              </div>
            </div>
            <div className="flex gap-2">
              <Button variant="outline">Download report JSON</Button>
              <Button variant="destructive">Revoke credential</Button>
            </div>
          </div>
        </div>
      </div>

      <PageBody className="space-y-8">
        {m.drift.length > 0 && (
          <div className="rounded-xl border border-warning/40 bg-warning/5 p-4">
            <div className="text-sm font-medium">Drift from org policy</div>
            <ul className="mt-2 space-y-1 text-sm text-muted-foreground">
              {m.drift.map((d) => (
                <li key={d}>• {d}</li>
              ))}
            </ul>
          </div>
        )}

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Agent hosts</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2">
              {(Object.entries(m.hosts) as [AgentHost, HostMode][]).map(([h, mode]) => (
                <div key={h} className="flex items-center justify-between text-sm">
                  {HOST_LABEL[h]}
                  <HostModeBadge host={h} mode={mode} compact />
                </div>
              ))}
              <p className="pt-2 text-xs text-muted-foreground">Only the machine owner can change a host mode, with owner authentication.</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Posture</CardTitle>
            </CardHeader>
            <CardContent className="divide-y py-0">
              <Row label="Org policy">
                {m.managed.status === "verified" ? (
                  <span className={m.managed.serial === CURRENT_SERIAL ? "" : "text-warning"}>
                    verified · serial {m.managed.serial}
                  </span>
                ) : (
                  <span className="text-destructive">{m.managed.status}</span>
                )}
              </Row>
              <Row label="rv version">
                <Mono className={m.rvVersion === LATEST_VERSION ? "" : "text-warning"}>{m.rvVersion}</Mono>
              </Row>
              <Row label="MCP servers">
                {m.mcp.servers} {m.mcp.failing > 0 && <span className="text-destructive">· {m.mcp.failing} failing</span>}
              </Row>
              <Row label="Enrolled">{timeAgo(m.enrolledAt)}</Row>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Checks</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2.5">
              <Check ok={m.audit.chainIntact !== false}>Audit chain {m.audit.chainIntact === null ? "unreadable" : m.audit.chainIntact ? "intact" : "broken"}</Check>
              <Check ok={m.managed.status !== "invalid"}>Org policy signature</Check>
              <Check ok={m.mcp.failing === 0}>MCP servers healthy</Check>
              <Check ok={m.mcp.plaintextCredentials === 0}>No plaintext MCP credentials</Check>
              <Check ok={m.sandbox.mcpSandbox}>MCP server sandbox enforced</Check>
            </CardContent>
          </Card>
        </div>

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <Card className="lg:col-span-2">
            <CardHeader>
              <CardTitle className="text-sm">Enabled packs</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap gap-1.5">
              {m.packs.map((p) => (
                <Badge key={p} variant="secondary" className="font-mono font-normal">
                  {p}
                </Badge>
              ))}
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Audit chain head</CardTitle>
            </CardHeader>
            <CardContent>
              <Mono className="break-all text-xs text-muted-foreground">{m.audit.chainHead}</Mono>
              <div className="mt-2 text-xs text-muted-foreground">{m.audit.total7d} events in 7 days</div>
            </CardContent>
          </Card>
        </div>

        <Section title="Recent events" description="Rule ids and hosts only. rv never sends command text.">
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Time</TableHead>
                  <TableHead>Kind</TableHead>
                  <TableHead>Rule</TableHead>
                  <TableHead className="hidden sm:table-cell">Host</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.map((e) => (
                  <TableRow key={e.id}>
                    <TableCell className="whitespace-nowrap text-muted-foreground">{fmtTime(e.recordedAt)}</TableCell>
                    <TableCell>
                      <Mono>{e.kind}</Mono>
                      {e.wouldBe && <span className="ml-1 text-xs text-muted-foreground">would {e.wouldBe}</span>}
                      {e.override && <span className="ml-1 text-xs text-muted-foreground">{e.override}</span>}
                    </TableCell>
                    <TableCell>
                      <Mono>{e.subject}</Mono>
                    </TableCell>
                    <TableCell className="hidden sm:table-cell">{HOST_LABEL[e.host]}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Section>
      </PageBody>
    </>
  )
}
