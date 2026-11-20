import { Suspense } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Mono, PageBody, PageHeader, Skeleton, Status } from "@/components/shared"
import { getServerEnv } from "@/lib/env"
import { timeAgo } from "@/lib/machine-status"
import { RETENTION_LIMIT } from "@/lib/plans"
import { adminAudit, enrollmentTokens, invites, members, orgSettings } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"
import { canAdmin } from "@/lib/vocab"
import { cancelInvite, changeRole, removeMember, revokeToken } from "./actions"
import { DeleteOrgForm, InviteForm, OrgForm, TokenForm } from "./forms"

const fmt = (iso: string) => new Date(iso).toISOString().replace("T", " ").slice(0, 16) + " UTC"

async function Settings({ searchParams }: { searchParams: PageProps<"/settings">["searchParams"] }) {
  const sp = await searchParams
  const s = await getSession()
  const admin = canAdmin(s.org.role)
  const owner = s.org.role === "owner"
  const now = requestTime()
  const [org, people, pending, tokens, log] = await Promise.all([
    orgSettings(s.org.orgId),
    members(s.org.orgId),
    admin ? invites(s.org.orgId) : Promise.resolve([]),
    admin ? enrollmentTokens(s.org.orgId) : Promise.resolve([]),
    admin ? adminAudit(s.org.orgId, 30) : Promise.resolve([]),
  ])
  const appUrl = getServerEnv().APP_URL.replace(/\/$/, "")

  return (
    <div className="space-y-6">
      {sp.welcome && (
        <div className="rounded-xl border border-info/30 bg-info/5 p-4 text-sm">
          <div className="font-medium">Welcome to rv Cloud</div>
          <p className="mt-1 text-muted-foreground">Create an enrollment token below and follow the steps on each machine. Activity appears within five minutes.</p>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Organization</CardTitle>
          <CardDescription>
            <Mono>{org.slug}</Mono> · <span className="capitalize">{org.plan}</span> plan · created {timeAgo(org.created_at, now)}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <OrgForm name={org.name} retention={org.retention_days} maxRetention={RETENTION_LIMIT[org.plan] ?? 30} editable={admin} />
        </CardContent>
      </Card>

      {admin && (
        <Card>
          <CardHeader>
            <CardTitle>Enroll machines</CardTitle>
            <CardDescription>
              An enrollment token lets machines join this organization. Each machine trades it for its own credential, which you can revoke on its page.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-5">
            <TokenForm appUrl={appUrl} />
            {tokens.length > 0 && (
              <div className="divide-y rounded-lg border text-sm">
                {tokens.map((t) => {
                  const expired = Date.parse(t.expires_at) <= now
                  const live = !t.revoked_at && !expired && t.uses < t.max_uses
                  return (
                    <div key={t.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 p-3">
                      <Mono className="w-36 shrink-0">{t.prefix}…</Mono>
                      <span className="min-w-0 flex-1 truncate">{t.label ?? <span className="text-muted-foreground">No label</span>}</span>
                      <span className="text-muted-foreground tabular-nums">
                        {t.uses}/{t.max_uses} used
                      </span>
                      <Status tone={live ? "success" : "neutral"}>
                        {t.revoked_at ? "Revoked" : expired ? "Expired" : t.uses >= t.max_uses ? "Used up" : `Expires ${fmt(t.expires_at).slice(0, 10)}`}
                      </Status>
                      {live && (
                        <form action={revokeToken}>
                          <input type="hidden" name="id" value={t.id} />
                          <Button type="submit" variant="ghost" size="sm" className="text-destructive">
                            Revoke
                          </Button>
                        </form>
                      )}
                    </div>
                  )
                })}
              </div>
            )}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Members</CardTitle>
          <CardDescription>Owners manage everything. Admins enroll machines, upload policy and invite viewers. Viewers read.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-5">
          <div className="divide-y rounded-lg border text-sm">
            {people.map((p) => (
              <div key={p.user_id} className="flex flex-wrap items-center gap-3 p-3">
                <span className="min-w-0 flex-1 truncate">
                  {p.email}
                  {p.user_id === s.userId && <span className="text-muted-foreground"> (you)</span>}
                </span>
                {owner && p.user_id !== s.userId ? (
                  <form action={changeRole} className="flex items-center gap-1">
                    <input type="hidden" name="userId" value={p.user_id} />
                    <select
                      name="role"
                      defaultValue={p.role}
                      aria-label={`Role for ${p.email}`}
                      className="h-8 rounded-md border bg-background px-2 text-sm"
                    >
                      <option value="owner">owner</option>
                      <option value="admin">admin</option>
                      <option value="viewer">viewer</option>
                    </select>
                    <Button type="submit" variant="ghost" size="sm">
                      Set
                    </Button>
                  </form>
                ) : (
                  <Badge variant="outline" className="font-normal capitalize">
                    {p.role}
                  </Badge>
                )}
                {(p.user_id === s.userId || owner || (s.org.role === "admin" && p.role === "viewer")) && (
                  <form action={removeMember}>
                    <input type="hidden" name="userId" value={p.user_id} />
                    <Button type="submit" variant="ghost" size="sm" className="text-destructive">
                      {p.user_id === s.userId ? "Leave" : "Remove"}
                    </Button>
                  </form>
                )}
              </div>
            ))}
          </div>
          {admin && (
            <>
              <InviteForm canInviteAdmins={owner} />
              {pending.length > 0 && (
                <div className="divide-y rounded-lg border text-sm">
                  {pending.map((i) => (
                    <div key={i.id} className="flex flex-wrap items-center gap-3 p-3">
                      <span className="min-w-0 flex-1 truncate">{i.email}</span>
                      <Badge variant="outline" className="font-normal">
                        {i.role}
                      </Badge>
                      <span className="text-muted-foreground">invited {timeAgo(i.created_at, now)}</span>
                      <form action={cancelInvite}>
                        <input type="hidden" name="id" value={i.id} />
                        <Button type="submit" variant="ghost" size="sm">
                          Cancel
                        </Button>
                      </form>
                    </div>
                  ))}
                </div>
              )}
              <p className="text-xs text-muted-foreground">
                Invitees join when they sign in at <Mono>{appUrl}/login</Mono> with the invited email.
              </p>
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>What rv Cloud receives</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-6 text-sm sm:grid-cols-2">
          <div>
            <div className="mb-2 font-medium">Receives</div>
            <ul className="space-y-1 text-muted-foreground">
              <li>Rule ids, agent host names and decisions</li>
              <li>Machine host names and OS user names</li>
              <li>Home-relative paths of blocked secret files</li>
              <li>Secret and MCP server names, config file hashes, counts</li>
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

      {admin && log.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Admin log</CardTitle>
            <CardDescription>Changes made in this dashboard and machine enrollments, newest first.</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="divide-y rounded-lg border text-sm">
              {log.map((l) => (
                <div key={l.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 p-3">
                  <span className="w-40 shrink-0 text-muted-foreground">{fmt(l.at)}</span>
                  <Mono>{l.action}</Mono>
                  <span className="min-w-0 flex-1 truncate">{l.target}</span>
                  <span className="text-muted-foreground">{l.actor_email ?? "machine"}</span>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      {owner && (
        <Card className="border-destructive/40">
          <CardHeader>
            <CardTitle>Delete organization</CardTitle>
            <CardDescription>
              Deletes every stored event, report, policy revision and machine credential. Machines keep enforcing the policy they already have.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <DeleteOrgForm slug={org.slug} />
          </CardContent>
        </Card>
      )}
    </div>
  )
}

export default function SettingsPage({ searchParams }: PageProps<"/settings">) {
  return (
    <>
      <PageHeader title="Settings" description="Enrollment, members, retention and access for this organization." />
      <PageBody className="max-w-4xl">
        <Suspense fallback={<Skeleton className="h-96 w-full rounded-xl" />}>
          <Settings searchParams={searchParams} />
        </Suspense>
      </PageBody>
    </>
  )
}
