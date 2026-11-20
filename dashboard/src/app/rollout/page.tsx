import Link from "next/link"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Mono, PageBody, PageHeader, Section, Status } from "@/components/shared"
import { HOST_LABEL, MACHINES, rolloutByHost, topRules } from "@/lib/data"

const READY = {
  ready: { tone: "success" as const, label: "Ready to enforce", note: "0.7 or fewer would-be blocks per machine per day." },
  review: { tone: "warning" as const, label: "Review first", note: "0.8 to 1.0 per machine per day. Check the top rules first." },
  "not-ready": { tone: "error" as const, label: "Not ready", note: "Over 1.0 per machine per day. Enforcing now would interrupt work." },
  "n/a": { tone: "neutral" as const, label: "Fully enforced", note: "No machine is observing this host." },
}

export default function RolloutPage() {
  const hosts = rolloutByHost().filter((h) => h.observing.length + h.enforcing.length + h.off.length > 0)
  const observedRules = topRules("command.observed", 14 * 86_400_000).slice(0, 8)
  const observingMachines = MACHINES.filter((m) => Object.values(m.hosts).includes("observe")).length

  return (
    <>
      <PageHeader
        title="Rollout"
        description={`${observingMachines} machines have at least one host in observe mode. This report shows what enforcement would have blocked over the last 14 days, so you can switch with evidence.`}
        actions={<Button render={<Link href="/policy" />}>Pin enforce with an org gate</Button>}
      />
      <PageBody className="space-y-10">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {hosts.map((h) => {
            const r = READY[h.readiness]
            const total = h.observing.length + h.enforcing.length + h.off.length
            return (
              <Card key={h.host} className="flex flex-col">
                <CardHeader>
                  <div className="flex items-center justify-between">
                    <CardTitle>{HOST_LABEL[h.host]}</CardTitle>
                    <Status tone={r.tone}>{r.label}</Status>
                  </div>
                  <CardDescription>{r.note}</CardDescription>
                </CardHeader>
                <CardContent className="flex-1 space-y-4">
                  <div>
                    <div className="flex h-2 overflow-hidden rounded-full bg-muted">
                      <div className="bg-success" style={{ width: `${(h.enforcing.length / total) * 100}%` }} />
                      <div className="bg-warning" style={{ width: `${(h.observing.length / total) * 100}%` }} />
                      <div className="bg-destructive" style={{ width: `${(h.off.length / total) * 100}%` }} />
                    </div>
                    <div className="mt-2 flex gap-4 text-xs text-muted-foreground">
                      <span>{h.enforcing.length} enforce</span>
                      <span>{h.observing.length} observe</span>
                      {h.off.length > 0 && <span className="text-destructive">{h.off.length} off</span>}
                    </div>
                  </div>
                  {h.observing.length > 0 && (
                    <dl className="grid grid-cols-3 gap-2 text-sm">
                      <div>
                        <dt className="text-xs text-muted-foreground">Would deny</dt>
                        <dd className="font-semibold tabular-nums">{h.wouldDeny}</dd>
                      </div>
                      <div>
                        <dt className="text-xs text-muted-foreground">Would ask</dt>
                        <dd className="font-semibold tabular-nums">{h.wouldAsk}</dd>
                      </div>
                      <div>
                        <dt className="text-xs text-muted-foreground">Per machine/day</dt>
                        <dd className="font-semibold tabular-nums">{h.rate.toFixed(1)}</dd>
                      </div>
                    </dl>
                  )}
                  {h.top.length > 0 && (
                    <div className="space-y-1">
                      <div className="text-xs text-muted-foreground">Top would-be rules</div>
                      {h.top.map(([rule, n]) => (
                        <div key={rule} className="flex justify-between gap-2 text-xs">
                          <Mono className="truncate">{rule}</Mono>
                          <span className="tabular-nums text-muted-foreground">{n}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </CardContent>
                {h.observing.length > 0 && (
                  <CardFooter className="flex-col items-start gap-1.5">
                    <span className="text-xs text-muted-foreground">Each owner flips it on their machine:</span>
                    <Mono className="w-full rounded-md border bg-muted/50 px-2 py-1.5">rv host mode {h.host} block</Mono>
                  </CardFooter>
                )}
              </Card>
            )
          })}
        </div>

        <Section title="What observe would have blocked" description="Across all observing hosts, last 14 days">
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Rule</TableHead>
                  <TableHead className="text-right">Would-be blocks</TableHead>
                  <TableHead className="hidden text-right sm:table-cell">Machines</TableHead>
                  <TableHead className="hidden md:table-cell">Hosts</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {observedRules.map((r) => (
                  <TableRow key={r.rule.id}>
                    <TableCell>
                      <Mono>{r.rule.id}</Mono>
                      <div className="text-xs text-muted-foreground">{r.rule.description}</div>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{r.count}</TableCell>
                    <TableCell className="hidden text-right tabular-nums sm:table-cell">{r.machines}</TableCell>
                    <TableCell className="hidden md:table-cell">
                      <div className="flex flex-wrap gap-1">
                        {r.hosts.map((h) => (
                          <Badge key={h} variant="outline" className="font-normal">
                            {h}
                          </Badge>
                        ))}
                      </div>
                    </TableCell>
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
