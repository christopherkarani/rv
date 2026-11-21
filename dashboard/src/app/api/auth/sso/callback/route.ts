import { NextResponse, type NextRequest } from "next/server";
import { ssoSignIn } from "@/lib/server/auth";
import { logConsoleAction } from "@/lib/server/db";
import { oidc, oidcConfiguration, publicOrigin, ssoSettings } from "@/lib/server/sso";
import { SSO_FLOW_COOKIE, openFlow } from "@/lib/server/sso-flow";
import { evaluateClaims } from "@/lib/sso-policy";

export const dynamic = "force-dynamic";

/** Finishes the OIDC flow: checks state, nonce and PKCE, then the console's own policy. */
export async function GET(request: NextRequest) {
  const settings = ssoSettings;
  let origin: string;
  try {
    origin = publicOrigin(request);
  } catch {
    return NextResponse.redirect(new URL("/login?error=sso-unavailable", request.url), 303);
  }
  const done = (path: string) => {
    const response = NextResponse.redirect(new URL(path, origin), 303);
    response.cookies.set(SSO_FLOW_COOKIE, "", { path: "/api/auth/sso", maxAge: 0 });
    return response;
  };
  if (!settings) return done("/login?error=sso-unavailable");
  const flow = openFlow(request.cookies.get(SSO_FLOW_COOKIE)?.value);
  if (!flow) return done("/login?error=sso-expired");
  if (request.nextUrl.searchParams.get("error")) {
    logConsoleAction(null, "sso.denied", `idp: ${request.nextUrl.searchParams.get("error")}`);
    return done("/login?error=sso-failed");
  }
  let claims: Record<string, unknown>;
  try {
    const configuration = await oidcConfiguration(settings);
    // The redirect URI the IdP saw, rebuilt from the public origin (not the proxy-facing request URL).
    const current = new URL(`${origin}/api/auth/sso/callback${request.nextUrl.search}`);
    const tokens = await oidc.authorizationCodeGrant(configuration, current, {
      pkceCodeVerifier: flow.verifier, expectedState: flow.state, expectedNonce: flow.nonce, idTokenExpected: true,
    });
    claims = { ...(tokens.claims() ?? {}) };
  } catch (error) {
    console.error("[rv-console] sso callback", error);
    logConsoleAction(null, "sso.denied", "token exchange or ID token validation failed");
    return done("/login?error=sso-failed");
  }
  const decision = evaluateClaims(claims, settings.policy);
  if (!decision.ok) {
    logConsoleAction(decision.email ?? null, "sso.denied", decision.reason);
    return done(`/login?error=${decision.reason}`);
  }
  const result = ssoSignIn(decision);
  if (!result.ok) {
    logConsoleAction(decision.email, "sso.denied", result.reason);
    return done(`/login?error=${result.reason}`);
  }
  const response = done(flow.next);
  response.cookies.set(result.session.name, result.session.value, result.session.options);
  return response;
}
