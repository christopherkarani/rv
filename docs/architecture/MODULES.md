# Modules

Each module keeps a small public API, `package` internals later, and its own test target. Hexagonal: dependency arrows down. Engine never imports CLI, TUI, or XPC. A test that needs a TTY to prove a **decision** is in the wrong module.

`RVHistory` is a **stub**. History stays off by default. Do not persist command text.

## Owns / Must not

| Module | Owns | Must not |
|---|---|---|
| **RVDomain** | `Decision`, `Severity`, `PackID`, `RuleID`, `EvaluationRequest/Result`, Explain pipeline (`ExplainStep`) | I/O, TTY, XPC |
| **RVEngine** | normalize, quick-reject, safe then destructive, deadline, `PatternEngine` | pack files, hooks |
| **RVPacks** | registry, bundled JSON, enable/disable | decisions, rendering |
| **RVPolicy** | config merge, allowlist, allow-once | rendering |
| **RVHooks** | **Pi / Grok / OpenCode** shell codecs only in v1 | evaluation |
| **RVIPC** | `rv.ipc.v1` Codable | transport details |
| **RVService** | XPC listener, EvaluateSession (compiled day-one packs + evaluate), launchd | ArgumentParser, SwiftUI |
| **RVPresentation** | deny/explain/packs/doctor view models | ANSI |
| **RVTheme** | palettes, pure capability detect | business rules |
| **RVTUI** | browse kit, `render` → `[String]`, key map | opening a TTY |
| **RVCLI** | ArgumentParser, output mode, thin XPC client, EvaluateSession for TTY test/explain and hook XPC miss | regex, pack parse |
| **RVHistory** | stub; later; off by default | logging full argv |

## Dependency graph

| Target | Dependencies | Notes |
|---|---|---|
| `RVDomain` | none | Types in T1. |
| `RVTheme` | none | Palettes in T2. No business rules. |
| `RVEngine` | `RVDomain` | Must not depend on Packs, Hooks, CLI, TUI, Service. |
| `RVPacks` | `RVDomain` | Day-one JSON: `core.git` + `core.filesystem`. |
| `RVPolicy` | `RVDomain` | Config/allowlist later. |
| `RVHooks` | `RVDomain` | Pi/Grok/OpenCode codecs later. |
| `RVIPC` | `RVDomain` | `rv.ipc.v1` Codable later. |
| `RVHistory` | `RVDomain` | **Stub.** Off by default forever until a later ticket enables it. Must not log argv. |
| `RVPresentation` | `RVDomain`, `RVTheme` | View models later. No ANSI. |
| `RVTUI` | `RVTheme`, `RVPresentation` | `reduce` + `render` later. Must not open a TTY. |
| `RVService` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVIPC`, `RVHistory` | XPC/`NSObject` edge later. No ArgumentParser, no SwiftUI, no TUI/CLI/Presentation. |
| `RVCLI` | `RVDomain`, `RVEngine`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVPresentation`, `RVTheme`, `RVTUI`, `RVService`, `RVHistory` | Thin client; EvaluateSession for TTY test/explain and hook XPC miss. No regex, no pack parse. |

Each module has a matching `*Tests` target that depends only on that module.
