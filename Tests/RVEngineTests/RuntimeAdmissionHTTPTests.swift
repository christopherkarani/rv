import Foundation
import RVDomain
import Testing
@testable import RVEngine

@Suite("Runtime admission HTTP resolver injection")
struct RuntimeAdmissionHTTPTests {
    @Test func stubbedPublicAddressIsPinnedAndAllowed() throws {
        let public4 = try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1]))
        var lookedUp: [String] = []
        let action = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://allowed.example/a"),
            resolve: {
                lookedUp.append($0)
                return .success([public4])
            }
        ).get()
        guard case .http(let http) = action else {
            Issue.record("expected an HTTP action")
            return
        }
        #expect(http.destination.address == public4)
        #expect(http.destination.isPublicPinned)
        #expect(lookedUp == ["allowed.example"])
        guard case .allowed = AgentAuthorization.decide(action: action, policy: .empty) else {
            Issue.record("public stubbed GET must be allowed")
            return
        }
    }

    @Test func stubbedFailureClosesWithoutAProposal() throws {
        var lookedUp: [String] = []
        let proposal = normalizeRuntimeAdmission(
            subject: try httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://down.example/"),
            resolve: {
                lookedUp.append($0)
                return .failure(.failed)
            }
        )
        #expect(proposal == .failure(.failed))
        #expect(lookedUp == ["down.example"])
    }

    @Test func stubMapAnswersTwoNamesFromOneTable() throws {
        let public4 = try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1]))
        let loopback = try #require(HTTPIPAddress(ipv4: [127, 0, 0, 1]))
        let table: [String: Result<[HTTPIPAddress], HTTPResolutionError>] = [
            "allowed.example": .success([public4]),
            "evil.example": .success([loopback]),
        ]
        var lookedUp: [String] = []
        let resolve: (String) -> Result<[HTTPIPAddress], HTTPResolutionError> = {
            lookedUp.append($0)
            return table[$0] ?? .failure(.failed)
        }
        let allowed = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://allowed.example/"),
            resolve: resolve
        ).get()
        guard case .allowed = AgentAuthorization.decide(action: allowed, policy: .empty) else {
            Issue.record("stubbed public name must be allowed")
            return
        }
        let denied = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://evil.example/"),
            resolve: resolve
        ).get()
        guard case .http(let http) = denied else {
            Issue.record("expected an HTTP action")
            return
        }
        #expect(http.destination.address == loopback)
        #expect(http.destination.isPublicPinned == false)
        guard case .denied = AgentAuthorization.decide(action: denied, policy: .empty) else {
            Issue.record("name resolving to loopback must be denied")
            return
        }
        #expect(lookedUp == ["allowed.example", "evil.example"])
    }

    @Test func literalAddressNeverReachesTheResolver() throws {
        var lookedUp = false
        let action = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://10.0.0.8/"),
            resolve: { _ in
                lookedUp = true
                return .failure(.failed)
            }
        ).get()
        #expect(lookedUp == false)
        guard case .denied = AgentAuthorization.decide(action: action, policy: .empty) else {
            Issue.record("private literal must be denied")
            return
        }
    }

    @Test func stubbedEmptyAnswerClosesWithoutAProposal() throws {
        var lookedUp: [String] = []
        let emptySuccess = normalizeRuntimeAdmission(
            subject: try httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://empty.example/"),
            resolve: {
                lookedUp.append($0)
                return .success([])
            }
        )
        #expect(emptySuccess == .failure(.failed))
        let emptyFailure = normalizeRuntimeAdmission(
            subject: try httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://empty.example/"),
            resolve: {
                lookedUp.append($0)
                return .failure(.empty)
            }
        )
        #expect(emptyFailure == .failure(.failed))
        #expect(lookedUp == ["empty.example", "empty.example"])
    }

    @Test func stubbedMixedAnswerIsForbidden() throws {
        let public4 = try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1]))
        let loopback = try #require(HTTPIPAddress(ipv4: [127, 0, 0, 1]))
        var lookedUp: [String] = []
        let denied = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(),
            action: .http(method: "GET", url: "https://mixed.example/"),
            resolve: {
                lookedUp.append($0)
                return .success([public4, loopback])
            }
        ).get()
        guard case .http(let http) = denied else {
            Issue.record("expected an HTTP action")
            return
        }
        #expect(http.destination.address == loopback)
        #expect(http.destination.isPublicPinned == false)
        #expect(lookedUp == ["mixed.example"])
        guard case .denied = AgentAuthorization.decide(action: denied, policy: .empty) else {
            Issue.record("mixed public/loopback answer must be denied")
            return
        }
    }

    @Test func shellActionNeverReachesTheResolver() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-http"))
        let action = try normalizeRuntimeAdmission(
            subject: httpAdmissionSubject(workspace: workspace),
            action: .shell(ShellCommand(rawValue: "echo hello")),
            resolve: { _ in
                Issue.record("shell must not consult the DNS resolver")
                return .failure(.failed)
            }
        ).get()
        guard case .pending = AgentAuthorization.decide(action: action, policy: .empty) else {
            Issue.record("echo must stay pending")
            return
        }
    }
}

private func httpAdmissionSubject(
    workspace: WorkingDirectory? = nil
) throws -> RuntimeAdmissionSubject {
    let directory = try #require(workspace ?? WorkingDirectory(validating: "/tmp/rv-admission-http"))
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        workspaceSessionID: WorkspaceSessionID(),
        host: .opencode,
        workspace: directory,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    return RuntimeAdmissionSubject(session: session, policyWorkspace: directory)
}
