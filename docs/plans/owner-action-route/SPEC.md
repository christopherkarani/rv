# Authenticated owner action route + Linux allow-once

Status: shipped in a narrower form. rvd confirms owner presence (`confirmOwnerAction`, `Sources/RVService/OwnerPresence.swift`) and audits it; the CLI then applies the change itself, rather than rvd applying it. macOS proof is rvd's own LocalAuthentication prompt showing rvd's sanitized copy of the summary (section 5.5, `daemonLocalAuthentication`), for every authenticated caller, so one-click installs without a manifest work; `cliAttestation` was not kept for owner actions. Linux proof is the login password checked by `unix_chkpwd`. Allow-once on Linux carries the same proof in `attestTTYRedemption`. Moving the writes themselves into rvd remains open. Owner decisions are in section 14.
Scope: one rvd-side IPC route that applies owner mutations, the presence proofs it accepts on macOS and Linux, and allow-once redemption on Linux.
Line numbers are against commit `bc52f30`.

## 1. What exists today

Every command that loosens policy calls `LocalControlBoundary.requireOwnerAuthorization()` (`Sources/RVCLI/LocalControlBoundary.swift:7-9`). It always throws. The bodies behind it still run in the CLI process and write `~/.config/rv` directly.

| Command | Gate | Body today |
| --- | --- | --- |
| `rv packs enable/disable` | `Sources/RVCLI/Commands/PacksCommand.swift:212` | `applyPackMutation` writes config in the CLI (`:218`) |
| `rv safety set` | `Sources/RVCLI/Commands/SafetyCommand.swift:12` | `SafetyStore.saveMachine` in the CLI |
| `rv allowlist add / add-command / remove` | `Sources/RVCLI/AllowlistCommand.swift:80, :127, :172` | `AllowlistCLI.store(...).add/remove` in the CLI |
| `rv policy export --output` | `Sources/RVCLI/Commands/PolicyCommand.swift:198` | writes an arbitrary path |
| `rv policy apply --save` | `Sources/RVCLI/Commands/PolicyCommand.swift:266` | `session.mergeIncoming(..., save: true)` |
| `rv policy draft --save` | `Sources/RVCLI/Commands/PolicyDraftCommand.swift:80` | saves the compiled draft |
| `rv egress approve / deny` | `Sources/RVCLI/Commands/EgressCommand.swift:531, :597` | `EgressReviewRun.approve` already has an LA ceremony (`:312-330`), never reached |
| `rv workspace abandon` | `Sources/RVCLI/Commands/WorkspaceCommand.swift:450` | `abandonBlockedWorkspace` (`:460`) |
| identity launches | `Sources/RVCLI/Commands/WorkspaceCommand.swift:597-603` | refused before any host contact: "requires a scoped operator permit" |

On the daemon side, the three generic owner methods (`pendingResolve`, `ruleSave`, `setPackEnabled`) map to `.ownerMutation` (`Sources/RVService/AuthenticatedRequestContext.swift:87-88`), which is never permitted (`:119-122`). The same-UID socket session also excludes it (`Sources/RVService/ServiceRuntime.swift:398-410`). rvd already has the apply code for packs: `LiveCompileSet.setPackEnabled` (`Sources/RVService/LiveCompileSet.swift:152`), reached from `ServiceRuntime.setPackEnabled` (`ServiceRuntime.swift:677`).

One generic-IPC path plants authority: `attestTTYRedemption` (`.ttyAttestation`, `AuthenticatedRequestContext.swift:66-74, :132-147`). The trust anchor is the pinned CLI code identity (`.cli` role from the admin-installed `peer-trust.json`, `Sources/RVIsolation/WorkspacePeerAuthenticator.swift:117`) plus the CLI's own LocalAuthentication run (`Sources/RVCLI/CLIOwnerAuth.swift:32-42`, `Sources/RVCLI/AllowOnceCommand.swift:147-165`). rvd re-checks shape and plants one memory grant (`ServiceRuntime.swift:454-497`).

This path does not work in two cases:

