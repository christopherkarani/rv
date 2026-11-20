import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Mono, PageBody, PageHeader } from "@/components/shared"

function CodeLine({ children }: { children: React.ReactNode }) {
  return (
    <pre className="overflow-x-auto rounded-lg border bg-muted/40 px-3 py-2.5 font-mono text-xs">
      <span className="select-none text-muted-foreground">$ </span>
      {children}
    </pre>
  )
}

export default function SettingsPage() {
  return (
    <>
      <PageHeader title="Settings" description="Enrollment, data retention and access for Acme Engineering." />
      <PageBody className="max-w-3xl space-y-6">
        <Card>
          <CardHeader>
            <CardTitle>Enroll machines</CardTitle>
            <CardDescription>
              Run once per machine, or push it through your MDM. The org token is exchanged for a per-machine credential stored in the
              Keychain or Secret Service.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <CodeLine>curl -fsSL https://rykanv.com/install | RV_INSTALL_MODE=observe sh</CodeLine>
            <CodeLine>rv cloud enroll rvc_enr_4Jq8…9xT2</CodeLine>
            <p className="text-xs text-muted-foreground">
              Installing in observe mode lets your team see what rv would block before anything is blocked. <Mono>rv cloud enroll</Mono> is
              the planned client command from the spec.
            </p>
          </CardContent>
          <CardFooter className="justify-between gap-2">
            <span className="text-xs text-muted-foreground">Token expires in 7 days · 31 of 100 uses left</span>
            <Button variant="outline" size="sm">
              Rotate token
            </Button>
          </CardFooter>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Retention</CardTitle>
            <CardDescription>How long rv Cloud keeps forwarded events. Your Business plan allows up to 365 days.</CardDescription>
          </CardHeader>
          <CardContent className="flex items-end gap-3">
            <div className="space-y-2">
              <Label htmlFor="retention">Days</Label>
              <Input id="retention" type="number" defaultValue={365} className="w-28" />
            </div>
          </CardContent>
          <CardFooter className="justify-end">
            <Button size="sm">Save</Button>
          </CardFooter>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>What rv Cloud receives</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-6 text-sm sm:grid-cols-2">
            <div>
              <div className="mb-2 font-medium">Receives</div>
              <ul className="space-y-1 text-muted-foreground">
                <li>Rule ids and agent host names</li>
                <li>Machine and user names</li>
                <li>Home-relative paths of blocked secret files</li>
                <li>Secret and MCP server names, config hashes, counts</li>
              </ul>
            </div>
            <div>
              <div className="mb-2 font-medium">Never receives</div>
              <ul className="space-y-1 text-muted-foreground">
                <li>Commands or prompts</li>
                <li>File contents</li>
                <li>MCP argument values</li>
                <li>Secret values</li>
              </ul>
            </div>
          </CardContent>
        </Card>

        <Card className="border-destructive/40">
          <CardHeader>
            <CardTitle>Delete organization</CardTitle>
            <CardDescription>Deletes all stored events, reports and policy revisions. Machines keep enforcing their installed policy.</CardDescription>
          </CardHeader>
          <CardFooter className="justify-end">
            <Button variant="destructive" size="sm">
              Delete organization
            </Button>
          </CardFooter>
        </Card>
      </PageBody>
    </>
  )
}
