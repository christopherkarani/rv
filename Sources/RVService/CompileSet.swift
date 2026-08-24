import RVDomain

/// Pack IDs an `EvaluateSession` compiles. Distinct from `WalkSet`; no conversion.
/// Sequence keeps `Set(enabledIDs(...))` compiling without editing ServiceRuntime.
package struct CompileSet: Sendable, Equatable, Sequence {
    package var ids: [PackID]

    package init(ids: [PackID]) {
        self.ids = ids
    }

    package func makeIterator() -> Array<PackID>.Iterator {
        ids.makeIterator()
    }
}