- **Linux.** Socket peers get `PlatformPeerEvidence.socketPeer` with `componentRole: nil` (`WorkspacePeerAuthenticator.swift:72-82`, `Sources/RVService/UnixFrameTransport.swift:205-217`), so they never get `.cli`. `CLIOwnerAuth.liveOutcome` returns `.unavailable` off macOS (`CLIOwnerAuth.swift:79-83`). `UserPresence.finishPrintedCode` refuses a typed code when no device-owner prompt exists (`Sources/RVCLI/Commands/UserPresence.swift:120-131`). So `rv allow-once` cannot be redeemed on Linux.
- **macOS one-click installs.** No manifest means no `.cli` role, so attestation is refused and the CLI points the user at RVOperatorUI (`AllowOnceCommand.swift:15-16`).

Pieces we can reuse already exist but are not wired. `ControlAuthorizationBroker` (`Sources/RVService/ControlAuthorization.swift:44-142`) runs LocalAuthentication inside rvd with a prompt built from the stored row, binds a receipt to row, connection and deadlines, and consumes it once. `LocalOwnerAuthenticator` (`Sources/RVService/OwnerAuthenticator.swift:11`) is its LA backend. `docs/security/phase-2-owner-authentication-status.md:11` records that a per-user GUI LaunchAgent could raise an LA prompt (second attempt succeeded).

## 2. Goals and non-goals

Goals:

1. One rvd route that applies every owner mutation in section 8. The CLI proposes; rvd builds, displays, proves and applies.
2. No mutation without fresh proof that a human was present for this exact operation. Single-use, operation-bound, expiring.
3. A Linux proof that a non-interactive same-user process cannot complete alone.
4. Allow-once redemption on Linux through the same route.
5. A slot for signed remote approvals (phone or chat relay) that changes only the proof, not the route.

Non-goals:

- Stopping a same-user process from editing `~/.config/rv` directly or killing rvd. rv already documents this limit ("A process running as you can still edit or delete ~/.config/rv; rv flags it", `Sources/RVCLI/Help/HelpCatalog.swift:640`). Contained runtimes cannot reach those files. This spec does not change that.
- Replacing the RVOperatorUI ceremonies (`Sources/RVService/HookReviewCeremony.swift`, the Step 6 action ceremony). They keep working. Section 13 says when they can share the authorizer.
- `rv uninstall` and `rv mcp approve/trust`. They keep their CLI-side presence checks for now (`Sources/RVCLI/Commands/UninstallCommand.swift:28`, `MCPCommand.swift:463`).

## 3. Threat model

The adversary is a coding agent running as the owner's uid. It may be:

- inside the hook-guarded shell, where `SelfProtectionGuard` floors `rv packs disable`, `rv allow-once` and similar at indeterminate (`Sources/RVEngine/SelfProtectionGuard.swift:3-13`);
- running a script it wrote (Python, Node) that opens the rvd socket directly, which the hook never sees;
- running a detached process (`setsid`, `nohup`, `systemd-run --user`) outside its own process tree.

It can: run the genuine `rv` binary; allocate a pseudo-terminal and read and write it (`UserPresence.swift:24-28`); open and write the owner's other `/dev/pts/N` devices (same uid, mode 0620); read every file rvd reads; read hook output, including allow-once codes; watch the session D-Bus (same-uid monitors are allowed); log keystrokes of other X11 clients on an X11 session; ptrace other same-uid processes when `kernel.yama.ptrace_scope` is 0.

We assume it cannot: touch hardware; know the login password; answer a system-drawn authentication dialog (the macOS LA sheet, a polkit agent dialog on Wayland); sign with a private key it never held; write root-owned paths.

The test for any proof is: **can a non-interactive same-user process complete it alone?** If yes, it is not presence.

What the route guarantees: rv's own surfaces (CLI, IPC, hooks) never turn agent bytes into owner authority. What it cannot guarantee on same-user Linux: that the owner's config files stay untouched, and that an install in user-writable paths is not replaced. Install integrity is assumed.

## 4. The pattern we generalize

The workspace launch ceremony already has the shape we want:

