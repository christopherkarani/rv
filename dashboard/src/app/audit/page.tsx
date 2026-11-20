import Link from "next/link"
import { PlusIcon } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Mono, PageBody, PageHeader, Section, Stat, StatGrid, Status } from "@/components/shared"
import { MACHINES, SIEM_TARGETS, isOnline, timeAgo } from "@/lib/data"

export default function AuditPage() {
  const intact = MACHINES.filter((m) => m.audit.chainIntact === true)
  const broken = MACHINES.filter((m) => m.audit.chainIntact === false)
  const unreadable = MACHINES.filter((m) => m.audit.chainIntact === null)
  const stale = MACHINES.filter((m) => !isOnline(m))
  const problems = [...broken, ...unreadable, ...stale.filter((m) => m.audit.chainIntact === true)]

  return (
    <>
      <PageHeader
        title="Audit"
        description="rv's audit log is a SHA-256 hash chain on each machine. rv Cloud keeps every chain head off the machine, so a rewritten or truncated log shows up here."
        actions={<Button variant="outline">Export JSONL</Button>}
      />
      <PageBody className="space-y-10">
        <StatGrid>
          <Stat label="Chains intact" tone="success" value={intact.length} sub="Head advanced on schedule" />
          <Stat label="Chains broken" tone={broken.length ? "error" : "success"} value={broken.length} sub="Edit, deletion or reorder detected" />
          <Stat label="Unreadable" tone={unreadable.length ? "warning" : "success"} value={unreadable.length} sub="audit.jsonl could not be read" />
          <Stat label="Stopped forwarding" tone={stale.length ? "warning" : "success"} value={stale.length} sub="No events for over 24 hours" />
        </StatGrid>

        <Section title="Chains to investigate" description="A head that moves backwards or forks means the log was rewritten on the machine.">
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Machine</TableHead>
                  <TableHead>Finding</TableHead>
                  <TableHead className="hidden md:table-cell">Last head seen</TableHead>
                  <TableHead className="text-right">Last event</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {problems.map((m) => (
                  <TableRow key={m.id}>
                    <TableCell>
                      <Link href={`/machines/${m.id}`} className="font-medium hover:underline">
                        {m.name}
                      </Link>
                      <div className="text-xs text-muted-foreground">{m.team}</div>
                    </TableCell>
                    <TableCell>
                      {m.audit.chainIntact === false ? (
                        <Status tone="error">Chain broken</Status>
                      ) : m.audit.chainIntact === null ? (
                        <Status tone="warning">Log unreadable</Status>
                      ) : (
                        <Status tone="neutral">Stopped forwarding</Status>
                      )}
                    </TableCell>
                    <TableCell className="hidden md:table-cell">
                      <Mono className="text-muted-foreground">{m.audit.chainHead.slice(0, 16)}…</Mono>
                    </TableCell>
                    <TableCell className="text-right text-muted-foreground">{timeAgo(Date.parse(m.audit.lastEventAt))}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Section>

        <Section
          title="SIEM destinations"
          description="Events are forwarded as received; OCSF 1.3.0 keeps a stable reason code in status_code."
          action={
            <Button size="sm" variant="outline">
              <PlusIcon />
              Add destination
            </Button>
          }
        >
          <div className="grid gap-4 md:grid-cols-2">
            {SIEM_TARGETS.map((t) => (
              <Card key={t.name} size="sm">
                <CardHeader>
                  <div className="flex items-center justify-between">
                    <CardTitle>{t.name}</CardTitle>
                    <Status tone={t.status === "healthy" ? "success" : "warning"}>{t.status === "healthy" ? "Healthy" : "Retrying"}</Status>
                  </div>
                  <CardDescription>
                    <Mono className="break-all">{t.url}</Mono>
                  </CardDescription>
                </CardHeader>
                <CardContent className="flex items-center justify-between text-sm text-muted-foreground">
                  <Badge variant="secondary" className="font-normal">
                    {t.format}
                  </Badge>
                  Last delivery {timeAgo(t.lastDelivery)}
                </CardContent>
              </Card>
            ))}
          </div>
        </Section>
      </PageBody>
    </>
  )
}
