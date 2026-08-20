# Modules

Each module keeps a small public API, `package` internals later, and its own test target. Hexagonal: dependency arrows down. Engine never imports CLI, TUI, or XPC. A test that needs a TTY to prove a **decision** is in the wrong module.

`RVHistory` is a **stub**. History stays off by default. Do not persist command text.

`RVAnalytics` owns anonymous product analytics (PostHog). Opt-out via `analytics.enabled` in `~/.config/rv/config.json` (missing = on). Never command text, paths, or secrets. Host hook processes never call it.

## Owns / Must not

| Module | Owns | Must not |
|---|---|---|
| **RVDomain** | `Decision`, `Severity`, `PackID`, `RuleID`, `EvaluationRequest/Result`, Explain pipeline (`ExplainStep`) | I/O, TTY, XPC |
| **RVEngine** | normalize, quick-reject, safe then destructive, deadline, `PatternEngine` | pack files, hooks |
| **RVPacks** | registry, bundled JSON, enable/disable | decisions, rendering |
| **RVPolicy** | config merge, allowlist, allow-once | rendering |
| **RVHooks** | **Pi / Grok / OpenCode** Host adapters: shell codecs, Hook mapper/voice, embedded adapter resources | evaluation, setup mutations |
| **RVIPC** | `rv.ipc.v1` Codable | transport details |
| **RVService** | XPC listener, EvaluateSession (compiled day-one packs + evaluate), GatedEvaluate (session then Policy gate), launchd | ArgumentParser, SwiftUI |
| **RVPresentation** | deny/explain/packs/doctor view models | ANSI |
| **RVTheme** | palettes, pure capability detect | business rules |
| **RVTUI** | browse kit, `render` → `[String]`, key map | opening a TTY |
| **RVCLI** | ArgumentParser, output mode, thin XPC client, typed service diagnostics, service health facts, GatedEvaluate for TTY test/explain and hook XPC miss, Host adapter installation state + setup mutations | regex, pack parse |
| **RVHistory** | stub; later; off by default | logging full argv |
| **RVAnalytics** | anonymous install / DAU / product counters; PostHog sink; opt-out preferences; `AnalyticsNotice` seam | command text, paths, secrets; hook-process I/O |

## Dependency graph

| Target | Dependencies | Notes |
|---|---|---|
| `RVDomain` | none | Types in T1. |
| `RVTheme` | none | Palettes in T2. No business rules. |
| `RVEngine` | `RVDomain` | Must not depend on Packs, Hooks, CLI, TUI, Service. |
| `RVPacks` | `RVDomain` | Bundled catalog JSON (99 packs); default-on remains core only. |
| `RVPolicy` | `RVDomain` | Packs config merge; allowlist / allow-once. |
| `RVHooks` | `RVDomain` | Complete Pi/Grok/OpenCode Host adapter behavior; no setup mutations. |
| `RVIPC` | `RVDomain` | `rv.ipc.v1` Codable later. |
| `RVHistory` | `RVDomain` | **Stub.** Off by default forever until a later ticket enables it. Must not log argv. |
| `RVAnalytics` | none | Store actor allowed. Network only in PostHog sink. |
| `RVPresentation` | `RVDomain`, `RVTheme` | View models later. No ANSI. |
| `RVTUI` | `RVTheme`, `RVPresentation` | `reduce` + `render` later. Must not open a TTY. |
| `RVService` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVIPC`, `RVHistory`, `RVAnalytics` | XPC/`NSObject` edge later. No ArgumentParser, no SwiftUI, no TUI/CLI/Presentation. |
| `RVCLI` | `RVDomain`, `RVEngine`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVPresentation`, `RVTheme`, `RVTUI`, `RVService`, `RVHistory`, `RVAnalytics` | Thin client; typed service diagnostics; service health facts shared by doctor and status; GatedEvaluate for TTY test/explain and hook XPC miss; read-only Host adapter installation state shared by setup and doctor. No regex, no pack parse. |

Each module has a matching `*Tests` target that depends only on that module.