- **Prepare.** The host mints an unguessable `PreparedLaunchID`, never derived from the digest, and retains the exact intent (`Sources/RVIsolation/PreparedWorkspaceLaunch.swift:6-24`). The CLI's proposal is untrusted input (`AuthenticatedRequestContext.swift:62-65`).
- **Permit.** `WorkspaceOperatorAuthorizer` holds every record in memory under a fresh epoch per process lifetime. Transitions run without suspension, so racing consumers get one winner. Monotonic time is the only expiry authority (`Sources/RVService/WorkspaceOperatorAuthorizer.swift:5-18`).
- **Redeem.** rvd consumes the server-held permit, then sends one commit to the live host. No retry. A transport failure after consume is recorded as unknown, because at-most-once beats recovery (`Sources/RVService/WorkspaceOperatorCeremony.swift:336-352`). The host re-verifies every binding against its own retained state (`Sources/RVIPC/WorkspaceOperatorRedeemWire.swift:24-29`).

`ControlAuthorizationBroker` adds the parts the launch ceremony lacks: the prompt text comes only from service state (`ControlAuthorization.swift:90-92`), the row is re-read after the prompt and again at consume, and disconnect kills outstanding receipts (`:70-73`).

The owner action route is those two combined, with the mutation applied by rvd instead of a workspace host.

## 5. Design

### 5.1 Flow

```text
rv packs disable cloud.aws
  │ 1 ownerActionPropose{kind: packs.disable, ids}            (untrusted)
  ▼
rvd: validate shape → read live state → build OwnerOperation
     precondition = digest(current packs config)
     digest = sha256(canonical(op, precondition, operationID, epoch))
     tag = 6 chars from digest; display lines from op
  │ 2 reply {operationID, tag, display, proofMethods, expiresIn}
  ▼
CLI prints display + tag, then sends
  │ 3 ownerActionConfirm{operationID, digest, method[, evidence]}
  ▼
rvd: same connection? digest equal? live? → run proof
     (macOS: LA prompt raised by rvd, text = display + tag)
     (Linux: polkit check raised by rvd, details = display + tag)
     (remote: verify signed approval)
     → re-read state, compare precondition → apply under lock
     → mark consumed → audit
  │ 4 reply {status: applied | changed | refused | expired | failed}
```

### 5.2 Operation model

`OwnerOperation` is a closed Swift enum in RVService, built by rvd from the proposal plus rvd's own reads. It is never decoded from client bytes, matching `ApprovalOperation` (`ControlAuthorization.swift:11`).

- **Canonical encoding.** Sorted-key JSON with a version field, the kind, typed parameters, the precondition digest, `operationID` and the rvd epoch. The digest is SHA-256 of these bytes. Including the ID and epoch makes every digest unique, so a proof can never match two operations.
- **Precondition.** A digest of the state the operation changes (the `[packs]` section, the safety level, `allowlist.toml`, the pending row, the policy document). rvd recomputes it right before apply. If it differs, the result is `changed` and nothing is written. This is the same re-read rule as `ControlAuthorizationBroker.authenticate` (`:96`) and the allow-once TOCTOU check (`AllowOnceCommand.swift:74-78`).
- **Classification.** Each kind is `loosening` or `tightening`. Loosening needs proof. Tightening (safety set strict, allowlist remove, egress deny) still goes through rvd for audit and a single writer, but needs only an authenticated peer. Section 14 asks whether to keep that exemption.
- **Display.** rvd renders display lines with the existing escaping (`DisplayedText.field`) and redaction. A secret-bearing command is shown masked. The digest binds the unmasked payload digest, as `AttestTTYRedemptionParams.payloadDigest` does today (`Sources/RVIPC/IPCTTYAttest.swift:27-33`).

### 5.3 State machine

A new actor, `OwnerActionAuthorizer` (`Sources/RVService/OwnerActionAuthorizer.swift`), follows `WorkspaceOperatorAuthorizer`:

```text
proposed ──confirm──▶ awaitingProof ──proof ok──▶ applying ──▶ applied
   │                       │                          │
   ├─ttl/cancel/disconnect─┴─▶ cancelled | expired    ├─▶ changed  (precondition)
   └─────────────────────────────────────────────────  └─▶ failed   (write error, no retry)
```

Rules:

