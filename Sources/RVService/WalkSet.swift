import RVDomain

/// Pack IDs on `EvaluationRequest.enabledPacks`. Empty means none. Distinct from `CompileSet`.
package struct WalkSet: Sendable, Equatable {
    package var ids: [PackID]

    package init(ids: [PackID]) {
        self.ids = ids
    }
}
