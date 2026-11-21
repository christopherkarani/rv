import "server-only";
import { BASE_PATH } from "@/lib/base-path";
import * as oidc from "openid-client";
import { config } from "./config";
import type { SsoPolicy } from "../sso-policy";

const list = (v: string | undefined) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

/** OIDC settings from the environment; null when SSO is not configured. */
export const ssoSettings = (() => {
  const issuer = process.env.RV_CONSOLE_OIDC_ISSUER?.trim();
  const clientId = process.env.RV_CONSOLE_OIDC_CLIENT_ID?.trim();
  if (!issuer || !clientId) return null;
  const policy: SsoPolicy = {
    allowedDomains: list(process.env.RV_CONSOLE_OIDC_ALLOWED_DOMAINS).map((d) => d.toLowerCase().replace(/^@/, "")),
    groupsClaim: process.env.RV_CONSOLE_OIDC_GROUPS_CLAIM?.trim() || "groups",
    adminGroups: list(process.env.RV_CONSOLE_OIDC_ADMIN_GROUPS),
    viewerGroups: list(process.env.RV_CONSOLE_OIDC_VIEWER_GROUPS),
    autoProvision: process.env.RV_CONSOLE_OIDC_AUTO_PROVISION !== "0",
    defaultRole: process.env.RV_CONSOLE_OIDC_DEFAULT_ROLE === "admin" ? "admin" : "viewer",
  };
  return {
    issuer,
    clientId,
    clientSecret: process.env.RV_CONSOLE_OIDC_CLIENT_SECRET || undefined,
    name: process.env.RV_CONSOLE_OIDC_NAME?.trim() || "SSO",
    scopes: process.env.RV_CONSOLE_OIDC_SCOPES?.trim() || "openid email profile",
    /** Password sign-in is then limited to local admins (break-glass). */
    enforce: process.env.RV_CONSOLE_SSO_ENFORCE === "1",
    policy,
  };
})();

export type SsoSettings = NonNullable<typeof ssoSettings>;

/**
 * The console's public URL: origin plus any base path, no trailing slash.
 * The redirect URI is registered with the IdP, so production must name it
 * (RV_CONSOLE_PUBLIC_URL, including the base path) instead of trusting the
 * request's Host header.
 */
export function publicOrigin(request: Request): string {
  if (config.publicUrl) return config.publicUrl;
  if (config.production) throw new Error("RV_CONSOLE_PUBLIC_URL is required for single sign-on in production");
  return new URL(request.url).origin + BASE_PATH;
}

export const redirectUri = (origin: string) => `${origin}/api/auth/sso/callback`;

const isLoopback = (url: URL) => ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);

const globalSso = globalThis as unknown as { __rvOidc?: Promise<oidc.Configuration> };

/** Discovery runs once and is cached; a failure is retried on the next sign-in. */
export function oidcConfiguration(settings: SsoSettings): Promise<oidc.Configuration> {
  globalSso.__rvOidc ??= (async () => {
    const issuer = new URL(settings.issuer);
    if (issuer.protocol !== "https:" && !isLoopback(issuer)) throw new Error("RV_CONSOLE_OIDC_ISSUER must use https");
    return oidc.discovery(
      issuer,
      settings.clientId,
      settings.clientSecret,
      settings.clientSecret ? oidc.ClientSecretPost(settings.clientSecret) : oidc.None(),
      { execute: issuer.protocol === "http:" ? [oidc.allowInsecureRequests] : [], timeout: 10 },
    );
  })().catch((error) => {
    globalSso.__rvOidc = undefined;
    throw error;
  });
  return globalSso.__rvOidc;
}

export { oidc };
