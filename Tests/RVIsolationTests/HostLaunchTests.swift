import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Host-launch edges this suite encodes before production code:
/// 1. `.pi` / `.claude` + contained plan + `/usr/bin/true` → `hostUnsupported`; no spawn
/// 2. `.opencode` + observed plan → `planNotContained`; no spawn
/// 3. `.opencode` + mediated plan → `planNotContained`; no spawn
/// 4. `.opencode` + contained + `/usr/bin/true` (or `/bin/true`) → established
///    `.contained`, platform family, exit 0
/// 5. `.opencode` + contained + absolute `touch` inside `ContainmentTree` →
///    file exists, contained
/// 6. `.opencode` + contained + `touch` sibling path → contained established,
///    file absent, exit ≠ 0
@Suite("HostLaunch")
struct HostLaunchTests {
    @Test func launch_nonOpenCode_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()

        expectHostUnsupported(
            launchContainedHost(host: .pi, command: command, plan: tree.contained)
        )
        expectHostUnsupported(
            launchContainedHost(host: .claude, command: command, plan: tree.contained)
        )
    }

    @Test func launch_observedPlan_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        expectPlanNotContained(
            launchContainedHost(host: .opencode, command: command, plan: tree.observed)
        )
    }

    @Test func launch_mediatedPlan_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        let workspace = try #require(tree.contained.workspace)
        let mediated = try ContainmentTree.requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectPlanNotContained(
            launchContainedHost(host: .opencode, command: command, plan: mediated)
        )
    }

    @Test func launch_containedTrue_establishes() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        switch launchContainedHost(host: .opencode, command: command, plan: tree.contained) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            expectContainedPlatform(run.established, matching: tree.contained)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                break
            }
            #endif
            recordUnexpectedHostLaunchError(error, expected: "contained true establish")
        }
    }

    @Test func launch_containedInWorkspaceTouch_succeeds() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let command = try requireTouchCommand(arguments: [inside])
        switch launchContainedHost(host: .opencode, command: command, plan: tree.contained) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: inside))
            expectContainedPlatform(run.established, matching: tree.contained)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                #expect(FileManager.default.fileExists(atPath: inside) == false)
                break
            }
            #endif
            recordUnexpectedHostLaunchError(error, expected: "in-workspace touch")
        }
    }

    @Test func launch_containedOutsideTouch_deniedByKernel() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let command = try requireTouchCommand(arguments: [outside])
        switch launchContainedHost(host: .opencode, command: command, plan: tree.contained) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedPlatform(run.established, matching: tree.contained)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                #expect(FileManager.default.fileExists(atPath: outside) == false)
                break
            }
            #endif
            recordUnexpectedHostLaunchError(
                error,
                expected: "blocked outside touch with established contained"
            )
        }
    }
}

private enum HostLaunchFixtureError: Error {
    case missingTrue
    case missingTouch
}

private let safeTouchExecutables = ["/usr/bin/touch", "/bin/touch"]

private func requireTrueCommand() throws -> IsolatedCommand {
    for path in ["/usr/bin/true", "/bin/true"]
    where FileManager.default.isExecutableFile(atPath: path) {
        if let command = IsolatedCommand(executable: path) {
            return command
        }
    }
    Issue.record("neither /usr/bin/true nor /bin/true exists")
    throw HostLaunchFixtureError.missingTrue
}

private func requireTouchExecutable() throws -> String {
    for path in safeTouchExecutables where FileManager.default.fileExists(atPath: path) {
        return path
    }
    Issue.record("neither /usr/bin/touch nor /bin/touch exists")
    throw HostLaunchFixtureError.missingTouch
}

private func requireTouchCommand(arguments: [String]) throws -> IsolatedCommand {
    let executable = try requireTouchExecutable()
    return try #require(IsolatedCommand(executable: executable, arguments: arguments))
}