- Memory only. A fresh epoch per rvd lifetime. A restart forgets everything, and old operation IDs fail as `unknown`.
- **One operation awaits proof at a time, machine-wide.** A second proposal while one is in `awaitingProof` is refused with `busy` and shown the first one's display and tag. This stops a human's touch or password from being spent on an operation the agent slipped in at the same moment. `rv owner cancel` clears the slot without proof, since cancelling grants nothing.
- Proposal lifetime: 120 s. Proof window: 60 s from confirm. Both use monotonic time.
- Confirm must come on the proposing connection (`connectionID` from `AuthenticatedRequestContext`, `:12`). Disconnect cancels.
- The `awaitingProof → applying` transition runs without suspension, so two racing confirms produce one winner. Proof evidence is consumed when this transition happens.
- Apply runs once. A write failure after consume becomes `failed` and the human must propose again. The route never retries.
- Per-peer rate limit: at most 5 proposals per minute per peer pid. Refusals are audited.

### 5.4 Apply

rvd performs every write, so the CLI bodies listed in section 1 move into RVService. The pack path already lives there (`LiveCompileSet.setPackEnabled`). Writes take the store's existing lock (for example `AllowlistStoreError.lockFailed`, `AllowlistCommand.swift:98`). Every stage emits an audit event to the hash-chained `audit.jsonl`: proposed, proof method and result, applied, changed, failed. Each event carries the operation digest, never secret text.

### 5.5 Proof providers

`OwnerProofMethod` is a closed enum. rvd advertises the methods available on this machine in the propose reply.

| Method | Platform | Who runs it | Evidence on the wire |
| --- | --- | --- | --- |
| `daemonLocalAuthentication` | macOS | rvd, via `LocalOwnerAuthenticator` | none |
| `cliAttestation` | macOS with `.cli` role | pinned CLI runs LA, then attests | none (the role is the anchor) |
| `polkit` | Linux desktop | rvd, via `pkcheck` | none |
| `securityKey` | Linux, optional (section 14) | rvd verifies; CLI talks to the key | assertion bytes |
| `signedApproval` | any | rvd verifies | signed approval bytes (section 10) |

**macOS primary: `daemonLocalAuthentication`.** rvd raises the LA prompt itself. Its text is the display and tag from rvd's retained operation. This removes the dependence on the admin-only manifest. It also means the text the human approves comes from rvd, not the client. It is `ControlAuthorizationBroker` with `OwnerOperation` in place of `ApprovalOperation`. LA unavailable (SSH session, no GUI login, no passcode) gives `unavailable`. The CLI then names the other methods.

**macOS compatibility: `cliAttestation`.** Kept so older CLIs and manifest installs keep working. It also becomes the path for `rv allow-once` when rvd's own LA prompt cannot show.

## 6. Linux presence: options evaluated

| Option | Can a non-interactive same-user process complete it alone? | Display trusted? | Dependencies | Verdict |
| --- | --- | --- | --- | --- |
| Code printed to the CLI's `/dev/tty`, typed back | Yes. It allocates a pty, reads the code, types it. | No | none | Reject. `UserPresence.swift:24-28` already says so. |
| Code printed to rvd's controlling TTY | rvd is a systemd user unit with no TTY (`Sources/RVCLI/Setup/SystemdUserTemplate.swift`). A VT or console write needs root. | n/a | root helper | Reject. |
| Check the CLI's controlling terminal via `/proc/<pid>/stat` (`tty_nr`, session leader exe) | Yes. Every pts is same-uid and allocatable. The agent can also open a real terminal window (`gnome-terminal -- rv ...`) and, on X11, read it. | No | none | Reject as authority. Fine as an audit hint. |
| Code sent by desktop notification or session D-Bus | Yes. Same-uid processes can monitor the session bus. | No | D-Bus | Reject. |
| `sudo` or a root helper that asks for the password | Mostly no, but the password is typed into a terminal the agent may control, and sudo's cached timestamp can be reused. | No | sudoers | Reject. |
| polkit `auth_self` (no `_keep`), checked by rvd with `pkcheck --allow-user-interaction` | No. polkitd (root) verifies the password through PAM. | Yes, on Wayland with the desktop's graphical agent | polkit, a root-installed action file | **Recommend for desktop Linux.** |
| FIDO2 security key, user presence (touch) | No. It needs a physical touch. | No. The display is the CLI's terminal. | libfido2, a key, a protected key pin | Optional, see section 14. |
| Signed approval from a paired phone | No. It needs the phone's private key. | Yes, on the phone | relay, pairing, a protected key pin | **Recommend for headless and SSH.** |

