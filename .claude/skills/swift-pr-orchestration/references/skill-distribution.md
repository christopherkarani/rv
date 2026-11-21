# Skill Distribution

Use the smallest skill set that covers the PR. The planning agent may add a project-specific skill after inspecting the repository.

| PR scope | Review skills | Implementation skills |
|---|---|---|
| Swift API or compatibility | `swift-adversarial-pr-review`, `swift-api-design-guidelines` | `swift-api-design-guidelines`, `swift-testing-pro` |
| Swift concurrency, actors, task groups, cancellation | `swift-adversarial-pr-review`, `swift-concurrency` | `swift-concurrency`, `swift-testing-pro` |
| Functional/state-machine/refactor | `swift-functional-codebase-evolution`, `swift-adversarial-pr-review` | `swift-functional-codebase-evolution`, `swift-testing-pro` |
| SwiftPM products, macros, traits, platforms | `swift-adversarial-pr-review`, `swift-architecture-pipeline` | `swift-architecture-pipeline`, `swift-testing-pro` |
| Test-only or documentation contract | `swift-testing-pro`, `swift-api-design-guidelines` | `swift-testing-pro` |

For every agent, include the exact PR base/head, owned files, acceptance tests, and a reminder to preserve other agents’ work. Do not attach unrelated skills merely to increase coverage; skill loading is part of the plan and should be explainable.
