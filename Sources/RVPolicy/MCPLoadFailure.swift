import RVFileStore

/// Shared file-read-failure mapping for the MCP config loaders
/// (`MCPToolPolicyFile`, `MCPToolkitFile`, `MCPIntegrationStore`).
///
/// All three agree arm-for-arm — a missing file loads the empty set, an
/// unopenable or unsafe location fails unsafe, unreadable and oversized
/// pass through — and differ only in the success/empty value and the
/// failure type, which stay generic. Each loader keeps its own
/// same-signature `mapLoadFailure` delegating here, so the per-loader
/// directly-testable arm coverage is unchanged.
enum MCPLoadFailure {
    /// Maps one file-read failure onto the loader's outcome. Total over
    /// `OwnerOnlyFileError`, so a new read outcome breaks the build until
    /// classified here. `missing` is the loader's empty value (always a
    /// cheap constant at the call sites, hence eager).
    static func map<Success, Failure>(
        _ error: OwnerOnlyFileError,
        missing: Success,
        unsafeLocation: Failure,
        unreadable: Failure,
        oversized: Failure
    ) -> Result<Success, Failure> {
        switch error {
        case .missing:
            return .success(missing)
        case .inaccessible, .unsafeLocation:
            return .failure(unsafeLocation)
        case .unreadable:
            return .failure(unreadable)
        case .oversized:
            return .failure(oversized)
        }
    }
}