Notes on polkit, stated plainly:

- rvd calls `pkcheck --action-id dev.rv.owner-action --process <cli pid>,<start time>,<uid> --allow-user-interaction --detail op <tag> --detail summary <first display line>`. It never runs the textual agent itself.
- The action file `/usr/share/polkit-1/actions/dev.rv.owner-action.policy` sets `allow_active=auth_self`, `allow_inactive=no`, `allow_any=no`. Installing it needs root once, from `rv setup` with sudo or from a distro package. Without it, the method is not advertised.
- rvd requires the CLI's logind session to be local, active and graphical (`loginctl show-session`: `Remote=no`, `Active=yes`, `Type=wayland` or `x11`). On SSH or a TTY-only session, a textual agent would read the password from a terminal the agent might control, so rvd refuses `polkit` there.
- On X11, any same-session client can log keystrokes, including the password typed into the polkit dialog. rvd marks proofs from an X11 session as `polkit-x11` in the audit, and `rv doctor` warns. Section 14 asks whether to refuse X11 outright.
- The authority is the system's PAM. Unlike key pins, there is nothing in `~/.config/rv` the agent can replace to forge a proof. That is the main reason polkit comes before FIDO2 or a phone on Linux.

The weakness shared by FIDO2 and phone approvals: rvd must store a public key, and a same-user agent can overwrite `~/.config/rv` with its own key, then forge proofs. A pin is only trustworthy if it lives somewhere the agent cannot write: the root-owned managed directory (`/etc/rv/managed` on Linux, `Sources/RVPolicy/ManagedPolicy.swift:382-384`), the macOS Keychain with an ACL, or a key whose vendor attestation rvd checks against roots built into the binary on every load.

## 7. Wire changes (Sources/RVIPC)

Add `Sources/RVIPC/IPCOwnerAction.swift` and four methods to `IPCMethod` / `IPCResult` (`Sources/RVIPC/IPCMethods.swift:4-51`), with matching keys in the hand-written Codable (`:54-149`):

```swift
case ownerActionPropose(OwnerActionProposeParams)   // → .ownerActionProposed
case ownerActionConfirm(OwnerActionConfirmParams)   // → .ownerActionResult
case ownerActionStatus(OwnerActionRefParams)        // → .ownerActionResult
case ownerActionCancel(OwnerActionRefParams)        // → .ownerActionResult

public struct OwnerActionProposeParams: Codable { var request: OwnerActionRequest; var clientSemver: String }
public enum OwnerActionRequest: Codable {           // closed; unknown "kind" fails decode
    case packs(enable: Bool, ids: [PackID])
    case safety(SafetyLevel)
    case allowlistAddRule(RuleID, reason: String)
    case allowlistAddCommand(command: String, reason: String)
    case allowlistRemove(target: String)
    case policyApply(document: String, layer: PolicyDocumentLayer)   // ≤ 256 KiB
    case policyDraftSave(document: String)
    case egressDecide(ApprovalID, approve: Bool, reason: String?)
    case workspaceAbandon(project: String)
    case allowOnceRedeem(codeHash: CodeHash)
    case allowOnceMint(command: String, cwd: WorkingDirectory)
}
public struct OwnerActionProposedReply: Codable {
    var operationID: UUID; var tag: String; var display: [String]
    var digestHex: String; var loosening: Bool
    var proofMethods: [OwnerProofMethod]; var expiresInSeconds: Int
}
public struct OwnerActionConfirmParams: Codable {
    var operationID: UUID; var digestHex: String
    var method: OwnerProofMethod; var evidence: Data?        // ≤ 8 KiB
}
public struct OwnerActionResultReply: Codable {
    var status: OwnerActionStatus; var applied: Bool; var summary: [String]
}
public enum OwnerActionStatus: String, Codable {
    case proposed, awaitingProof, applied, changed, refused, busy,
         expired, cancelled, failed, unavailable, unknown
}
```

Authorization (`AuthenticatedRequestContext.swift`):

