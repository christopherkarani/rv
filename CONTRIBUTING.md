# Contributing to rv

Thanks for helping. This file covers building, testing, and opening a PR.
For the domain vocabulary, read [`CONTEXT.md`](CONTEXT.md) first.

## Toolchain

- Swift 6.4 (pinned in [`.swift-version`](.swift-version)). The
  `Scripts/swift-6.4` wrapper finds the right toolchain; use it when your
  default `swift` is a different version.
- macOS 15+ on Apple Silicon, or Linux (aarch64/x86_64).
- `python3` for preflight checks and a few proof scripts.

## Build and test

```sh
swift build --build-tests      # or Scripts/swift-6.4 build --build-tests
Scripts/gate.sh                # preflight + tests for the modules you changed
swift test                     # full suite (what Linux CI runs)
```

`Scripts/gate.sh` infers test filters from your git changes, including
every test target that depends on a changed module. Pass `--filter NAME`
to choose the targets yourself. `Scripts/preflight.sh` runs the structural
checks (value types, evaluate purity, corpus) on its own.

Tests must not touch your real `~/.config/rv`. CI checks this.

## Ground rules

- **Fail closed.** On parse failure, unreadable config, a timeout, or
  anything ambiguous, the gate returns `deny` or `indeterminate`, never
  `allow`. A fix for a false positive must not add an allow path that only
  holds on the happy path.
- **Test first.** A bug fix starts with a failing test. Gate changes should
  add cases to the corpora under `Tests/RVCorpusTests` or
  `Tests/RVEngineTests/Fixtures/corpus`.
- **Keep changes small.** One concern per PR. Don't reformat or refactor
  code next to your change.

## Pull requests

- Branch from `main`.
- Title in conventional-commit form: `feat(scope): …`, `fix(scope): …`,
  `refactor: …`, `docs: …`, `test: …`, `chore: …`, `ci: …`.
- Say what changed and why, and how you tested it.
- Add a line under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md) for
  user-visible changes.
- PR CI ([`.github/workflows/pr.yml`](.github/workflows/pr.yml)) runs the
  full suite on Linux, the Linux root end-to-end checks, and one macOS job
  ("macos essentials": the service and CLI suites). The whole macOS grade
  (isolation, MCP, release-staged hook grade, macOS 15 smoke, micro-VM)
  is [`.github/workflows/macos-full.yml`](.github/workflows/macos-full.yml):
  nightly on main, by hand, or on a PR with the `ci:full` label. Add that
  label to a PR that changes Darwin isolation, MCP sandboxing, the C hook
  or release staging. All required checks must pass.

## Security issues

Do not open public issues for vulnerabilities. See
[`SECURITY.md`](SECURITY.md).

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
