import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NextRequest } from "next/server";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startMockIdp } from "./support/mock-idp";
import { evaluateClaims, type SsoPolicy } from "@/lib/sso-policy";

const dir = mkdtempSync(join(tmpdir(), "rv-console-sso-"));
let idp: Awaited<ReturnType<typeof startMockIdp>>;
let start: typeof import("@/app/api/auth/sso/start/route");
let callback: typeof import("@/app/api/auth/sso/callback/route");
let auth: typeof import("@/lib/server/auth");
let db: typeof import("@/lib/server/db");

beforeAll(async () => {
  idp = await startMockIdp({ clientId: "rv-console", clientSecret: "s3cret" });
  Object.assign(process.env, {
    RV_CONSOLE_DATA_DIR: dir,
    RV_CONSOLE_PUBLIC_URL: "http://console.test",
    RV_CONSOLE_OIDC_ISSUER: idp.issuer,
    RV_CONSOLE_OIDC_CLIENT_ID: "rv-console",
    RV_CONSOLE_OIDC_CLIENT_SECRET: "s3cret",
    RV_CONSOLE_OIDC_NAME: "Okta",
    RV_CONSOLE_OIDC_ALLOWED_DOMAINS: "northwind.example",
    RV_CONSOLE_OIDC_ADMIN_GROUPS: "rv-admins",
    RV_CONSOLE_OIDC_VIEWER_GROUPS: "engineering,security",
  });
  start = await import("@/app/api/auth/sso/start/route");
  callback = await import("@/app/api/auth/sso/callback/route");
  auth = await import("@/lib/server/auth");
  db = await import("@/lib/server/db");
});

afterAll(async () => {
  await idp?.close();
  rmSync(dir, { recursive: true, force: true });
});

/** Runs the browser's part of the flow: start, IdP redirect, callback. */
async function signIn(claims: Record<string, unknown>, next = "/fleet", tamper?: (url: URL) => void) {
  idp.setNextClaims(claims);
  const begun = await start.GET(new NextRequest(`http://console.test/api/auth/sso/start?next=${encodeURIComponent(next)}`));
  expect(begun.status).toBe(303);
  const flowCookie = begun.cookies.get("rvc_sso_flow")?.value;
  expect(flowCookie).toBeTruthy();
  const authorize = new URL(begun.headers.get("location")!);
  expect(authorize.origin).toBe(idp.issuer);
  expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
  expect(authorize.searchParams.get("redirect_uri")).toBe("http://console.test/api/auth/sso/callback");
  const idpAnswer = await fetch(authorize, { redirect: "manual" });
  const back = new URL(idpAnswer.headers.get("location")!);
  tamper?.(back);
  const done = await callback.GET(new NextRequest(back, { headers: { cookie: `rvc_sso_flow=${flowCookie}` } }));
  return { status: done.status, location: done.headers.get("location") ?? "", session: done.cookies.get("rvc_session")?.value };
}

const user = (email: string) => db.db().prepare("SELECT role, auth_provider, oidc_sub FROM users WHERE email = ?").get(email) as
  { role: string; auth_provider: string; oidc_sub: string } | undefined;

describe("OIDC sign-in", () => {
  it("signs in a mapped admin, creates the account, and returns to `next`", async () => {
    const r = await signIn({ sub: "okta|1", email: "ada@northwind.example", email_verified: true, name: "Ada Lovelace", groups: ["rv-admins"] });
    expect(r.status).toBe(303);
    expect(r.location).toBe("http://console.test/fleet");
    expect(r.session).toBeTruthy();
    expect(user("ada@northwind.example")).toMatchObject({ role: "admin", auth_provider: "oidc", oidc_sub: "okta|1" });
  });

  it("maps viewers and syncs a role change on the next sign-in", async () => {
    await signIn({ sub: "okta|2", email: "grace@northwind.example", groups: ["engineering"] });
    expect(user("grace@northwind.example")?.role).toBe("viewer");
    await signIn({ sub: "okta|2", email: "grace@northwind.example", groups: ["engineering", "rv-admins"] });
    expect(user("grace@northwind.example")?.role).toBe("admin");
  });

  it("refuses other domains and users outside the allowed groups", async () => {
    const domain = await signIn({ sub: "x|1", email: "mallory@evil.example", groups: ["rv-admins"] });
    expect(domain.location).toBe("http://console.test/login?error=domain-not-allowed");
    expect(domain.session).toBeUndefined();
    const group = await signIn({ sub: "okta|3", email: "sam@northwind.example", groups: ["sales"] });
    expect(group.location).toContain("error=not-in-group");
    expect(user("sam@northwind.example")).toBeUndefined();
  });

  it("rejects a callback whose state was swapped", async () => {
    const r = await signIn({ sub: "okta|4", email: "lin@northwind.example", groups: ["engineering"] }, "/", (url) => url.searchParams.set("state", "forged"));
    expect(r.location).toContain("error=sso-failed");
    expect(r.session).toBeUndefined();
  });

  it("rejects a callback without the flow cookie", async () => {
    idp.setNextClaims({ sub: "okta|5", email: "kim@northwind.example", groups: ["engineering"] });
    const begun = await start.GET(new NextRequest("http://console.test/api/auth/sso/start"));
    const back = new URL((await fetch(new URL(begun.headers.get("location")!), { redirect: "manual" })).headers.get("location")!);
    const done = await callback.GET(new NextRequest(back));
    expect(done.headers.get("location")).toContain("error=sso-expired");
  });

  it("never lets an SSO-only account sign in with a password", async () => {
    const row = db.db().prepare("SELECT password_hash FROM users WHERE email = ?").get("ada@northwind.example") as { password_hash: string };
    expect(row.password_hash).toBe("!sso");
    expect(auth.userCount()).toBe(2);
  });
});

describe("evaluateClaims", () => {
  const policy: SsoPolicy = { allowedDomains: [], groupsClaim: "groups", adminGroups: [], viewerGroups: [], autoProvision: true, defaultRole: "viewer" };
  it("falls back to preferred_username for Entra ID and keeps roles when no mapping is set", () => {
    const d = evaluateClaims({ sub: "e1", preferred_username: "Ada@Contoso.com", name: "Ada" }, policy);
    expect(d).toMatchObject({ ok: true, email: "ada@contoso.com", role: null });
  });
  it("refuses an explicitly unverified email and a missing one", () => {
    expect(evaluateClaims({ sub: "e2", email: "a@b.co", email_verified: false }, policy)).toMatchObject({ ok: false, reason: "email-unverified" });
    expect(evaluateClaims({ sub: "e3" }, policy)).toMatchObject({ ok: false, reason: "no-email" });
  });
  it("matches groups case-insensitively and accepts a space-separated string claim", () => {
    const mapped = { ...policy, adminGroups: ["RV-Admins"], viewerGroups: ["eng"] };
    expect(evaluateClaims({ sub: "e4", email: "a@b.co", groups: "eng rv-admins" }, mapped)).toMatchObject({ ok: true, role: "admin" });
  });
});
