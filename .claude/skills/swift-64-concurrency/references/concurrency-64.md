# Swift 6.4 concurrency APIs

## Async defer — SE-0493

```swift
func processFile(at url: URL) async throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        await withTaskCancellationShield {
            await flushMetrics(for: url)
            try? handle.close()
        }
    }
    try await processContents(of: handle)
}
```

The enclosing function must be `async`. Closures that `await` inside `defer`
become `async` by inference.

## Cancellation shields — SE-0504

```swift
await withTaskCancellationShield {
    // Task.isCancelled is false here even if the outer task is cancelled.
    await transaction.rollbackIfNeeded()
}
```

Outer cancellation is restored after the closure returns. Child tasks started
inside the shield can still be cancelled explicitly.

## Unused throwing tasks — SE-0520

Diagnostic group: `NoUseUnstructuredThrowingTask`. Applies to throwing
`Task.init` / `Task.immediate` / `Task.detached` whose result is neither stored
nor ignored. (`Task.immediate` itself is 6.2 / SE-0472.)

```swift
// warning: unstructured throwing task was not used
Task { try await importArticles() }

Task {
    do { try await importArticles() }
    catch { log(error) }
}

let handle = Task { try await importArticles() }
try await handle.value
```

Typed failure is available when the API already knows `Failure`:

```swift
let task: Task<String, URLError> = Task { throw URLError(.badURL) }
```

## `Continuation` — SE-0528

| Scenario | `UnsafeContinuation` | `CheckedContinuation` | `Continuation` |
| --- | --- | --- | --- |
| Double resume | UB | Runtime trap | Compile error |
| Missing resume | Hang | Warning | `fatalError` in `deinit` |
| Fast-path cost | None | Allocation + atomics | None |

```swift
let data = await withContinuation(of: Data.self) { continuation in
    bridge.store(consume continuation)
}

let data = try await withContinuation(
    of: Data.self,
    throwing: NetworkError.self
) { continuation in
    bridge.store(consume continuation)
}
```

`resume` methods are `consuming`. Success values are `consuming sending`.
When two escaping callbacks both capture the continuation, convert:

```swift
let checked = CheckedContinuation(continuation)
```

Do not deprecate `CheckedContinuation` / `UnsafeContinuation`.

## `~Sendable` — SE-0518

```swift
enum ExecutionResult: ~Sendable {
    case success
    case failure(NonSendablePayload)
}
```

Rules: on the type, not an extension; cannot also declare `Sendable`; subclasses
may still conform.

## Async `Result` — SE-0530

`Result.init(catching:)` has an async `nonisolated(nonsending)` overload:

```swift
let result = await Result { try await importArticles() }
```

## Observation tracking — SE-0506

Ordinary UI stays on `@Observable` and `Observations`. Use
`withObservationTracking(..., options:)` or `withContinuousObservationTracking`
only for middleware, widgets, or syncing two models without an async context.

## Related 6.3 (do not re-teach here)

`weak let` is SE-0481 (Swift 6.3). It unblocks `Sendable` classes that hold a
weak delegate. Use it; do not call it a 6.4 feature.
