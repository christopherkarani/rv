# Package.swift ownership

Home for who may edit the graph. `MODULES.md` is home for arrows. `PLAN.md`
parallel rules win conflicts **except** the T2/T3 entry-point files below —
SwiftPM 6.3 rejects `main.swift` / `@main` inside a library product.

## Graph snapshot

Until T2: twelve library products, no executables, no ArgumentParser.
`RVCorpusTests` is the only allowed extra test target (depends on `RVDomain`,
`RVEngine`, `RVPacks`).

T2 adds executable product `rv` (separate target). Do not delete `rv` to
restore the pre-T2 snapshot.

`RVEngine` must not gain a `RVPacks` dependency.

## Who may add what

| Ticket | May add | Must not |
|---|---|---|
| T0 | The twelve libraries + matching `*Tests` | Executables, ArgumentParser, `RVCorpusTests` |
| T1 | `RVCorpusTests` only | Executables, ArgumentParser, Engine→Packs |
| T2 | `apple/swift-argument-parser` `from: "1.7.0"`, product `rv`, `executableTarget` `rv` at `Sources/rv/main.swift` that calls `RV.main()`. Keep `RVCLI` a library (`ParsableCommand`, no `@main`, no `main.swift`). | Product `rvd`, IPC/Service files, `Sources/RVCLI/main.swift` |
| T3 | Product + `executableTarget` `rvd` at `Sources/rvd` depending on `RVService`. Keep `RVService` a library. | ArgumentParser, product `rv`, `Sources/RVCLI/main.swift`, `Sources/RVService/main.swift` / `@main` |
| T4–T5 | Nothing in the library graph unless a spec says so | A second hooks module |
| T6–T9 | Only what that ticket’s spec names | A surprise executable |
| T10 | Nothing in the library graph. `tools/release.sh` + `install.sh` bundle copy | `Package.swift`, `Sources/` |
| T11–T14 | Nothing in the library graph. File ownership is `docs/factory/specs/phase-5-size-speed.md` | A new product, target, or SPM dependency |
| T15+ (fence) | Thin hook executable — **merge plan required** | Do not add `rv-hook` in T10–T14 |

T2 and T3 run in **separate worktrees**. They must not both edit
`products` / `dependencies` / `targets` without a merge plan.

Exclusive lines: T2 = ArgumentParser pin + `executableTarget`/`product` `rv`
+ `Sources/rv/main.swift`. T3 = `executableTarget`/`product` `rvd` +
`Sources/rvd`. Neither writes `Sources/RVCLI/main.swift` or
`Sources/RVService/main.swift`.

T3 proves `rv service status` **in-process** (`ServiceStatusReport`). Process
`rv service status` waits for T2’s `rv` product.

## Merge-plan trigger

Stop and write a merge plan if the change needs:

- a new library target
- a new executable besides the ticket’s one
- a new SPM dependency besides T2’s ArgumentParser pin
- retargeting an existing module’s dependencies
- `main.swift` or `@main` in any existing library target

## Worktrees

T0 serial. T1 serial after T0. After T1: T2 ∥ T3, T8 ∥ T9, then T4 then T5,
then T6 ∥ T7 if file ownership is split. Parallel agents use git worktrees
from the same base SHA. They do not share a working tree.
