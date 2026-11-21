"use client";

import { useActionState, useState, useTransition } from "react";
import { AnimatePresence, motion } from "motion/react";
import { KeyRound, Loader2, Plus, Trash2, UserPlus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { createTokenAction, createUserAction, deleteUserAction, revokeTokenAction } from "@/app/actions";
import { CodeBlock } from "./code-block";
import { StatusPill } from "./badges";
import { LocalTime } from "./local-time";

export function TokenCreator({ canEdit }: { canEdit: boolean }) {
  const [state, action, pending] = useActionState(createTokenAction, undefined);
  return (
    <div>
      <form action={action} className="flex flex-wrap items-center gap-2">
        <Input name="name" defaultValue={state?.values?.name} placeholder="Token name, e.g. engineering-macs" aria-label="Token name" maxLength={80} required disabled={!canEdit} className="h-8 max-w-xs bg-faint text-[12.5px]" />
        <Button type="submit" size="sm" disabled={pending || !canEdit}>
          {pending ? <Loader2 className="animate-spin" /> : <Plus />} Create ingest token
        </Button>
        {!canEdit && <span className="text-xs text-muted-foreground">Admins create tokens.</span>}
      </form>
      {state?.error && <p className="mt-2 text-xs text-status-critical">{state.error}</p>}
      <AnimatePresence>
        {state?.token && (
          <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: "auto" }} className="mt-3 overflow-hidden">
            <div className="rounded-lg border border-brand/40 bg-brand/6 p-3">
              <p className="mb-2 flex items-center gap-1.5 text-[12.5px] font-medium"><KeyRound className="size-3.5" /> Copy this token now. It will not be shown again.</p>
              <CodeBlock code={state.token} label="ingest token" />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export function RevokeButton({ id, name }: { id: string; name: string }) {
  const [pending, start] = useTransition();
  const [confirm, setConfirm] = useState(false);
  if (!confirm) {
    return <Button variant="ghost" size="xs" onClick={() => setConfirm(true)}>Revoke</Button>;
  }
  return (
    <span className="flex items-center gap-1">
      <Button variant="destructive" size="xs" disabled={pending} onClick={() => start(async () => { await revokeTokenAction(id); toast.success(`Revoked ${name}`); })}>
        {pending && <Loader2 className="animate-spin" />} Revoke {name}?
      </Button>
      <Button variant="ghost" size="xs" onClick={() => setConfirm(false)}>Cancel</Button>
    </span>
  );
}

export function UserCreator() {
  const [state, action, pending] = useActionState(createUserAction, undefined);
  const [role, setRole] = useState("viewer");
  return (
    <form action={action} className="grid gap-2 sm:grid-cols-[1fr_1.2fr_120px_1fr_auto]">
      <Input name="name" defaultValue={state?.values?.name} placeholder="Name" aria-label="Name" required className="h-8 bg-faint text-[12.5px]" />
      <Input name="email" defaultValue={state?.values?.email} type="email" placeholder="Email" aria-label="Email" required className="h-8 bg-faint text-[12.5px]" />
      <input type="hidden" name="role" value={role} />
      <Select value={role} onValueChange={setRole}>
        <SelectTrigger size="sm" aria-label="Role" className="h-8 bg-faint text-[12.5px]"><SelectValue /></SelectTrigger>
        <SelectContent>
          <SelectItem value="viewer">Viewer</SelectItem>
          <SelectItem value="admin">Admin</SelectItem>
        </SelectContent>
      </Select>
      <Input name="password" type="password" placeholder="Initial password (12+)" aria-label="Initial password" minLength={12} required autoComplete="new-password" className="h-8 bg-faint text-[12.5px]" />
      <Button type="submit" size="sm" disabled={pending}>{pending ? <Loader2 className="animate-spin" /> : <UserPlus />} Add</Button>
      {state?.error && <p className="text-xs text-status-critical sm:col-span-5">{state.error}</p>}
      {state?.ok && <p className="text-xs text-muted-foreground sm:col-span-5">User added. Share the password with them out of band.</p>}
    </form>
  );
}

export function RemoveUserButton({ id, email }: { id: string; email: string }) {
  const [pending, start] = useTransition();
  return (
    <Button variant="ghost" size="icon-xs" aria-label={`Remove ${email}`} disabled={pending}
      onClick={() => { if (window.confirm(`Remove ${email}? Their sessions end immediately.`)) start(async () => { await deleteUserAction(id); toast.success(`Removed ${email}`); }); }}>
      {pending ? <Loader2 className="animate-spin" /> : <Trash2 />}
    </Button>
  );
}

export function TokenStatus({ revokedAt, lastUsedAt }: { revokedAt: number | null; lastUsedAt: number | null }) {
  if (revokedAt) return <StatusPill status="neutral" label="Revoked" />;
  if (!lastUsedAt) return <StatusPill status="pending" label="Never used" />;
  return <StatusPill status="good" label={<>Used <LocalTime ms={lastUsedAt} /></>} />;
}