private func expectHostUnsupported(
    _ result: Result<IsolatedRunResult, HostLaunchError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .failure(.hostUnsupported):
        break
    case .failure(.planNotContained):
        Issue.record(
            "non-OpenCode contained launch must be hostUnsupported, not planNotContained",
            sourceLocation: sourceLocation
        )
    case .failure(.apply(let error)):
        Issue.record(
            "non-OpenCode contained launch must not apply, got \(error)",
            sourceLocation: sourceLocation
        )
    case .success:
        Issue.record("non-OpenCode contained launch must not spawn", sourceLocation: sourceLocation)
    }
}

private func expectPlanNotContained(
    _ result: Result<IsolatedRunResult, HostLaunchError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .failure(.planNotContained):
        break
    case .failure(.hostUnsupported):
        Issue.record(
            "OpenCode observed/mediated launch must be planNotContained, not hostUnsupported",
            sourceLocation: sourceLocation
        )
    case .failure(.apply(let error)):
        Issue.record(
            "OpenCode observed/mediated launch must not apply, got \(error)",
            sourceLocation: sourceLocation
        )
    case .success:
        Issue.record(
            "OpenCode observed/mediated launch must not spawn",
            sourceLocation: sourceLocation
        )
    }
}

private func expectContainedPlatform(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(established.mode == plan.mode, sourceLocation: sourceLocation)
    switch established.mode {
    case .contained:
        break
    case .observed:
        Issue.record("contained run must not establish observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("contained run must not establish mediated", sourceLocation: sourceLocation)
    }
    #if os(macOS)
    switch established.family {
    case .seatbelt:
        break
    case .none:
        Issue.record("Darwin contained establish must be family seatbelt", sourceLocation: sourceLocation)
    case .landlock:
        Issue.record(
            "Darwin contained establish must be family seatbelt, not landlock",
            sourceLocation: sourceLocation
        )
    }
    #elseif os(Linux)
    switch established.family {
    case .landlock:
        break
    case .none:
        Issue.record("Linux contained establish must be family landlock", sourceLocation: sourceLocation)
    case .seatbelt:
        Issue.record(
            "Linux contained establish must be family landlock, not seatbelt",
            sourceLocation: sourceLocation
        )
    }
    #else
    Issue.record("first-slice host launch requires Darwin or Linux", sourceLocation: sourceLocation)
    #endif
}

private func recordUnexpectedHostLaunchError(
    _ error: HostLaunchError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .hostUnsupported:
        Issue.record("expected \(expected), got hostUnsupported", sourceLocation: sourceLocation)
    case .planNotContained:
        Issue.record("expected \(expected), got planNotContained", sourceLocation: sourceLocation)
    case .apply(let apply):
        recordUnexpectedApplyError(apply, expected: expected, sourceLocation: sourceLocation)
    }
}

private func recordUnexpectedApplyError(
    _ error: IsolationApplyError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .backendUnavailable:
        Issue.record("expected \(expected), got backendUnavailable", sourceLocation: sourceLocation)
    case .backendMismatch:
        Issue.record("expected \(expected), got backendMismatch", sourceLocation: sourceLocation)
    case .workspaceMustBeAbsolute:
        Issue.record("expected \(expected), got workspaceMustBeAbsolute", sourceLocation: sourceLocation)
    case .workspaceDoesNotExist:
        Issue.record("expected \(expected), got workspaceDoesNotExist", sourceLocation: sourceLocation)
    case .workspacePathUnresolvable:
        Issue.record(
            "expected \(expected), got workspacePathUnresolvable",
            sourceLocation: sourceLocation
        )
    case .workspacePathUnsafe:
        Issue.record("expected \(expected), got workspacePathUnsafe", sourceLocation: sourceLocation)
    case .workspaceContainsInodeAlias:
        Issue.record("expected \(expected), got workspaceContainsInodeAlias", sourceLocation: sourceLocation)
    case .containedGuaranteesUnsupported:
        Issue.record(
            "expected \(expected), got containedGuaranteesUnsupported",
            sourceLocation: sourceLocation
        )
    case .profileNotApplicable:
        Issue.record("expected \(expected), got profileNotApplicable", sourceLocation: sourceLocation)
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandContainsNUL:
        Issue.record("unexpected NUL command rejection")
    case .commandExecutableMustBeAbsolute:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
