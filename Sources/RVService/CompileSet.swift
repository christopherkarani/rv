import RVDomain

/// Pack IDs an `EvaluateSession` compiles. Distinct from `WalkSet`; no conversion.
package struct CompileSet: Sendable, Equatable {
    package var ids: [PackID]

    package init(ids: [PackID]) {
        self.ids = ids
    }
}

extension Set where Element == PackID {
    /// ServiceRuntime calls `Set(enabledIDs(...))`. CompileSet is not a Sequence.
    package init(_ compileSet: CompileSet) {
        self.init(compileSet.ids)
    }
}