- New requirement `.ownerAction` for all four methods: `context.peer != nil`, any role or none. Proposing grants nothing. Authority comes only from the proof and the actor's checks.
- `ServiceRuntime.sameUIDSocketSession` (`ServiceRuntime.swift:398-410`) admits `.ownerAction`, so Linux socket peers can reach it.
- `.ownerMutation` stays `false`. `pendingResolve`, `ruleSave` and `setPackEnabled` stay denied and are removed at the next major protocol bump.
- `ProtocolVersion.serviceSemver` goes from `1.0.0` to `1.1.0` (`Sources/RVIPC/ProtocolVersion.swift:4`). The change is additive. A CLI talking to an old rvd gets `unknownMethod` and prints today's `LocalControlBoundary.reason`.
- `IPCError` gains `.ownerActionFailed(String)` with a closed reason vocabulary.

The XPC transport needs no new keys. These ride the existing `rv.ipc` envelope. The C front door (`Sources/rv-c`) does not change, because it only handles hooks.

## 8. Command migration

`LocalControlBoundary` becomes a client helper, `OwnerActionClient.run(_ request:)`: propose, print display and tag, confirm, wait, print the result. The `requireOwnerAuthorization()` lines are replaced call by call.

| Command | Request kind | Class | Notes |
| --- | --- | --- | --- |
| `rv packs enable` | `packs(enable: true)` | loosening by default | A pack's safe patterns can short-circuit, so enabling is not provably tightening. See section 14. |
| `rv packs disable` | `packs(enable: false)` | loosening | |
| `rv safety set normal` / `strict` | `safety` | loosening / tightening | |
| `rv allowlist add`, `add-command` | `allowlistAddRule`, `allowlistAddCommand` | loosening | rvd computes `matchingView` and the digests (`AllowlistCommand.swift:134-140`) itself. |
| `rv allowlist remove` | `allowlistRemove` | tightening | |
| `rv policy apply --save` | `policyApply` | loosening | rvd re-runs `PolicyDiffRisk.evaluateShare` and refuses blocking findings itself. |
| `rv policy draft --save` | `policyDraftSave` | loosening | The CLI compiles the English. rvd parses, risk-checks and saves the document. |
| `rv policy export --output` | none | n/a | Drop the gate and the flag. Stdout plus shell redirection does the same thing, and rvd must not write arbitrary paths. |
| `rv egress approve` / `deny` | `egressDecide` | loosening / tightening | Moves `EgressReviewRun` resolve CAS into rvd. |
| `rv workspace abandon` | `workspaceAbandon` | loosening (destroys data) | rvd runs the `WorkspaceHosts.abandon` body. |
| `rv allow-once <code>` / `mint` | `allowOnceRedeem` / `allowOnceMint` | loosening | Section 9. |
| identity launch | later | loosening | The route's proof replaces the UI completion that issues the Step 3 permit. Redemption stays as is. |

`SelfProtectionGuard` stays. The hook path keeps flooring these commands at indeterminate, because an agent should not even start the ceremony from its shell.

## 9. Allow-once on Linux

Today: a hook deny writes a pending row and prints a code. The CLI reads the row, runs LA, re-reads, then attests (`AllowOnceCommand.swift:56-79`). The code is not a secret, since the agent sees it in the hook output. It only names the row.

New flow:

1. `rv allow-once a1b2c3` sends `allowOnceRedeem(codeHash: sha256(code))`. The code itself never crosses IPC, as today (`IPCTTYAttest.swift:23-25`).
2. rvd reads the pending row itself, through the same `AllowOnceStore` (`Sources/RVPolicy/AllowOnceStore.swift`). It builds the operation from that row: fingerprint, cwd, payload digest, redacted command, rule ID and invocation tag (the same fields as `redeemReason`, `AllowOnceCommand.swift:94`). The precondition is the row digest. Unknown, expired or spent codes are refused before any prompt, which keeps today's rule that garbage codes never prompt (`:129-140`).
3. Proof: `polkit` on desktop Linux, `signedApproval` elsewhere. On macOS, `daemonLocalAuthentication`, falling back to `cliAttestation`.
4. rvd re-reads the row, compares, and calls `grants.plant(...)` exactly as `attestTTYRedemption` does (`ServiceRuntime.swift:476-482`), keeping per-epoch code single-use.
5. The CLI flips its display row after `applied`, as today. rvd still never writes the projection file (`ServiceRuntime.swift:485-487`).

