import { Suspense } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { EmptyState, Mono, PageBody, PageHeader, Section, Skeleton, Status } from "@/components/shared"
import { getServerEnv } from "@/lib/env"
import { listMachines, policyRevisions, signingKeys } from "@/lib/queries"
import { getSession } from "@/lib/session"
import { canAdmin } from "@/lib/vocab"
import { removeSigningKey } from "./actions"
import { PolicyEditor } from "./policy-editor"
import { AddKeyForm, UploadForm } from "./policy-forms"

const fmt = (iso: string) => new Date(iso).toISOString().replace("T", " ").slice(0, 16) + " UTC"

async function Policy() {
  const { org } = await getSession()
  const [revisions, keys, machines] = await Promise.all([policyRevisions(org.orgId), signingKeys(org.orgId), listMachines(org.orgId)])
  const current = revisions[0]?.serial ?? null
  const onSerial = new Map<number, number>()
  for (const m of machines) {
    const s = m.latest_report?.managed?.state === "active" ? m.latest_report.managed.serial : undefined
    if (typeof s === "number" && !m.revoked_at) onSerial.set(s, (onSerial.get(s) ?? 0) + 1)
  }
  const forwardUrl = `${getServerEnv().APP_URL.replace(/\/$/, "")}/api/v1/events`
  const admin = canAdmin(org.role)
  const owner = org.role === "owner"

  return (
    <div className="space-y-12">
      <PolicyEditor orgName={org.name} nextSerial={(current ?? 0) + 1} forwardUrl={forwardUrl} />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Upload a signed bundle</CardTitle>
            <CardDescription>
              {keys.length === 0
                ? "Pin a public key first, so rv Cloud can check the signature."
                : "rv Cloud verifies the signature against your pinned keys and refuses an older serial."}
            </CardDescription>
          </CardHeader>
          <CardContent>{admin ? <UploadForm disabled={keys.length === 0} /> : <p className="text-sm text-muted-foreground">Only owners and admins can upload.</p>}</CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Signing keys</CardTitle>
            <CardDescription>
              The contents of <Mono>org-key.pub</Mono> from <Mono>rv managed keygen</Mono>. Only owners can change them.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {keys.length > 0 && (
              <div className="divide-y rounded-lg border">
                {keys.map((k) => (
                  <div key={k.id} className="flex items-center gap-3 p-3 text-sm">
                    <div className="min-w-0 flex-1">
                      <div className="font-medium">{k.label ?? "Unlabeled key"}</div>
                      <Mono className="block truncate text-xs text-muted-foreground">{k.public_key}</Mono>
                    </div>
                    {owner && (
                      <form action={removeSigningKey}>
                        <input type="hidden" name="id" value={k.id} />
                        <Button type="submit" variant="ghost" size="sm" className="text-destructive">
                          Remove
                        </Button>
                      </form>
                    )}
                  </div>
                ))}
              </div>
            )}
            {owner && <AddKeyForm />}
          </CardContent>
        </Card>
      </div>

      <Section title="Revisions" description="Machines report the serial they enforce; the count is from each machine's latest report.">
        {revisions.length === 0 ? (
          <EmptyState title="No policy uploaded yet">Build one above, sign it with rv, and upload it.</EmptyState>
        ) : (
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Serial</TableHead>
                  <TableHead>Contents</TableHead>
                  <TableHead className="hidden md:table-cell">Uploaded</TableHead>
                  <TableHead className="text-right">Machines</TableHead>
                  <TableHead className="text-right">Files</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {revisions.map((r) => (
                  <TableRow key={r.id}>
                    <TableCell>
                      <Status tone={r.serial === current ? "success" : "neutral"}>
                        <Mono>{r.serial}</Mono>
                      </Status>
                    </TableCell>
                    <TableCell className="max-w-96 truncate">{r.summary}</TableCell>
                    <TableCell className="hidden text-muted-foreground md:table-cell">{fmt(r.uploaded_at)}</TableCell>
                    <TableCell className="text-right tabular-nums">{onSerial.get(r.serial) ?? 0}</TableCell>
                    <TableCell className="space-x-1 text-right">
                      <Button variant="ghost" size="xs" render={<a href={`/api/policy/${r.serial}?file=policy.json`} download />}>
                        json
                      </Button>
                      <Button variant="ghost" size="xs" render={<a href={`/api/policy/${r.serial}?file=policy.json.sig`} download />}>
                        sig
                      </Button>
                      <Button variant="ghost" size="xs" render={<a href={`/api/policy/${r.serial}?file=org-key.pub`} download />}>
                        key
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Section>
    </div>
  )
}

export default function PolicyPage() {
  return (
    <>
      <PageHeader
        title="Policy"
        description="Build the organization policy rv enforces on every machine. Restrict-only: user config can never loosen it."
      />
      <PageBody>
        <Suspense fallback={<Skeleton className="h-[600px] w-full rounded-xl" />}>
          <Policy />
        </Suspense>
      </PageBody>
    </>
  )
}
