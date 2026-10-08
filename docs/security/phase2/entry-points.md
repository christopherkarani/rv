# Phase 2 local authority inventory

Independently traced from hardened HEAD before implementation. This records actual
routes, including routes not mentioned in the old plan. Names in payloads never
establish roles. This is an incomplete implementation audit, not release approval.

| Entry point | Classification | Transport / baseline auth | Caller fields | Required role / principal source | Draft failure mode |
|---|---|---|---|---|---|
| rvd XPC | Agent authority, control read/mutation, policy mutation | Mach messages; handshake only | Entire request, host, session, stdin, cwd | Verified component; host-bound live agent or exact owner operation | New peer capture, matrix denies unsupported authority |
| Unix daemon | Same as XPC | Linux AF_UNIX; pathname mode only | Entire request | Kernel peer + mutually authenticated server + live host binding | No context means authority denied; Linux platform proof absent |
| Swift hook | Agent authority | IPC or local fallback | HookHost/stdin | Live authenticated agent channel | No local authority fallback; deny on failure |
| C hook | Agent authority | IPC or replay to CLI | Host/stdin | Live authenticated channel + server | Entire authority hook unavailable pending mutual C auth |
| Generic evaluation | Agent authority or explicit diagnostic | IPC / in-process | Request/cwd | Live principal for authority; pure diagnostic otherwise | RPC denied; local fallback empty-store peek |
| Hello/version | Diagnostic | IPC handshake | Version/name | None | No authority granted |
| Explain/classify/list packs/doctor | Diagnostic | IPC/local peek | Request/cwd | None only for read/peek semantics | Unprivileged diagnostic path |
| Pending list/watch | Control read | IPC | Generation | Authorized reader separate from agent | CLI identity alone denied |
| Pending resolve | Control mutation | IPC | ID/decision/fingerprint/integration labels | Owner auth + live subject + exact CAS | Production unavailable |
| Rule preview/save | Control read/policy mutation | IPC | ID/draft/polarity | Reader; owner auth bound to draft+target | Save unavailable |
| Pack enablement | Policy mutation | IPC/direct CLI | ID/enable/HOME | Exact owner operation | Denied/unavailable |
| Workspace control socket | Workspace control | Same UID + owner token | Token/IDs/launch/terminal data | Verified component plus scoped control permit; live host registry | Peer capture added; mutation/terminal operations unavailable |
| Workspace client | Workspace control | Endpoint inode/mode | Endpoint file | Live verified host before token disclosure | Unverifiable host denied before Hello token |
| Admission FDs4/5 | Agent authority | Inherited pipes + runtime capability | Runtime claim/capability/action | Existing host-minted runtime binding | Phase1 preserved; FD forwarding/non-forwardability proof outstanding |
| Admitted HTTP | Agent authority/internal host | Admission pipes | Method/URL/action | Live authoritative runtime binding | Existing path preserved; full Phase2 audit outstanding |
| EgressProxy | Agent authority | Loopback TCP, no credential | CONNECT/destination/bytes | Authenticated live runtime channel | OPEN BLOCKER: native proxy channel not authenticated |
| Direct allow-once mint/redeem/clear | Control mutation | TTY + direct file store | Code/command/cwd/HOME | Fresh exact owner authorization | Direct CLI writes unavailable |
| Allow-once list | Control read | Direct file store | HOME | Authorized reader | OPEN BLOCKER: direct row inspection remains |
| spendHostAsk | Control mutation | Direct store | Command/cwd/host | Owner permit or internal host capability | Denied; cannot plant grant |
| Policy apply --save | Policy mutation | Direct file | Policy/destination | Exact owner draft/target authorization | Unavailable |
| Policy draft --save | Policy mutation | Direct upsert | English/repo/HOME | Exact owner draft/target authorization | Unavailable before compile |
| Policy export --output | Potential policy mutation | Arbitrary local file write | Output path | Owner authorization for authoritative destination | Explicit file output unavailable; stdout remains diagnostic |
| Safety normal/strict | Policy mutation | Direct configuration file | Level/HOME | Owner authorization | Unavailable |
| Allowlist add/add-command/remove | Policy mutation | TTY + direct exception store | ID/command/cwd/HOME | Owner authorization | Unavailable |
| Workspace operator abandon | Workspace control | Journal/filesystem owner checks | Workspace path | Scoped owner permit | Unavailable; automated recovery untouched |
| Automatic crash recovery | Internal trusted host | Ownership/journal/start evidence | Host-selected state | Trusted ownership state only | Preserved; no human prompt added |
| Workspace-host bootstrap | Workspace control/internal host | Direct executable invocation | Workspace/args/env | Authenticated parent launch permit | OPEN BLOCKER: parent bootstrap authentication absent |
| Launch/helper fd3 | Internal trusted host | Parent-created pipe/helper path | Bootstrap args/env | Trusted host channel; no owner authority implied | Phase1 preserved; forwarding containment proof outstanding |
| Setup/install/host attach/detach/uninstall | Policy/control mutation | Direct file/process writes | Paths/config | Exact owner operation | Guarded at CLI and lifecycle boundaries; replacement unavailable |
| Direct same-user store/file writes | Policy/control mutation | Filesystem UID/mode | Raw files | Protected authoritative state and containment | OPEN BLOCKER: CLI guards alone cannot authenticate file bytes |

No further inbound localhost RV service found in Sources beyond daemon Unix,
workspace Unix and EgressProxy TCP. Outbound connectors are not inbound entry points.
Additional writers (policy draft, safety, export, allowlist) were discovered and
independently confirmed during fresh review; they are included above.
