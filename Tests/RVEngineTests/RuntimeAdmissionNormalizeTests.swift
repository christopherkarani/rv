#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVEngine

@Suite("Runtime admission normalize")
struct RuntimeAdmissionNormalizeTests {
    @Test func insideTouchIsAllowedAndOutsideTouchIsDenied() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-norm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: workspaceURL.path))
        let subject = admissionSubject(workspace)

        let inside = try normalizeRuntimeAdmission(
            subject: subject,
            action: .shell(ShellCommand(rawValue: "touch marker"))
        ).get()
        guard case .allowed = AgentAuthorization.decide(action: inside, policy: .empty) else {
            Issue.record("inside touch must be allowed")
            return
        }

        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-outside-\(UUID().uuidString)")
        let outside = try normalizeRuntimeAdmission(
            subject: subject,
            action: .shell(ShellCommand(rawValue: "touch \(outsideURL.path)"))
        ).get()
        guard case .denied = AgentAuthorization.decide(action: outside, policy: .empty) else {
            Issue.record("outside touch must be denied")
            return
        }
    }

    @Test func uncoveredCommandStaysPending() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-norm"))
        let proposal = try normalizeRuntimeAdmission(
            subject: admissionSubject(workspace),
            action: .shell(ShellCommand(rawValue: "echo hello"))
        ).get()
        guard case .pending(let pending) = AgentAuthorization.decide(action: proposal, policy: .empty) else {
            Issue.record("echo must stay pending")
            return
        }
        #expect(pending.reason == .reviewAsk)
    }

    @Test func localhostLookupIsNotAPublicAddress() throws {
        let answers = try resolveHTTPHost("localhost").get()
        #expect(answers.isEmpty == false)
        #expect(answers.allSatisfy { $0.isPublicGlobal == false })
    }

    @Test func unwrapLimitedCommandProducesNoProposal() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-norm"))
        let proposal = normalizeRuntimeAdmission(
            subject: admissionSubject(workspace),
            action: .shell(ShellCommand(rawValue: #"python3 -c "$CMD""#))
        )
        #expect(proposal == .failure(.failed))
    }

    @Test func resolutionDoesNotStartWhenTheSessionHasStopped() {
        let lookedUp = Mutex(false)
        let result = RuntimeAdmissionStop.$shouldStop.withValue({ true }) {
            resolveHTTPHost(
                "example.com",
                deadline: Date().addingTimeInterval(5),
                lookup: { _ in
                    lookedUp.withLock { $0 = true }
                    return .failure(.failed)
                }
            )
        }
        #expect(result == .failure(.failed))
        #expect(lookedUp.withLock { $0 } == false)
    }

    @Test func resolutionReturnsWhenTheSessionStopsDuringLookup() {
        let started = Mutex(false)
        let release = Mutex(false)
        let stop = Mutex(false)
        defer { release.withLock { $0 = true } }
        DispatchQueue.global().async {
            while started.withLock({ $0 }) == false && release.withLock({ $0 }) == false {
                usleep(1_000)
            }
            stop.withLock { $0 = true }
        }
        let began = Date()
        let result = RuntimeAdmissionStop.$shouldStop.withValue({ stop.withLock { $0 } }) {
            resolveHTTPHost(
                "example.com",
                deadline: Date().addingTimeInterval(5),
                lookup: { _ in
                    started.withLock { $0 = true }
                    while release.withLock({ $0 }) == false {
                        usleep(1_000)
                    }
                    return .failure(.failed)
                }
            )
        }
        #expect(result == .failure(.failed))
        #expect(Date().timeIntervalSince(began) < 2)
    }
}

private func admissionSubject(_ workspace: WorkingDirectory) -> RuntimeAdmissionSubject {
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        host: .opencode,
        workspace: workspace,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    return RuntimeAdmissionSubject(session: session, policyWorkspace: workspace)
}
