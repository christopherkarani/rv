#if os(macOS)
import Testing
@testable import RVCLI
import RVIsolation

/// `rv workspace run` prints these through `ValidationError`. The strings are
/// the ones the CLI printed before the session moved into RVIsolation, so a
/// change here is a user-visible change.
struct WorkspaceTerminalFailureTextTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let failure: WorkspaceTerminalSessionFailure
        let resourceProfileID: String?
        let text: String

        var testDescription: String { "\(failure) profile=\(resourceProfileID ?? "nil")" }
    }

    static let rows: [Row] = [
        // Launch failures echo the requested profile.
        Row(
            failure: .launch(.resourceProfileUnavailable), resourceProfileID: "gpu",
            text: "runtime resource profile 'gpu' is unavailable for this project"
        ),
        Row(
            failure: .launch(.resourceProfileUnavailable), resourceProfileID: nil,
            text: "runtime resource profile is unavailable"
        ),
        Row(
            failure: .launch(.resourceStagingFailed("/cache")), resourceProfileID: "gpu",
            text: "runtime resource profile 'gpu' staging failed: /cache is unusable"
        ),
        Row(
            failure: .launch(.resourceStagingFailed("/cache")), resourceProfileID: nil,
            text: "runtime resource staging failed: /cache is unusable"
        ),
        Row(
            failure: .launch(.disconnected), resourceProfileID: "gpu",
            text: "workspace host disconnected"
        ),
        Row(
            failure: .launch(.disconnected), resourceProfileID: nil,
            text: "workspace host disconnected"
        ),
        Row(failure: .noTerminal, resourceProfileID: "gpu", text: "runtime has no terminal"),
        Row(failure: .noTerminal, resourceProfileID: nil, text: "runtime has no terminal"),
        // Session failures after launch never echo the profile.
        Row(
            failure: .client(.resourceProfileUnavailable), resourceProfileID: "gpu",
            text: "runtime resource profile is unavailable"
        ),
        Row(
            failure: .client(.resourceStagingFailed("/cache")), resourceProfileID: "gpu",
            text: "runtime resource staging failed: /cache is unusable"
        ),
        Row(failure: .client(.disconnected), resourceProfileID: "gpu", text: "workspace host disconnected"),
        Row(failure: .client(.disconnected), resourceProfileID: nil, text: "workspace host disconnected"),
        Row(
            failure: .client(.terminalBusy), resourceProfileID: nil,
            text: "terminal input is owned by another client"
        ),
        Row(failure: .fellBehind, resourceProfileID: "gpu", text: "terminal client fell behind"),
        Row(failure: .fellBehind, resourceProfileID: nil, text: "terminal client fell behind"),
        // Not "host disconnected": the host is fine, the local reader left.
        Row(failure: .outputClosed, resourceProfileID: "gpu", text: "terminal output closed"),
        Row(failure: .outputClosed, resourceProfileID: nil, text: "terminal output closed"),
    ]

    @Test(arguments: rows)
    func workspaceTerminalFailureTextIsUnchanged(_ row: Row) {
        #expect(
            WorkspaceCommandRun.text(row.failure, resourceProfileID: row.resourceProfileID) == row.text
        )
    }
}
#endif
