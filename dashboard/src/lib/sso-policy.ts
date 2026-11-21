/**
 * Who may sign in through SSO, and as what. Pure, so it is unit-tested apart
 * from the OIDC exchange. Claims come from a verified ID token.
 */
export type Role = "admin" | "viewer";

export interface SsoPolicy {
  /** Lower-case email domains allowed to sign in; empty allows any. */
  allowedDomains: string[];
  /** ID token claim holding group names or ids (`groups` on Okta and Entra ID). */
  groupsClaim: string;
  adminGroups: string[];
  /** When set, members of none of `adminGroups` or `viewerGroups` are refused. */
  viewerGroups: string[];
  autoProvision: boolean;
  defaultRole: Role;
}

export type SsoRefusal =
  | "no-email"
  | "email-unverified"
  | "domain-not-allowed"
  | "not-in-group";

export type SsoDecision =
  | { ok: true; sub: string; email: string; name: string; groups: string[]; role: Role | null }
  | { ok: false; reason: SsoRefusal; email?: string };

function asStrings(value: unknown): string[] {
  if (Array.isArray(value)) return value.filter((v): v is string => typeof v === "string");
  if (typeof value === "string") return value.split(/[,\s]+/).filter(Boolean);
  return [];
}

export function evaluateClaims(claims: Record<string, unknown>, policy: SsoPolicy): SsoDecision {
  const sub = typeof claims.sub === "string" ? claims.sub : "";
  // Entra ID often omits `email`; its sign-in name is an address in preferred_username or upn.
  const candidates = [claims.email, claims.preferred_username, claims.upn];
  const email = (candidates.find((c): c is string => typeof c === "string" && /^[^@\s]+@[^@\s]+$/.test(c)) ?? "").toLowerCase();
  if (!sub || !email) return { ok: false, reason: "no-email" };
  if (claims.email_verified === false || claims.email_verified === "false") return { ok: false, reason: "email-unverified", email };
  const domain = email.slice(email.lastIndexOf("@") + 1);
  if (policy.allowedDomains.length && !policy.allowedDomains.includes(domain)) return { ok: false, reason: "domain-not-allowed", email };

  const groups = asStrings(claims[policy.groupsClaim]);
  const lower = new Set(groups.map((g) => g.toLowerCase()));
  const inAny = (list: string[]) => list.some((g) => lower.has(g.toLowerCase()));
  const mapping = policy.adminGroups.length > 0 || policy.viewerGroups.length > 0;
  let role: Role | null = null;
  if (mapping) {
    if (inAny(policy.adminGroups)) role = "admin";
    else if (policy.viewerGroups.length === 0 || inAny(policy.viewerGroups)) role = "viewer";
    else return { ok: false, reason: "not-in-group", email };
  }
  const given = typeof claims.given_name === "string" ? claims.given_name : "";
  const family = typeof claims.family_name === "string" ? claims.family_name : "";
  const name = (typeof claims.name === "string" && claims.name.trim()) || `${given} ${family}`.trim() || email;
  return { ok: true, sub, email, name: name.slice(0, 80), groups, role };
}

export const SSO_ERRORS: Record<string, string> = {
  "no-email": "Your identity provider did not send an email address for your account.",
  "email-unverified": "Your email address is not verified with your identity provider.",
  "domain-not-allowed": "Your email domain is not allowed to sign in to this console.",
  "not-in-group": "Your account is not in a group allowed to use this console. Ask an admin to add you.",
  "not-provisioned": "Your account has not been added to this console. Ask an admin to add you.",
  "sso-required": "This console requires single sign-on.",
  "sso-failed": "Single sign-on did not complete. Try again.",
  "sso-expired": "The sign-in attempt expired. Try again.",
  "sso-unavailable": "Single sign-on is not configured correctly. Check the console's OIDC settings.",
};
