import { NextResponse, type NextRequest } from "next/server";
import { withBase } from "@/lib/base-path";
import { config } from "@/lib/server/config";
import { oidc, oidcConfiguration, publicOrigin, redirectUri, ssoSettings } from "@/lib/server/sso";
import { SSO_FLOW_COOKIE, SSO_FLOW_TTL_MS, sealFlow } from "@/lib/server/sso-flow";
import { safeNext } from "@/lib/safe-next";

export const dynamic = "force-dynamic";

/** Starts the OIDC authorization code flow (PKCE, state and nonce). */
export async function GET(request: NextRequest) {
  const settings = ssoSettings;
  const fail = (code: string) => NextResponse.redirect(new URL(withBase(`/login?error=${code}`), request.url), 303);
  if (!settings) return fail("sso-unavailable");
  try {
    const origin = publicOrigin(request);
    const configuration = await oidcConfiguration(settings);
    const verifier = oidc.randomPKCECodeVerifier();
    const state = oidc.randomState();
    const nonce = oidc.randomNonce();
    const url = oidc.buildAuthorizationUrl(configuration, {
      redirect_uri: redirectUri(origin),
      scope: settings.scopes,
      code_challenge: await oidc.calculatePKCECodeChallenge(verifier),
      code_challenge_method: "S256",
      state,
      nonce,
    });
    const response = NextResponse.redirect(url, 303);
    response.cookies.set(SSO_FLOW_COOKIE, sealFlow({
      state, nonce, verifier, next: safeNext(request.nextUrl.searchParams.get("next") ?? "/"), expires: Date.now() + SSO_FLOW_TTL_MS,
    }), {
      httpOnly: true, sameSite: "lax", secure: config.secureCookies, path: withBase("/api/auth/sso"), maxAge: SSO_FLOW_TTL_MS / 1000,
    });
    return response;
  } catch (error) {
    console.error("[rv-console] sso start", error);
    return fail("sso-unavailable");
  }
}
