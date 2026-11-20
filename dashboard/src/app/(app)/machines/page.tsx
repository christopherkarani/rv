import { Suspense } from "react"
import { DownloadIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { PageBody, PageHeader, TableSkeleton } from "@/components/shared"
import { assess, newestVersion, timeAgo } from "@/lib/machine-status"
import { currentPolicySerial, listMachines } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"
import { MachinesTable, type MachineListItem } from "./machines-table"

async function Machines() {
  const { org } = await getSession()
  const now = requestTime()
  const [machines, serial] = await Promise.all([listMachines(org.orgId), currentPolicySerial(org.orgId)])
  const latest = newestVersion(machines.map((m) => m.rv_version))
  const items: MachineListItem[] = machines.map((m) => {
    const a = assess(m, { now, currentSerial: serial, latestVersion: latest })
    return {
      id: m.id,
      name: m.name,
      team: m.team,
      platform: m.platform,
      rvVersion: m.rv_version,
      outdated: Boolean(latest && m.rv_version && m.rv_version !== latest),
      policy: m.latest_report?.managed?.state === "active" ? `serial ${m.latest_report.managed.serial ?? "?"}` : (m.latest_report?.managed?.state ?? null),
      policyBad: m.latest_report?.managed?.state === "invalid",
      hosts: m.latest_report?.hosts ?? null,
      lastSeen: timeAgo(m.last_seen_at, now),
      lastSeenAt: m.last_seen_at,
      state: a.state,
      label: a.label,
      tone: a.tone,
      issues: a.issues,
    }
  })
  return <MachinesTable items={items} latestVersion={latest} />
}

export default function MachinesPage() {
  return (
    <>
      <PageHeader
        title="Machines"
        description="Every enrolled machine, from its latest rv report."
        actions={
          <Button variant="outline" render={<a href="/api/export/machines" download />}>
            <DownloadIcon />
            Export CSV
          </Button>
        }
      />
      <PageBody>
        <Suspense fallback={<TableSkeleton rows={8} />}>
          <Machines />
        </Suspense>
      </PageBody>
    </>
  )
}
