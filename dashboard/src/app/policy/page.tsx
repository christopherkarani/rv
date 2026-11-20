import { UploadIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Mono, PageBody, PageHeader, Section, Status } from "@/components/shared"
import { MACHINES, POLICY_REVISIONS, fmtTime } from "@/lib/data"
import { PolicyEditor } from "./policy-editor"

export default function PolicyPage() {
  const reporting = MACHINES.filter((m) => m.managed.status === "verified").length
  return (
    <>
      <PageHeader
        title="Policy"
        description="Build the organization policy rv enforces on every machine. Restrict-only: user config can never loosen it."
        actions={
          <Button variant="outline">
            <UploadIcon />
            Upload signed bundle
          </Button>
        }
      />
      <PageBody className="space-y-12">
        <PolicyEditor />
        <Section title="Revisions" description={`${reporting} of ${MACHINES.length} machines report a verified policy`}>
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Serial</TableHead>
                  <TableHead>Change</TableHead>
                  <TableHead className="hidden md:table-cell">Signed by</TableHead>
                  <TableHead className="hidden sm:table-cell">Uploaded</TableHead>
                  <TableHead className="text-right">Machines on it</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {POLICY_REVISIONS.map((r, i) => (
                  <TableRow key={r.serial}>
                    <TableCell>
                      <Status tone={i === 0 ? "success" : "neutral"}>
                        <Mono>{r.serial}</Mono>
                      </Status>
                    </TableCell>
                    <TableCell>{r.summary}</TableCell>
                    <TableCell className="hidden md:table-cell">
                      <Mono className="text-muted-foreground">{r.signer}</Mono>
                    </TableCell>
                    <TableCell className="hidden text-muted-foreground sm:table-cell">
                      {fmtTime(r.uploadedAt)} · {r.author}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{r.machines}</TableCell>
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
