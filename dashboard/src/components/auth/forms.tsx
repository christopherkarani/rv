"use client";

import { useActionState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { ArrowRight, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { loginAction, setupAction, type FormState } from "@/app/actions";

function FormError({ state }: { state: FormState }) {
  return (
    <AnimatePresence>
      {state?.error && (
        <motion.p
          role="alert"
          initial={{ opacity: 0, height: 0, x: 0 }}
          animate={{ opacity: 1, height: "auto", x: [0, -6, 6, -3, 3, 0] }}
          exit={{ opacity: 0, height: 0 }}
          transition={{ duration: 0.35 }}
          className="rounded-md border border-status-critical/30 bg-status-critical/10 px-3 py-2 text-sm"
        >
          {state.error}
        </motion.p>
      )}
    </AnimatePresence>
  );
}

function Field({ label, ...props }: React.ComponentProps<typeof Input> & { label: string }) {
  return (
    <div className="grid gap-1.5">
      <Label htmlFor={props.id} className="text-xs text-muted-foreground">{label}</Label>
      <Input className="h-9 bg-faint" {...props} />
    </div>
  );
}

export function LoginForm({ next }: { next?: string }) {
  const [state, action, pending] = useActionState(loginAction, undefined);
  return (
    <form action={action} className="grid gap-4">
      <input type="hidden" name="next" value={next ?? "/"} />
      <Field label="Email" id="email" name="email" type="email" autoComplete="username" required autoFocus defaultValue={state?.values?.email} />
      <Field label="Password" id="password" name="password" type="password" autoComplete="current-password" required autoFocus={!!state?.error} />
      <FormError state={state} />
      <Button type="submit" size="lg" disabled={pending} className="mt-1 h-9">
        {pending ? <Loader2 className="animate-spin" /> : null}
        Sign in
        {!pending && <ArrowRight />}
      </Button>
    </form>
  );
}

export function SetupForm() {
  const [state, action, pending] = useActionState(setupAction, undefined);
  return (
    <form action={action} className="grid gap-4">
      <Field label="Your name" id="name" name="name" autoComplete="name" required autoFocus defaultValue={state?.values?.name} />
      <Field label="Work email" id="email" name="email" type="email" autoComplete="username" required defaultValue={state?.values?.email} />
      <Field label="Password (12+ characters)" id="password" name="password" type="password" autoComplete="new-password" minLength={12} required />
      <FormError state={state} />
      <Button type="submit" size="lg" disabled={pending} className="mt-1 h-9">
        {pending ? <Loader2 className="animate-spin" /> : null}
        Create admin and continue
      </Button>
    </form>
  );
}
