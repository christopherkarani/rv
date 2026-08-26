# Modules

Each module keeps a small public API, `package` internals later, and its own test target. Hexagonal: dependency arrows down. Engine never imports CLI, TUI, or XPC. A test that needs a TTY to prove a **decision** is in the wrong module.

`RVHistory` is a **stub**. History stays off by default. Do not persist command text.

`RVAnalytics` owns anonymous product analytics (PostHog). Opt-out via `analytics.enabled` in `~/.config/rv/config.json` (missing = on). Never command text, paths, or secrets. Host hook processes never call it.

## Owns / Must not

| Module | Owns | Must not |
|---|---|---|
| **RVDomain** | `Decision`, `Severity`, `PackID`, `RuleID`, `SecretPathCatalog`, `EvaluationRequest/Result`, Explain pipeline (`ExplainStep`), `ProposedAction`, `HardPolicyDecision`, `ActionPolicyEngine`, `ActionReviewer`, `PendingApproval`, `HostNativeAsk`, `ApprovalBridge` | I/O, TTY, XPC |
| **RVEngine** | normalize, quick-reject, safe then destructive, secret-path on allow, deadline, `PatternEngine` | pack files, hooks |
| **RVPacks** | registry, bundled JSON, enable/disable | decisions, rendering |
| **RVScan** | session-store discovery, bounds walk, store adapters, extract, classify, dedupe | CLI, TUI, XPC, hooks codecs, Policy gate |
| **RVPolicy** | config merge, allowlist, allow-once, `HostGrantWriter`, durable `PendingApprovalStore`, Apple Foundation Models `ActionReviewer` adapter (shadow), `ShadowReviewRunner` | rendering |
| **RVHooks** | **Pi / Grok / OpenCode / Claude / OpenClaw / Hermes** Host adapters: shell codecs, Hook mapper/voice, Pi/OpenCode confirm-or-resolution spend-then-allow, Claude deny-or-TTY (no leftover `permissionDecision` ask), embedded adapter resources | evaluation, setup mutations |
| **RVIPC** | `rv.ipc.v1` Codable | transport details |
| **RVService** | XPC listener, EvaluationWorld (single assembly), EvaluateSession (compiled day-one packs + evaluate), GatedEvaluate (session then Policy gate), launchd | ArgumentParser, SwiftUI |
| **RVPresentation** | deny/explain/packs/doctor view models | ANSI |
| **RVTheme** | palettes, pure capability detect | business rules |
| **RVTUI** | `FrameRenderer` `render` → `[String]` | opening a TTY |
| **RVCLI** | ArgumentParser, output mode, thin XPC client, typed service diagnostics, service health facts, GatedEvaluate for TTY test/explain and hook XPC miss, Host adapter installation state + setup mutations | regex, pack parse |
| **RVHistory** | stub; later; off by default | logging full argv |
| **RVAnalytics** | anonymous install / DAU / product counters; PostHog sink; opt-out preferences; `AnalyticsNotice` seam | command text, paths, secrets; hook-process I/O |

## Dependency graph

| Target | Dependencies | Notes |
|---|---|---|
| `RVDomain` | none | Types in T1. |
| `RVTheme` | none | Palettes in T2. No business rules. |
| `RVEngine` | `RVDomain` | Must not depend on Packs, Hooks, CLI, TUI, Service. |
| `RVPacks` | `RVDomain` | Bundled catalog JSON (95 packs, excluding `windows.*` OS catalogs); default-on remains core only. |
| `RVScan` | `RVDomain`, `RVEngine`, `RVPacks` | Session forensics: bounds, discovery walk, `SessionStoreAdapter`; classify later. No CLI/TUI/Service/Hooks. |
| `RVPolicy` | `RVDomain` | Packs config merge; allowlist / allow-once; AFM shadow reviewer. Darwin: CryptoKit. Linux: `Crypto` (swift-crypto) added on that graph only. |
| `RVHooks` | `RVDomain` | Complete Pi/Grok/OpenCode/Claude/OpenClaw/Hermes Host adapter behavior (`ClaudeHostCodec` + rich deny; OpenClaw/Hermes short deny); no setup mutations. |
| `RVIPC` | `RVDomain` | `rv.ipc.v1` Codable later. |
| `RVHistory` | `RVDomain` | **Stub.** Off by default forever until a later ticket enables it. Must not log argv. |
| `RVAnalytics` | none | Store actor allowed. Network only in PostHog sink. |
| `RVPresentation` | `RVDomain`, `RVTheme` | View models later. No ANSI. |
| `RVTUI` | `RVTheme`, `RVPresentation` | `FrameRenderer.render` → `[String]`. Must not open a TTY. |
| `RVService` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVHistory`, `RVAnalytics` | XPC/`NSObject` edge later. No ArgumentParser, no SwiftUI, no TUI/CLI/Presentation. |
| `RVCLI` | `RVDomain`, `RVEngine`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVPresentation`, `RVTheme`, `RVTUI`, `RVService`, `RVHistory`, `RVAnalytics` | Thin client; typed service diagnostics; service health facts shared by doctor and status; GatedEvaluate for TTY test/explain and hook XPC miss; read-only Host adapter installation state shared by setup and doctor. No regex, no pack parse. |

Each module has a matching `*Tests` target that depends only on that module.

On Linux (OPE-261–262), `RVService`, `rvd`, `RVCLI`, `rv`, and their tests are on the graph. XPC types stay behind `#if canImport(XPC)`; Linux `rvd` listens on AF_UNIX under `$XDG_RUNTIME_DIR`. The C `rv` hook talks that socket; miss still execs `rv-cli`. Darwin `RVPolicy` stays `RVDomain` + CryptoKit; Linux `RVPolicy` adds `Crypto` (swift-crypto).

**Semantic policy (OPE-157).** `ActionPolicyEngine` is the pure evaluator: `ProposedAction` + context + `EffectiveActionPolicy` → `HardPolicyDecision`. Built-in `hardDeny` / `mandatoryHuman` cannot be weakened by repo/user overlay or `ReviewBind` (including a stub `.allow`). Legacy pack verdicts apply only when no semantic rule covers the action. `supportingCommand` is evidence, not the primary input.

**Shadow review (OPE-250).** `FoundationModelsActionReviewer` implements `ActionReviewer` in RVPolicy (`#if canImport(FoundationModels)`). `ShadowReviewRunner` invokes it only for `HardPolicyDecision.reviewEligible` and records a `ShadowReviewRecord` (decision, confidence, rationale category, latency, disagreement, missing-context reasons, model-unavailable). The live decision is the deterministic/human path; the runner never calls `ReviewBind.apply`. The runner consumes the engine's `HardPolicyDecision` — it does not turn shadow into live Auto-review (OPE-253). Promotion thresholds live in `AutoReviewPromotionThresholds` and are measurement constants only.
