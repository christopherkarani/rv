# rv control plane: spec (not built)

Status: design only (Phase 4.4). Owner decision needed before any server work.

## What the client already does (Phases 2-4)

| Need | Client piece | Contract |
|---|---|---|
| Org rules on every Mac | Managed policy in `/Library/Application Support/RV/managed/` (root-owned), optional Ed25519 signature | `policy.json` v1, `policy.json.sig`, `org-key.pub` |
| Fleet posture | `rv report --json` | `rv.report.v1` |
| Evidence in the SIEM | `rv audit forward` / `rv audit export --format ocsf` | OCSF 1.3.0 JSON arrays, `metadata.uid` for dedupe |
| Tool governance | `rv mcp serve` gateway, deny/ask/allow, local approvals | `mcp.json` v1, `mcp-approvals.json` |
| Secret custody | `rv secrets` + placeholder gateway, Keychain/Vault/1Password/AWS sources | `secrets.json` v1 |

**CP0, available today with no rv server:** MDM (Jamf, Kandji, Intune) installs
the signed bundle and runs `rv report --json` as an extension attribute;
launchd runs `rv audit forward` every few minutes to the customer's SIEM
(Splunk HEC, Datadog, Sentinel, or any HTTPS collector). This is the
enterprise pilot story until the control plane exists.

## Goals

1. Author, sign, and distribute policy per group without hand-editing JSON.
2. See the fleet: which machines are compliant, ungoverned MCP servers,
   plaintext credentials, invalid policy, rv versions.
3. Route `ask` decisions (MCP tool calls, later secret use) to a human approver
   other than the agent's user, with an auditable decision.
4. Admin console behind the customer's IdP; group membership from SCIM.

Non-goals: hosting customer secrets (they stay in Keychain/Vault/1Password/AWS),
proxying model traffic, replacing the SIEM.

## Components

```
 IdP (OIDC/SAML, SCIM) ──► Console + API ──► Signer (KMS/HSM key)
                              │    ▲               │ signed bundles
           reports, approvals │    │ decisions     ▼
 Mac: rvd / rv ◄──────────────┘    └──── Policy distribution (MDM or pull)
        │ OCSF
        ▼
      customer SIEM (unchanged)
```

### Policy authoring and signing
- Policies are the existing `policy.json` v1 schema, edited as structured
  forms plus a JSON view; every save is a new `serial`.
- Signing happens only in the signer service with a non-exportable KMS/HSM
  Ed25519 key. The console never sees the private key. `rv managed sign`
  remains for customers who sign offline.
- Key rotation (client change needed): allow `org-key.pub` to hold several
  keys, one per line; a bundle verifies if any key verifies. Remove the old
  key after the fleet reports the new serial.

### Distribution
- Recommended: MDM installs the bundle (root-owned, nothing new on the client).
- Optional pull (client change needed): `rvd` (root LaunchDaemon) fetches
  `https://<cp>/v1/policy/<device-group>` with an ETag, verifies the signature
  with the pinned key, refuses a `serial` lower than the last installed one
  (anti-rollback, last serial stored root-owned), and writes the bundle into
  the managed directory. The user-level `rv` never writes there.

### Fleet inventory
- `POST /v1/reports` with `rv.report.v1`, authenticated by a per-device token
  enrolled through MDM (client change: `rv report --post` reading the token
  from the managed directory).
- Console views: compliance by group, MCP servers seen across the fleet
  (name + command, never env values), plaintext-credential findings, invalid
  bundles, version skew.

### Approval routing
Today an `ask` call creates a local pending request that the same user
approves with `rv mcp approve`. For enterprise:

- Policy gains `"approvals": {"route": "https://<cp>/v1/approvals", "localApproval": false}`.
- `rv mcp serve` posts `{id, device, user, server, tool, argumentKeys,
  argumentsHash, requestedAt}` (never argument values) and tells the agent the
  call is waiting, as today.
- Approvers (SCIM group per policy) decide in the console or in Slack/Teams.
  The decision is signed by the control plane:
  `{id, argumentsHash, decision, approver, expiresAt}`.
- The gateway polls (or holds a long-poll) for the decision, verifies the
  signature with a pinned approvals key, checks `id`, `argumentsHash` and
  expiry, and consumes it once, exactly like a local grant. With
  `localApproval: false`, `rv mcp approve` refuses.
- Every decision is an OCSF API Activity event on both sides.

### Identity
- Console: OIDC or SAML SSO; roles admin, policy-editor, approver, auditor.
- SCIM 2.0 provisions users and groups; groups bind to policies and approver
  sets.
- Devices: MDM enrollment provides device id → assigned user; reports carry
  the local account name and uid for correlation.

## Data handling
- Never collected: secret values, MCP tool arguments, env values, prompt text.
- Collected: names, hashes, statuses, decisions, timestamps, device/user ids.
- Region-pinned storage; reports and approval records kept 13 months by default.

## Build order
1. CP1: report ingestion + fleet dashboard (read-only, low risk, sells pilots).
2. CP2: approval routing (needs the client change plus the signed decision format).
3. CP3: policy authoring + KMS signing + pull distribution with anti-rollback.

## Open questions for the owner
- Hosted SaaS, customer-hosted, or both for the first customers?
- One org key for bundles and approvals, or separate keys (recommended: separate)?
- Should `ask` time out to deny, and after how long (suggest 10 minutes)?
- Slack/Teams approvals in CP2, or the console only?
