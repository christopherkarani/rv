import { createHash, randomBytes } from "node:crypto";
import { createServer, type Server } from "node:http";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

/**
 * A minimal OpenID provider for tests: discovery, an authorize endpoint that
 * approves at once, a token endpoint that checks the client secret, the code,
 * the redirect URI and PKCE, and a JWKS. `nextClaims` sets who signs in next.
 */
export async function startMockIdp(opts: { clientId: string; clientSecret: string }) {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "RS256", use: "sig" };
  const codes = new Map<string, { nonce: string; challenge: string; redirectUri: string; claims: Record<string, unknown> }>();
  let nextClaims: Record<string, unknown> = {};
  let issuer = "";

  const server: Server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", issuer);
    const json = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (url.pathname === "/.well-known/openid-configuration") {
      return json(200, {
        issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/token`, jwks_uri: `${issuer}/jwks`,
        response_types_supported: ["code"], subject_types_supported: ["public"], id_token_signing_alg_values_supported: ["RS256"],
        code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["client_secret_post"],
      });
    }
    if (url.pathname === "/jwks") return json(200, { keys: [jwk] });
    if (url.pathname === "/authorize") {
      const p = url.searchParams;
      if (p.get("client_id") !== opts.clientId || p.get("code_challenge_method") !== "S256") return json(400, { error: "invalid_request" });
      const code = randomBytes(16).toString("hex");
      codes.set(code, { nonce: p.get("nonce") ?? "", challenge: p.get("code_challenge") ?? "", redirectUri: p.get("redirect_uri") ?? "", claims: nextClaims });
      const back = new URL(p.get("redirect_uri") ?? "");
      back.searchParams.set("code", code);
      back.searchParams.set("state", p.get("state") ?? "");
      res.writeHead(302, { location: back.toString() });
      return res.end();
    }
    if (url.pathname === "/token" && req.method === "POST") {
      let body = "";
      for await (const chunk of req) body += chunk;
      const form = new URLSearchParams(body);
      const entry = codes.get(form.get("code") ?? "");
      codes.delete(form.get("code") ?? "");
      const challenge = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
      if (!entry || form.get("client_secret") !== opts.clientSecret || form.get("redirect_uri") !== entry.redirectUri || challenge !== entry.challenge) {
        return json(400, { error: "invalid_grant" });
      }
      const idToken = await new SignJWT({ ...entry.claims, nonce: entry.nonce })
        .setProtectedHeader({ alg: "RS256", kid: "k1" })
        .setIssuer(issuer).setAudience(opts.clientId).setSubject(String(entry.claims.sub ?? "anon"))
        .setIssuedAt().setExpirationTime("5m").sign(privateKey);
      return json(200, { access_token: randomBytes(16).toString("hex"), token_type: "Bearer", expires_in: 300, id_token: idToken });
    }
    json(404, { error: "not_found" });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  issuer = `http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}`;
  return {
    issuer,
    setNextClaims(claims: Record<string, unknown>) { nextClaims = claims; },
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}
