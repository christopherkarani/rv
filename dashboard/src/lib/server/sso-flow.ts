import "server-only";
import { open, seal } from "./secretbox";

/** What survives the round trip to the IdP: in an encrypted, 10-minute cookie. */
export interface SsoFlow {
  state: string;
  nonce: string;
  verifier: string;
  next: string;
  expires: number;
}

export const SSO_FLOW_COOKIE = "rvc_sso_flow";
export const SSO_FLOW_TTL_MS = 10 * 60 * 1000;

export const sealFlow = (flow: SsoFlow) => seal(JSON.stringify(flow), "sso-flow");

export function openFlow(value: string | undefined): SsoFlow | null {
  if (!value) return null;
  const text = open(value, "sso-flow");
  if (!text) return null;
  try {
    const flow = JSON.parse(text) as SsoFlow;
    return typeof flow.state === "string" && flow.expires > Date.now() ? flow : null;
  } catch {
    return null;
  }
}
