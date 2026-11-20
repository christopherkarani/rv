"use client"

import { useActionState, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { revokeMachine, setTeam, type ActionState } from "../actions"

export function TeamForm({ machineId, team }: { machineId: string; team: string | null }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setTeam, {})
  return (
    <form action={action} className="flex items-center gap-2">
      <input type="hidden" name="machineId" value={machineId} />
      <Input name="team" defaultValue={team ?? ""} placeholder="No team" maxLength={64} className="h-8 w-36" aria-label="Team" />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>
        Save
      </Button>
      {state.error && <span className="text-xs text-destructive">{state.error}</span>}
      {state.ok && <span className="text-xs text-muted-foreground">Saved</span>}
    </form>
  )
}

export function RevokeButton({ machineId, name }: { machineId: string; name: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(revokeMachine, {})
  const [confirming, setConfirming] = useState(false)
  if (!confirming) {
    return (
      <Button variant="destructive" onClick={() => setConfirming(true)}>
        Revoke credential
      </Button>
    )
  }
  return (
    <form action={action} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="machineId" value={machineId} />
      <span className="text-sm text-muted-foreground">
        {name} will stop being able to send data. Re-enrolling makes a new machine.
      </span>
      <Button type="submit" variant="destructive" disabled={pending}>
        {pending ? "Revoking…" : "Revoke"}
      </Button>
      <Button type="button" variant="ghost" onClick={() => setConfirming(false)}>
        Cancel
      </Button>
      {state.error && <span className="text-sm text-destructive">{state.error}</span>}
    </form>
  )
}
