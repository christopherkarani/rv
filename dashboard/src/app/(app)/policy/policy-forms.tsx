"use client"

import { useActionState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { addSigningKey, uploadPolicy, type ActionState } from "./actions"

export function UploadForm({ disabled }: { disabled: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(uploadPolicy, {})
  return (
    <form action={action} className="space-y-4">
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="policy">policy.json</Label>
          <Input id="policy" name="policy" type="file" accept=".json,application/json" required disabled={disabled} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="signature">policy.json.sig</Label>
          <Input id="signature" name="signature" type="file" accept=".sig,text/plain" required disabled={disabled} />
        </div>
      </div>
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
      {state.ok && <p className="text-sm text-success">{state.message}</p>}
      <Button type="submit" disabled={pending || disabled}>
        {pending ? "Verifying…" : "Verify and upload"}
      </Button>
    </form>
  )
}

export function AddKeyForm() {
  const [state, action, pending] = useActionState<ActionState, FormData>(addSigningKey, {})
  return (
    <form action={action} className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-[1fr_160px]">
        <div className="space-y-2">
          <Label htmlFor="publicKey">Public key (base64)</Label>
          <Input id="publicKey" name="publicKey" required placeholder="from org-key.pub" className="font-mono text-xs" autoComplete="off" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="label">Label</Label>
          <Input id="label" name="label" maxLength={64} placeholder="2026 key" />
        </div>
      </div>
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
      <Button type="submit" variant="outline" disabled={pending}>
        Pin key
      </Button>
    </form>
  )
}
