"use client"

import { useActionState, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { createOrg, type CreateOrgState } from "../actions"

const slugify = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)

export function CreateOrgForm() {
  const [state, action, pending] = useActionState<CreateOrgState, FormData>(createOrg, {})
  const [name, setName] = useState("")
  const [slug, setSlug] = useState("")
  const [touched, setTouched] = useState(false)

  return (
    <form action={action} className="space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="name">Organization name</Label>
        <Input
          id="name"
          name="name"
          required
          maxLength={100}
          placeholder="Acme Engineering"
          value={name}
          onChange={(e) => {
            setName(e.target.value)
            if (!touched) setSlug(slugify(e.target.value))
          }}
        />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="slug">URL name</Label>
        <Input
          id="slug"
          name="slug"
          required
          pattern="[a-z0-9][a-z0-9\-]{1,38}[a-z0-9]"
          placeholder="acme"
          value={slug}
          onChange={(e) => {
            setTouched(true)
            setSlug(e.target.value)
          }}
          className="font-mono"
        />
        <p className="text-xs text-muted-foreground">Lowercase letters, digits and dashes.</p>
      </div>
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
      <Button type="submit" className="h-10 w-full" disabled={pending}>
        {pending ? "Creating…" : "Create organization"}
      </Button>
    </form>
  )
}