On Linux without a desktop agent or a paired device, `rv allow-once` prints: "no presence method on this machine: use a desktop session or pair a device (`rv owner pair`)". It never falls back to a TTY code.

## 10. Remote approvals

A remote approval is one more proof provider. The route, the state machine and apply do not change.

- **Pairing** is itself an owner action (`ownerPair`), approved locally with LA or polkit. The phone generates a P-256 or Ed25519 key in its secure hardware and shows its public key as a QR code. rvd stores the pin only where section 6 allows (managed directory, Keychain, or attested). A pin in plain `~/.config/rv` is refused for this method.
- **Request.** `rv owner wait --remote` (or rvd, if section 14 allows rvd network access) posts `{operationID, canonicalOperation, tag, expiresAt}` to the relay. The canonical operation carries redacted display fields plus digests, never secret values or MCP arguments. This matches the control-plane rule in `docs/plans/agent-governance/control-plane-spec.md:96-98`.
- **Phone.** It renders the display from the canonical bytes, recomputes the digest, and signs `{v, operationID, digest, epoch, decision, deviceID, notBefore, expiresAt}`. The relay is untrusted. It cannot swap the operation, because the phone hashes what it shows.
- **rvd** verifies the signature against the pin, checks that the digest equals the retained one, that the epoch matches, and that the approval is unexpired and unused. It then applies as for any other proof. `decision: deny` cancels the operation.
- **Enterprise.** The control plane's signed approval (`control-plane-spec.md:85-90`) uses the same verifier with the root-pinned approvals key. With `localApproval: false`, rvd stops advertising local methods.

## 11. Failure modes

| Event | Result | User sees |
| --- | --- | --- |
| rvd restarts between propose and confirm | new epoch, `unknown` | "rv restarted; run the command again" |
| Proposing connection drops | `cancelled` | nothing (the CLI is gone) |
| Proof window passes | `expired`, evidence discarded | "timed out; nothing changed" |
| Another operation is awaiting proof | `busy` with its display | "another owner action is waiting: <tag> <summary>; `rv owner cancel` to clear" |
| State changed between display and apply | `changed`, no write | "the config changed while you reviewed; nothing changed" |
| Write fails after proof | `failed`, no retry | "write failed; nothing applied; run again" |
| LA or polkit unavailable | `unavailable`, other methods listed | which methods exist here |
| User cancels the dialog | `refused` | "not approved" |
| Old rvd, new CLI | `unknownMethod` | today's refusal text |
| New rvd, old CLI | old CLI still throws locally | unchanged |
| Signed approval bad, replayed or for another digest | `refused`, audited | "approval rejected" |
| Flood of proposals | rate-limited `refused`, audited | "too many requests" |

## 12. Tests

Unit (no platform prompts, injected authenticators as in `ControlAuthorizationTests`):

- `Tests/RVServiceTests/OwnerActionAuthorizerTests.swift`: every transition; single-use under racing confirms; monotonic expiry with wall-clock rollback; epoch rejection after re-init; the `busy` rule; disconnect cancel; precondition mismatch gives `changed` with no write; a failed apply is never retried.
- `Tests/RVServiceTests/OwnerActionDispatchTests.swift`: the authorization matrix (a socket peer may propose and confirm only its own operation; `nil` peer is denied; `.ownerMutation` methods are still denied for every role, extending `SocketPeerAuthorizationTests`); a wrong digest is refused; a confirm from another connection is refused.
- `Tests/RVServiceTests/OwnerActionApplyTests.swift`: one test per request kind against a temp home, asserting the exact file diff and the audit events.
- `Tests/RVServiceTests/PolkitProofTests.swift`: a fake `pkcheck` and fake `loginctl` (exit 0, 1, 2, 3; remote session; TTY session; X11) map to the right status. The method is not advertised when the action file is missing.
- `Tests/RVServiceTests/SignedApprovalTests.swift`: signature, digest, epoch, expiry, replay, unpinned key, and a pin read from user-writable config being refused.
- `Tests/RVIPCTests/OwnerActionWireTests.swift`: round trips, unknown kind rejected, size bounds, and byte stability of the canonical encoding (golden vectors shared with the phone app).
- `Tests/RVCLITests/LocalControlBoundaryTests.swift`: rewritten so each command in section 8 sends the right request kind and no longer writes config in-process.
- `Tests/RVCLITests/AllowOnceCommandRunTests.swift`: the Linux redeem path, and garbage codes never reaching a proof.

