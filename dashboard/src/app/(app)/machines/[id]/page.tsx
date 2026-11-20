import { Suspense } from "react"
import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeftIcon, CheckCircle2Icon, CircleHelpIcon, XCircleIcon } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { EmptyState, HostModeBadge, Mono, PageBody, Section, Skeleton, Status, TableSkeleton } from "@/components/shared"
import { assess, newestVersion, timeAgo } from "@/lib/machine-status"
import { chainFindings, currentPolicySerial, getMachine, listEvents, listMachines } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"
import { canAdmin, hostLabel, platformLabel } from "@/lib/vocab"
import { RevokeButton, TeamForm } from "./machine-actions"

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 py-2.5 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="min-w-0 text-right">{children}</span>
    </div>
  )
}

function Check({ ok, children }: { ok: boolean | null; children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 text-sm">
      {ok === null ? (
        <CircleHelpIcon className="size-4 text-muted-foreground" />
      ) : ok ? (
        <CheckCircle2Icon className="size-4 text-success" />
      ) : (
        <XCircleIcon className="size-4 text-destructive" />
      )}
      {children}
    </div>
  )
}

const fmt = (iso: string) => new Date(iso).toISOString().replace("T", " ").slice(0, 16) + " UTC"

async function Machine({ params }: { params: PageProps<"/machines/[id]">["params"] }) {
  const { id } = await params
  const { org } = await getSession()
  const m = await getMachine(org.orgId, id)
  if (!m) notFound()
  const now = requestTime()
  const [all, serial, events, findings] = await Promise.all([
    listMachines(org.orgId),
    currentPolicySerial(org.orgId),
    listEvents(org.orgId, { machineId: m.id, limit: 30 }),
    chainFindings(org.orgId, m.id),
  ])
  const a = assess(m, { now, currentSerial: serial, latestVersion: newestVersion(all.map((x) => x.rv_version)) })
  const r = m.latest_report
  const admin = canAdmin(org.role)

  return (
    <>
      <div className="border-b bg-muted/30">
        <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6">
          <Button variant="ghost" size="sm" className="-ml-2 mb-4 text-muted-foreground" render={<Link href="/machines" />}>
            <ArrowLeftIcon />
            Machines
          </Button>
          <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-3">
                <h1 className="truncate text-2xl font-semibold tracking-tight sm:text-3xl">{m.name}</h1>
                {m.team && (
                  <Badge variant="outline" className="font-normal">
                    {m.team}
                  </Badge>
                )}
              </div>
              <div className="mt-2 flex flex-wrap items-center gap-x-5 gap-y-1 text-sm text-muted-foreground">
                <Status tone={a.tone}>{a.label}</Status>
                <span>{platformLabel(m.platform)}</span>
                {m.rv_version && (
                  <span>
                    rv <Mono>{m.rv_version}</Mono>
                  </span>
                )}
                <span>Last seen {timeAgo(m.last_seen_at, now)}</span>
              </div>
            </div>
            {admin && !m.revoked_at && <RevokeButton machineId={m.id} name={m.name} />}
          </div>
        </div>
      </div>

      <PageBody className="space-y-8">
        {a.issues.length > 0 && (
          <div className={`rounded-xl border p-4 ${a.tone === "error" ? "border-destructive/40 bg-destructive/5" : "border-warning/40 bg-warning/5"}`}>
            <div className="text-sm font-medium">{a.tone === "error" ? "Why this machine is not compliant" : "Drift from expected state"}</div>
            <ul className="mt-2 space-y-1 text-sm text-muted-foreground">
              {a.issues.map((d) => (
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
              {r?.hosts && Object.keys(r.hosts).length > 0 ? (
                Object.entries(r.hosts).map(
                  ([h, mode]) =>
                    mode && (
                      <div key={h} className="flex items-center justify-between text-sm">
                        {hostLabel(h)}
                        <HostModeBadge host={h} mode={mode} compact />
                      </div>
                    ),
                )
              ) : (
                <p className="text-sm text-muted-foreground">This rv version does not report host modes yet.</p>
              )}
              <p className="pt-2 text-xs text-muted-foreground">Only the machine owner can change a host mode, with owner authentication.</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Posture</CardTitle>
            </CardHeader>
            <CardContent className="divide-y py-0">
              <Row label="Org policy">
                {r?.managed?.state === "active" ? (
                  <span className={serial != null && (r.managed.serial ?? -1) < serial ? "text-warning" : ""}>
                    active · serial {r.managed.serial ?? "unset"}
                  </span>
                ) : (
                  <span className={r?.managed?.state === "invalid" ? "text-destructive" : "text-muted-foreground"}>{r?.managed?.state ?? "—"}</span>
                )}
              </Row>
              <Row label="MCP servers">
                {r?.mcp ? `${r.mcp.servers ?? 0}${r.mcp.failing?.length ? ` · ${r.mcp.failing.length} failing` : ""}` : "—"}
              </Row>
              <Row label="Host / user">
                {[m.hostname, m.os_user].filter(Boolean).join(" / ") || "—"}
              </Row>
              <Row label="Enrolled">{timeAgo(m.enrolled_at, now)}</Row>
              <Row label="Last report">{timeAgo(m.last_report_at, now)}</Row>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Checks</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2.5">
              <Check ok={r?.audit?.chainIntact ?? null}>
                Local audit chain {r?.audit?.chainIntact == null ? "not reported" : r.audit.chainIntact ? "intact" : "broken"}
              </Check>
              <Check ok={m.chain_status === "unknown" ? null : m.chain_status === "ok"}>Forwarded chain continuous</Check>
              <Check ok={r?.managed ? r.managed.state !== "invalid" : null}>Org policy verifies</Check>
              <Check ok={r?.mcp ? r.mcp.ok !== false : null}>MCP servers healthy</Check>
              <Check ok={r?.mcp ? (r.mcp.plaintextCredentials ?? 0) === 0 : null}>No plaintext MCP credentials</Check>
              <Check ok={r?.sandbox ? Boolean(r.sandbox.mcpSandbox) : null}>MCP server sandbox enforced</Check>
            </CardContent>
          </Card>
        </div>

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <Card className="lg:col-span-2">
            <CardHeader>
              <CardTitle className="text-sm">Team</CardTitle>
            </CardHeader>
            <CardContent>{admin ? <TeamForm machineId={m.id} team={m.team} /> : <span className="text-sm">{m.team ?? "No team"}</span>}</CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Last forwarded chain head</CardTitle>
            </CardHeader>
            <CardContent>
              <Mono className="break-all text-xs text-muted-foreground">{m.chain_head ?? "none yet"}</Mono>
            </CardContent>
          </Card>
        </div>

        {findings.length > 0 && (
          <Section title="Chain findings" description="Each one means forwarded events did not continue the previous chain head.">
            <div className="divide-y rounded-xl border text-sm">
              {findings.map((f) => (
                <div key={f.id} className="flex flex-wrap items-center justify-between gap-2 p-3">
                  <Status tone="error">{f.kind === "gap" ? "Gap in forwarded chain" : "Local chain broken"}</Status>
                  <span className="text-muted-foreground">{fmt(f.detected_at)}</span>
                </div>
              ))}
            </div>
          </Section>
        )}

        <Section title="Recent events" description="Rule ids and hosts only. rv never sends command text.">
          {events.length === 0 ? (
            <EmptyState title="No events from this machine yet" />
          ) : (
            <div className="overflow-hidden rounded-xl border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead>Time</TableHead>
                    <TableHead>Kind</TableHead>
                    <TableHead>Subject</TableHead>
                    <TableHead className="hidden sm:table-cell">Host</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {events.map((e) => (
                    <TableRow key={e.uid}>
                      <TableCell className="whitespace-nowrap text-muted-foreground">{fmt(e.time)}</TableCell>
                      <TableCell>
                        <Mono>{e.kind}</Mono>
                      </TableCell>
                      <TableCell className="max-w-80 truncate">
                        <Mono>{e.subject}</Mono>
                      </TableCell>
                      <TableCell className="hidden sm:table-cell">{hostLabel(e.host)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
          <Button variant="ghost" size="sm" render={<Link href={`/activity?machine=${m.id}`} />}>
            All activity for this machine
          </Button>
        </Section>
      </PageBody>
    </>
  )
}

export default function MachinePage({ params }: PageProps<"/machines/[id]">) {
  return (
    <Suspense
      fallback={
        <PageBody className="space-y-6">
          <Skeleton className="h-24 w-full" />
          <TableSkeleton />
        </PageBody>
      }
    >
      <Machine params={params} />
    </Suspense>
  )
}
