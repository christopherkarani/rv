"use client"

import { useActionState, useState } from "react"
import { CheckIcon, CopyIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { createToken, deleteOrg, inviteMember, updateOrg, type ActionState } from "./actions"

function CopyBlock({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="group relative">
      <pre className="overflow-x-auto whitespace-pre rounded-lg border bg-muted/40 px-3 py-2.5 pr-10 font-mono text-xs leading-relaxed">{text}</pre>
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        aria-label={`Copy ${label}`}
        className="absolute right-1.5 top-1.5"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(text)
            setCopied(true)
            setTimeout(() => setCopied(false), 1500)
          } catch {
            // Clipboard blocked; the text is selectable.
          }
        }}
      >
        {copied ? <CheckIcon /> : <CopyIcon />}
      </Button>
    </div>
  )
}

export function OrgForm({ name, retention, maxRetention, editable }: { name: string; retention: number; maxRetention: number; editable: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(updateOrg, {})
  return (
    <form action={action} className="grid gap-4 sm:grid-cols-[1fr_160px_auto] sm:items-end">
      <div className="space-y-2">
        <Label htmlFor="org-name">Name</Label>
        <Input id="org-name" name="name" defaultValue={name} maxLength={100} disabled={!editable} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="retention">Keep events (days)</Label>
        <Input id="retention" name="retention" type="number" min={1} max={maxRetention} defaultValue={retention} disabled={!editable} />
      </div>
      {editable && (
        <Button type="submit" disabled={pending}>
          Save
        </Button>
      )}
      {(state.error || state.message) && (
        <p className={`text-sm sm:col-span-3 ${state.error ? "text-destructive" : "text-muted-foreground"}`}>{state.error ?? state.message}</p>
      )}
    </form>
  )
}

export function TokenForm({ appUrl }: { appUrl: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(createToken, {})
  if (state.token) {
    const enroll = `CRED=$(curl -fsS ${appUrl}/api/v1/enroll \\
  -H 'content-type: application/json' \\
  -d "{\\"token\\":\\"${state.token}\\",\\"name\\":\\"$(hostname -s)\\",\\"rvVersion\\":\\"$(rv --version 2>/dev/null)\\"}" \\
  | sed -E 's/.*"credential":"([^"]+)".*/\\1/')`
    const store = `printf %s "$CRED" | rv secrets set RV_CLOUD --environment --description "rv Cloud machine credential"`
    const forward = `rv audit forward --to ${appUrl}/api/v1/events --header 'Authorization=Bearer \${secret:RV_CLOUD}' --install`
    const report = `mkdir -p ~/.config/rv-cloud && umask 077 && printf 'Authorization: Bearer %s\\n' "$CRED" > ~/.config/rv-cloud/header
(crontab -l 2>/dev/null; echo "17 * * * * rv report --json | curl -fsS -X POST ${appUrl}/api/v1/report -H 'content-type: application/json' -H @$HOME/.config/rv-cloud/header --data-binary @- >/dev/null") | crontab -`
    return (
      <div className="space-y-4">
        <div className="rounded-lg border border-warning/40 bg-warning/5 p-3 text-sm">
          Copy this token now. rv Cloud stores only its hash and cannot show it again.
        </div>
        <CopyBlock text={state.token} label="token" />
        <div className="space-y-3 text-sm">
          <p className="font-medium">On each machine, with rv installed:</p>
          <p className="text-muted-foreground">1. Enroll and get this machine&apos;s credential</p>
          <CopyBlock text={enroll} label="enroll command" />
          <p className="text-muted-foreground">2. Keep the credential in the Keychain (Secret Service on Linux) as an rv secret</p>
          <CopyBlock text={store} label="store command" />
          <p className="text-muted-foreground">3. Forward the audit log every five minutes</p>
          <CopyBlock text={forward} label="forward command" />
          <p className="text-muted-foreground">4. Send an hourly posture report (until rv ships rv report --to)</p>
          <CopyBlock text={report} label="report command" />
        </div>
        <Button variant="outline" onClick={() => location.reload()}>
          Done
        </Button>
      </div>
    )
  }
  return (
    <form action={action} className="grid gap-4 sm:grid-cols-[1fr_120px_120px_auto] sm:items-end">
      <div className="space-y-2">
        <Label htmlFor="token-label">Label</Label>
        <Input id="token-label" name="label" maxLength={64} placeholder="Engineering laptops" />
      </div>
      <div className="space-y-2">
        <Label htmlFor="days">Expires in days</Label>
        <Input id="days" name="days" type="number" min={1} max={90} defaultValue={7} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="maxUses">Max machines</Label>
        <Input id="maxUses" name="maxUses" type="number" min={1} max={10000} defaultValue={100} />
      </div>
      <Button type="submit" disabled={pending}>
        Create token
      </Button>
      {state.error && <p className="text-sm text-destructive sm:col-span-4">{state.error}</p>}
    </form>
  )
}

export function InviteForm({ canInviteAdmins }: { canInviteAdmins: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(inviteMember, {})
  const [role, setRole] = useState("viewer")
  return (
    <form action={action} className="grid gap-3 sm:grid-cols-[1fr_130px_auto] sm:items-end">
      <div className="space-y-2">
        <Label htmlFor="invite-email">Email</Label>
        <Input id="invite-email" name="email" type="email" required placeholder="teammate@company.com" />
      </div>
      <div className="space-y-2">
        <Label>Role</Label>
        <input type="hidden" name="role" value={role} />
        <Select value={role} onValueChange={(v) => setRole(String(v))}>
          <SelectTrigger aria-label="Role">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="viewer">viewer</SelectItem>
            {canInviteAdmins && <SelectItem value="admin">admin</SelectItem>}
          </SelectContent>
        </Select>
      </div>
      <Button type="submit" disabled={pending}>
        Invite
      </Button>
      {(state.error || state.message) && (
        <p className={`text-sm sm:col-span-3 ${state.error ? "text-destructive" : "text-muted-foreground"}`}>{state.error ?? state.message}</p>
      )}
    </form>
  )
}

export function DeleteOrgForm({ slug }: { slug: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(deleteOrg, {})
  return (
    <form action={action} className="flex flex-wrap items-end gap-3">
      <div className="space-y-2">
        <Label htmlFor="confirm">
          Type <span className="font-mono">{slug}</span> to confirm
        </Label>
        <Input id="confirm" name="confirm" autoComplete="off" className="w-56 font-mono" />
      </div>
      <Button type="submit" variant="destructive" disabled={pending}>
        Delete organization
      </Button>
      {state.error && <p className="w-full text-sm text-destructive">{state.error}</p>}
    </form>
  )
}