Platform proof (manual checklist, then a self-hosted job):

- macOS: rvd raises LA from its LaunchAgent for each kind. SSH session reports `unavailable`. Cancel gives `refused`.
- Linux desktop VM (GNOME on Wayland): polkit dialog, wrong password, cancel, SSH session refused, X11 warning.
- An adversarial script: a same-user Python process that opens the socket, proposes, confirms and polls never reaches `applied` without a human. This also runs as an automated test with every authenticator stubbed to "no human".

## 13. Rollout

1. **Phase 0: wire and actor.** `IPCOwnerAction.swift`, `OwnerActionAuthorizer`, dispatch, all tests. rvd answers `unavailable` for every method. No CLI change.
2. **Phase 1: macOS, small surface.** `daemonLocalAuthentication`. Migrate packs, safety and allowlist. Delete their in-CLI bodies.
3. **Phase 2: macOS, the rest.** Egress, policy apply and draft, workspace abandon, and allow-once through the route, with `attestTTYRedemption` kept for one release for older CLIs. Drop `policy export --output`.
4. **Phase 3: Linux.** The polkit method, the action file in `rv setup`, and allow-once on Linux. `rv doctor` reports which methods are available.
5. **Phase 4: remote.** `rv owner pair`, the signed approval verifier, and the relay client. The enterprise verifier comes with control-plane CP2.
6. **Phase 5: cleanup.** Delete `LocalControlBoundary`. Remove `pendingResolve`, `ruleSave` and `setPackEnabled` from the wire at the next major. Consider moving HookReviewCeremony and the identity-launch permit onto `OwnerActionAuthorizer`.

Each phase ships behind the CLI's `unknownMethod` fallback, so mixed versions fail closed.

## 14. Decisions for the owner

1. **Tightening without proof.** Should safety strict, allowlist remove and egress deny apply with peer authentication only? *Recommendation:* yes for those three. Treat `packs enable` as loosening until pack semantics prove that enabling can only add denies.
2. **macOS primary method.** Should rvd raise LA itself, or keep the pinned CLI as the anchor? *Recommendation:* rvd-side LA. It works on one-click installs and the prompt text comes from rvd. Keep `cliAttestation` as a fallback for one release.
3. **Linux X11 sessions.** Should polkit proofs be refused on X11, given same-session keylogging? *Recommendation:* allow, with an audit mark and a `rv doctor` warning. Refusing would leave most X11 users with no path at all. Revisit once remote approvals ship.
4. **FIDO2 security keys.** Should we add `securityKey` (libfido2 via dlopen, attestation checked against built-in vendor roots)? *Recommendation:* not in this plan. Polkit and phone approvals cover desktop and headless use. FIDO2 adds a C dependency and a weak display binding.
5. **Who talks to the relay.** Should rvd make outbound network calls for remote approvals, or only the CLI (`rv owner wait --remote`)? *Recommendation:* CLI only at first. rvd stays offline, and a human is at a terminal anyway.
6. **Key pin storage for personal Linux.** Should a paired-device pin require the root-owned managed directory, which needs sudo once at pairing? *Recommendation:* yes. A pin in `~/.config/rv` lets any same-user agent forge approvals.
7. **One awaiting operation machine-wide.** Is the `busy` rule acceptable, given an agent can hold the slot for up to 120 s? *Recommendation:* yes. It is an availability cost only. The alternative lets one touch or password be spent on the wrong operation.
8. **`rv policy export --output`.** Remove the flag, or route it? *Recommendation:* remove it. Writing to stdout is enough, and rvd must not write caller-chosen paths.
9. **Identity launches.** Should identity launches be unblocked through this route (proof replaces the UI completion that issues the Step 3 permit) in Phase 2, or wait for RVOperatorUI? *Recommendation:* use this route in Phase 2. It also unblocks Agent Instances in the micro-VM (see `docs/plans/packs-in-cage/SPEC.md`).
