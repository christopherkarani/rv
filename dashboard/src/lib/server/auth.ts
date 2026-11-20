import "server-only";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";
import { config, sessionSecret } from "./config";
import { db, logConsoleAction } from "./db";
import { hashPassword, newId, safeEqual, sha256Hex, sign, verifyPassword } from "./crypto";

export const SESSION_COOKIE = "rvc_session";
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

export type Role = "admin" | "viewer";
export interface User {
  id: string;
  email: string;
  name: string;
  role: Role;
  createdAt: number;
  lastLoginAt: number | null;
}

interface UserRow {
  id: string; email: string; name: string; role: Role; password_hash: string;
  session_epoch: number; created_at: number; last_login_at: number | null;
}

const toUser = (row: UserRow): User => ({
  id: row.id, email: row.email, name: row.name, role: row.role, createdAt: row.created_at, lastLoginAt: row.last_login_at,
});

export function userCount(): number {
  return (db().prepare("SELECT COUNT(*) AS n FROM users").get() as { n: number }).n;
}

export function listUsers(): User[] {
  return (db().prepare("SELECT * FROM users ORDER BY created_at").all() as unknown as UserRow[]).map(toUser);
}

export async function createUser(input: { email: string; name: string; role: Role; password: string }): Promise<User> {
  const id = newId("usr");
  const hash = await hashPassword(input.password);
  db().prepare("INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)")
    .run(id, input.email.trim(), input.name.trim(), input.role, hash, Date.now());
  return toUser(db().prepare("SELECT * FROM users WHERE id = ?").get(id) as unknown as UserRow);
}

/**
 * First-run only. The password is hashed before the check, so the check and
 * the insert run with no await between them: two concurrent setups cannot
 * both create an admin.
 */
export async function createFirstAdmin(input: { email: string; name: string; password: string }): Promise<User | null> {
  const hash = await hashPassword(input.password);
  if (userCount() > 0) return null;
  const id = newId("usr");
  db().prepare("INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, 'admin', ?, ?)")
    .run(id, input.email.trim(), input.name.trim(), hash, Date.now());
  return toUser(db().prepare("SELECT * FROM users WHERE id = ?").get(id) as unknown as UserRow);
}

export function deleteUser(id: string) {
  db().prepare("DELETE FROM users WHERE id = ?").run(id);
}

/** Seeds the first admin from RV_CONSOLE_ADMIN_EMAIL / _PASSWORD when no user exists. */
export async function ensureBootstrapAdmin() {
  const email = process.env.RV_CONSOLE_ADMIN_EMAIL;
  const password = process.env.RV_CONSOLE_ADMIN_PASSWORD;
  if (!email || !password || userCount() > 0) return;
  await createUser({ email, name: "Administrator", role: "admin", password });
  logConsoleAction("bootstrap", "user.created", email);
}

// --- sessions -------------------------------------------------------------

function encodeSession(user: UserRow): string {
  const payload = Buffer.from(JSON.stringify({ u: user.id, e: user.session_epoch, x: Date.now() + SESSION_TTL_MS })).toString("base64url");
  return `${payload}.${sign(payload, sessionSecret())}`;
}

function decodeSession(value: string | undefined): { u: string; e: number; x: number } | null {
  if (!value) return null;
  const [payload, mac] = value.split(".");
  if (!payload || !mac || !safeEqual(mac, sign(payload, sessionSecret()))) return null;
  try {
    const data = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (typeof data.u !== "string" || typeof data.x !== "number" || data.x < Date.now()) return null;
    return data;
  } catch {
    return null;
  }
}

/** The signed-in user, or null. Cached per request. */
export const currentUser = cache(async (): Promise<User | null> => {
  const store = await cookies();
  const session = decodeSession(store.get(SESSION_COOKIE)?.value);
  if (!session) return null;
  const row = db().prepare("SELECT * FROM users WHERE id = ?").get(session.u) as UserRow | undefined;
  if (!row || row.session_epoch !== session.e) return null;
  return toUser(row);
});

export async function requireUser(): Promise<User> {
  const user = await currentUser();
  if (!user) redirect(userCount() === 0 ? "/setup" : "/login");
  return user;
}

export async function requireAdmin(): Promise<User> {
  const user = await requireUser();
  if (user.role !== "admin") throw new Error("This action needs an admin");
  return user;
}

async function setSessionCookie(row: UserRow) {
  const store = await cookies();
  store.set(SESSION_COOKIE, encodeSession(row), {
    httpOnly: true, sameSite: "lax", secure: config.secureCookies, path: "/", maxAge: SESSION_TTL_MS / 1000,
  });
}

// --- login rate limiting ----------------------------------------------------

const attempts = new Map<string, { count: number; until: number; windowStart: number }>();
const WINDOW_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 8;

async function clientKey(email: string) {
  const h = await headers();
  const ip = h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? h.get("x-real-ip") ?? "local";
  return sha256Hex(`${ip}|${email.toLowerCase()}`);
}

export type LoginResult = { ok: true } | { ok: false; error: string };

export async function login(email: string, password: string): Promise<LoginResult> {
  const key = await clientKey(email);
  const now = Date.now();
  if (attempts.size > 10_000) {
    for (const [k, v] of attempts) if (v.until < now && now - v.windowStart > WINDOW_MS) attempts.delete(k);
  }
  const entry = attempts.get(key);
  if (entry && entry.until > now) {
    return { ok: false, error: `Too many attempts. Try again in ${Math.ceil((entry.until - now) / 60000)} min.` };
  }
  const row = db().prepare("SELECT * FROM users WHERE email = ?").get(email.trim()) as UserRow | undefined;
  // Hash even for unknown emails so timing does not reveal which exist.
  const valid = row ? await verifyPassword(password, row.password_hash) : (await hashPassword(password), false);
  if (!row || !valid) {
    const fresh = !entry || now - entry.windowStart > WINDOW_MS;
    const next = fresh ? { count: 1, until: 0, windowStart: now } : { ...entry, count: entry.count + 1 };
    if (next.count >= MAX_ATTEMPTS) next.until = now + WINDOW_MS;
    attempts.set(key, next);
    return { ok: false, error: "Email or password is incorrect." };
  }
  attempts.delete(key);
  db().prepare("UPDATE users SET last_login_at = ? WHERE id = ?").run(now, row.id);
  await setSessionCookie(row);
  logConsoleAction(row.email, "session.login");
  return { ok: true };
}

export async function logout() {
  const store = await cookies();
  store.delete(SESSION_COOKIE);
}

/** Ends every session of a user (password change, removal, "sign out everywhere"). */
export function revokeSessions(userId: string) {
  db().prepare("UPDATE users SET session_epoch = session_epoch + 1 WHERE id = ?").run(userId);
}

export async function startSessionFor(userId: string) {
  const row = db().prepare("SELECT * FROM users WHERE id = ?").get(userId) as unknown as UserRow;
  await setSessionCookie(row);
}
