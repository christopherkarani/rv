"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { safeNext } from "@/lib/safe-next";
import {
  createFirstAdmin, createUser, currentUser, deleteUser, login, logout, requireAdmin, revokeSessions, startSessionFor, userCount,
} from "@/lib/server/auth";
import { logConsoleAction } from "@/lib/server/db";
import { createToken, revokeToken } from "@/lib/server/tokens";
import { createDestination, deleteDestination, sendTest, setDestinationEnabled, updateRule } from "@/lib/server/alerts";

/** `values` echoes what was typed (never passwords): React resets a form after its action runs. */
export type FormState = { error?: string; ok?: boolean; token?: string; values?: Record<string, string> } | undefined;

const echo = (form: FormData, ...keys: string[]) =>
  Object.fromEntries(keys.map((k) => [k, String(form.get(k) ?? "").slice(0, 254)]));

const credentials = z.object({
  email: z.email("Enter a valid email").max(254),
  password: z.string().min(1, "Enter your password").max(512),
});

export async function loginAction(_: FormState, form: FormData): Promise<FormState> {
  const parsed = credentials.safeParse({ email: form.get("email"), password: form.get("password") });
  if (!parsed.success) return { error: parsed.error.issues[0].message, values: echo(form, "email") };
  const result = await login(parsed.data.email, parsed.data.password);
  if (!result.ok) return { error: result.error, values: echo(form, "email") };
  redirect(safeNext(String(form.get("next") ?? "/")));
}

const newAdmin = z.object({
  name: z.string().trim().min(1, "Enter your name").max(80),
  email: z.email("Enter a valid email").max(254),
  password: z.string().min(12, "Use at least 12 characters").max(512),
});

/** First-run only: creates the first admin while the console has no users. */
export async function setupAction(_: FormState, form: FormData): Promise<FormState> {
  if (userCount() > 0) return { error: "Setup is already complete. Sign in instead." };
  const parsed = newAdmin.safeParse({ name: form.get("name"), email: form.get("email"), password: form.get("password") });
  if (!parsed.success) return { error: parsed.error.issues[0].message, values: echo(form, "name", "email") };
  const user = await createFirstAdmin(parsed.data);
  if (!user) return { error: "Setup is already complete. Sign in instead." };
  logConsoleAction(user.email, "user.created", `${user.email} (admin, first run)`);
  await startSessionFor(user.id);
  redirect("/settings?welcome=1");
}

export async function logoutAction() {
  const user = await currentUser();
  if (user) logConsoleAction(user.email, "session.logout");
  await logout();
  redirect("/login");
}

export async function createTokenAction(_: FormState, form: FormData): Promise<FormState> {
  const admin = await requireAdmin();
  const name = z.string().trim().min(1, "Name the token").max(80).safeParse(form.get("name"));
  if (!name.success) return { error: name.error.issues[0].message, values: echo(form, "name") };
  const { token } = createToken(name.data, admin.email);
  revalidatePath("/settings");
  return { ok: true, token };
}

export async function revokeTokenAction(id: string) {
  const admin = await requireAdmin();
  revokeToken(id, admin.email);
  revalidatePath("/settings");
}

const newUser = z.object({
  name: z.string().trim().min(1, "Enter a name").max(80),
  email: z.email("Enter a valid email").max(254),
  role: z.enum(["admin", "viewer"]),
  password: z.string().min(12, "Use at least 12 characters").max(512),
});

export async function createUserAction(_: FormState, form: FormData): Promise<FormState> {
  const admin = await requireAdmin();
  const parsed = newUser.safeParse({
    name: form.get("name"), email: form.get("email"), role: form.get("role"), password: form.get("password"),
  });
  if (!parsed.success) return { error: parsed.error.issues[0].message, values: echo(form, "name", "email", "role") };
  try {
    const user = await createUser(parsed.data);
    logConsoleAction(admin.email, "user.created", `${user.email} (${user.role})`);
  } catch {
    return { error: "A user with that email already exists.", values: echo(form, "name", "email", "role") };
  }
  revalidatePath("/settings");
  return { ok: true };
}

export async function deleteUserAction(id: string) {
  const admin = await requireAdmin();
  if (id === admin.id) throw new Error("You cannot remove your own account");
  revokeSessions(id);
  deleteUser(id);
  logConsoleAction(admin.email, "user.removed", id);
  revalidatePath("/settings");
}

// --- alerts -------------------------------------------------------------------

const newDestination = z.object({
  name: z.string().trim().min(1, "Name the destination").max(80),
  kind: z.enum(["slack", "webhook"]),
  url: z.string().trim().min(1, "Enter the webhook URL").max(2048),
  minSeverity: z.enum(["critical", "high", "medium"]),
});

export type DestinationFormState = { error?: string; ok?: boolean; signingSecret?: string | null; values?: Record<string, string> } | undefined;

export async function createDestinationAction(_: DestinationFormState, form: FormData): Promise<DestinationFormState> {
  const admin = await requireAdmin();
  const parsed = newDestination.safeParse({
    name: form.get("name"), kind: form.get("kind"), url: form.get("url"), minSeverity: form.get("minSeverity"),
  });
  const values = echo(form, "name", "kind", "minSeverity");
  if (!parsed.success) return { error: parsed.error.issues[0].message, values };
  const result = createDestination(parsed.data, admin.email);
  if (!result.ok) return { error: result.error, values };
  revalidatePath("/alerts");
  return { ok: true, signingSecret: result.signingSecret };
}

export async function toggleDestinationAction(id: string, enabled: boolean) {
  const admin = await requireAdmin();
  setDestinationEnabled(id, enabled, admin.email);
  revalidatePath("/alerts");
}

export async function deleteDestinationAction(id: string) {
  const admin = await requireAdmin();
  deleteDestination(id, admin.email);
  revalidatePath("/alerts");
}

export async function testDestinationAction(id: string) {
  const admin = await requireAdmin();
  const result = await sendTest(id, admin.email);
  revalidatePath("/alerts");
  return result;
}

const ruleIds = z.enum(["chain.break", "secret.misuse", "mcp.forged", "gate.loosened", "device.noncompliant", "blocks.spike", "device.silent"]);

export async function updateRuleAction(id: string, patch: { enabled?: boolean; threshold?: number }) {
  const admin = await requireAdmin();
  const rule = ruleIds.parse(id);
  const clean = z.object({ enabled: z.boolean().optional(), threshold: z.number().int().positive().max(100_000).optional() }).parse(patch);
  updateRule(rule, clean, admin.email);
  revalidatePath("/alerts");
}
