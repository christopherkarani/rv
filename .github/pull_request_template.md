## What and why

<!-- What changed, and why. Link the issue if there is one. -->

## How it was tested

<!-- Commands you ran (e.g. Scripts/gate.sh, swift test --filter ...) and on which platform. -->

## Checklist

- [ ] Title follows conventional commits (`feat(scope): …`, `fix(scope): …`, `docs: …`)
- [ ] Fails closed: no new path returns `allow` on error, timeout, or ambiguous input
- [ ] Bug fixes start with a failing test; gate changes add corpus cases
- [ ] User-visible changes have a line under `## [Unreleased]` in `CHANGELOG.md`
