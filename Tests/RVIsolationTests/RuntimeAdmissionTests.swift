#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

@Suite("RuntimeAdmission")
struct RuntimeAdmissionIsolationTests {
    @Test func allowedCommandRunsOnce() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let first = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        #expect(harness.effect.runs == 1)
        #expect(harness.effect.exists)
        #expect(first.response == .executed(exitStatus: 0))
        #expect(first.event.executionAttempted)
        #expect(first.event.session == harness.runtime.id.rawValue.uuidString)

        let replay = harness.session.submitLegacy(.success(harness.frame("touch marker", id: harness.requestID)))
        #expect(harness.effect.runs == 1)
        #expect(replay.response == .rejected(.replay))
        #expect(replay.event.executionAttempted == false)

        let sameCommand = harness.session.submitLegacy(
            .success(harness.frame("touch marker", id: UUID()))
        )
        #expect(harness.effect.runs == 1)
        #expect(sameCommand.response == .rejected(.replay))
    }

    @Test func deniedCommandDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-outside-\(UUID().uuidString)")
        let decision = harness.session.submitLegacy(
            .success(harness.frame("touch \(outside.path)"))
        )
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        if case .denied = decision.response {
        } else {
            Issue.record("outside touch must be denied, got \(decision.response)")
        }
    }

    @Test func pendingCommandDoesNotRunUntilAllowOnce() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let pending = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(harness.effect.runs == 0)
        #expect(pending.response == .pending(.reviewAsk))

        let approved = try AdmissionHarness(approval: { _, _ in .success(.allowOnce) })
        defer { approved.cleanup() }
        let decision = approved.session.submitLegacy(.success(approved.frame("echo hello")))
        #expect(approved.effect.runs == 1)
        #expect(approved.effect.exists)
        #expect(decision.response == .executed(exitStatus: 0))

        let unavailable = try AdmissionHarness(approval: { _, _ in .failure(.approvalUnavailable) })
        defer { unavailable.cleanup() }
        let refused = unavailable.session.submitLegacy(.success(unavailable.frame("echo hello")))
        #expect(unavailable.effect.runs == 0)
        #expect(unavailable.effect.exists == false)
        #expect(refused.response == .approvalUnavailable)

        let rule = try AdmissionHarness(approval: { _, _ in .success(.createRule) })
        defer { rule.cleanup() }
        let created = rule.session.submitLegacy(.success(rule.frame("echo hello")))
        #expect(rule.effect.runs == 0)
        #expect(created.response == .approvalUnavailable)
    }

    @Test func evaluationFailureDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.success(harness.frame(#"python3 -c "$CMD""#)))
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(decision.response == .evaluationFailed)
        #expect(decision.event.executionAttempted == false)
    }

    @Test func fakeCapabilityWrongSessionAndClosedChannelDoNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let other = try AdmissionHarness()
        defer { other.cleanup() }

        let fake = harness.session.submitLegacy(
            .success(harness.frame("touch marker", capability: RuntimeCapability()))
        )
        let impersonated = harness.session.submitLegacy(
            .success(harness.frame("touch marker", claim: other.runtime.id.rawValue))
        )
        let foreignToken = harness.session.submitLegacy(
            .success(other.frame("touch marker"))
        )
        #expect(fake.response == .rejected(.invalidCapability))
        #expect(impersonated.response == .rejected(.impersonation))
        #expect(foreignToken.response == .rejected(.invalidCapability))
        #expect(harness.effect.runs == 0)

        let encoded = try RuntimeAdmissionCodec.encodeRequest(harness.frame("touch marker")).get()
        harness.session.finish()
        let stale = harness.session.accept(encoded)
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(stale.first?.response == .rejected(.inactiveSession))
        #expect(stale.first?.event.executionAttempted == false)
    }

    @Test func malformedFrameDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.failure(.malformed))
        #expect(harness.effect.runs == 0)
        #expect(decision.response == .rejected(.malformed))
        let extra = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(harness.capability.rawValue)","session":"\(harness.runtime.id.rawValue.uuidString)","command":"touch marker","cwd":"/tmp"}
            """.utf8
        )
        var framed = Data()
        var length = UInt32(extra.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(extra)
        let decoded = harness.session.accept(framed)
        #expect(harness.effect.runs == 0)
        #expect(decoded.first?.response == .rejected(.malformed))
    }

    @Test func evidenceFileRecordsTheSessionAndOutcome() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let harness = try AdmissionHarness(evidenceFile: log)
        defer { harness.cleanup() }
        _ = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains(harness.runtime.id.rawValue.uuidString))
        #expect(text.contains("\"authorization\":\"allowed\""))
        #expect(text.contains("\"executionAttempted\":true"))
        #expect(text.contains("\"result\":\"exit:0\""))
    }

    @Test func admissionAuditAppendSurfacesFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = RuntimeAdmissionEvent(
            session: UUID().uuidString,
            requestID: nil,
            fingerprint: nil,
            authorization: .allowed,
            executionAttempted: true,
            result: "exit:0"
        )
        let diagnostics = AdmissionDiagnosticCollector()
        let url = directory.appendingPathComponent("runtime-admission.jsonl")
        #expect(appendAdmissionEvent(event, to: url, diagnose: diagnostics.record))
        #expect(diagnostics.all.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"authorization\":\"allowed\""))

        // Fault injection: the log parent is a regular file. Appending must
        // report failure visibly (and return false) instead of dropping the
        // audit row through `try?`. The admission decision itself is already
        // made; only the audit persistence fails.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        let badURL = blocker.appendingPathComponent("runtime-admission.jsonl")
        #expect(appendAdmissionEvent(event, to: badURL, diagnose: diagnostics.record) == false)
        #expect(diagnostics.all.isEmpty == false)
    }

    @Test func seatbeltProfileGainsNoNetworkAllow() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-profile"))
        let plan = try compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        ).get()
        let profile = try compileSeatbeltProfile(plan).get()
        #expect(profile.source.contains("(deny default)"))
        #expect(profile.source.contains("allow network") == false)
        #expect(profile.source.contains("system-socket") == false)
    }

    #if os(Linux)
    @Test func containedLaunchStaysUnsupported() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/touch", arguments: ["must-not-run"]))
        switch await IsolationBackends.applyOffPool(tree.contained, command: command) {
        case .failure(.containedGuaranteesUnsupported):
            break
        case .failure(let error):
            Issue.record("Linux contained launch must be refused, got \(error)")
        case .success(let run):
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
    #endif

    #if os(macOS)
    @Test func containedClientUsesTheGrantedPipes() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let client = try compileAdmissionClient(in: tree.workspaceURL)
        let reply = tree.workspaceURL.appendingPathComponent("admission-reply")
        let marker = tree.workspaceURL.appendingPathComponent("admitted-marker")
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: containedPipeNormalize,
            executor: .containedCommand,
            http: .effect { action, _, _ in
                .success(
                    HTTPExecutionReceipt(
                        status: 204,
                        destination: action.destination.auditedResource,
                        headers: [],
                        body: Data()
                    )
                )
            },
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: evidence
        )
        let command = try #require(
            IsolatedCommand(executable: client.path, arguments: [reply.path])
        )
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .file(log),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        let text = try String(contentsOf: reply, encoding: .utf8)
        #expect(text.contains("\"status\":\"executed\""))
        #expect(text.contains("\"reason\":\"replay\""))
        #expect(text.contains("\"reason\":\"impersonation\""))
        #expect(text.contains("\"reason\":\"invalidCapability\""))
        #expect(text.contains("\"status\":\"denied\""))
        #expect(text.contains("\"status\":\"pending\""))
        #expect(text.contains("\"status\":\"http\""))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // One allowed shell and one allowed GET. A second shell still fails.
        let attempted = evidence.snapshot().filter(\.executionAttempted)
        let shells = attempted.filter { $0.httpMethod == nil }
        let transfers = attempted.filter { $0.httpMethod != nil }
        #expect(shells.count == 1)
        #expect(shells.first?.authorization == .allowed)
        #expect(shells.first?.result == "exit:0")
        #expect(transfers.count == 1)
        #expect(transfers.first?.authorization == .allowed)
        let rejected = evidence.snapshot().filter { $0.eventExecutionWasRejected }
        #expect(rejected.allSatisfy { $0.executionAttempted == false })
    }

    @Test func ptyRuntimeStillAdmitsShellCommands() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let client = try compileAdmissionClient(in: tree.workspaceURL)
        let reply = tree.workspaceURL.appendingPathComponent("pty-admission-reply")
        let marker = tree.workspaceURL.appendingPathComponent("admitted-marker")
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: containedPipeNormalize,
            executor: .containedCommand,
            http: .effect { action, _, _ in
                .success(
                    HTTPExecutionReceipt(
                        status: 204,
                        destination: action.destination.auditedResource,
                        headers: [],
                        body: Data()
                    )
                )
            },
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: evidence
        )
        let command = try #require(
            IsolatedCommand(executable: client.path, arguments: [reply.path])
        )
        let log = tree.rootURL.appendingPathComponent("pty-sessions.jsonl")
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .pseudoTerminal(rows: 24, columns: 80),
            host: .opencode,
            sessionStore: .file(log),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        let text = try String(contentsOf: reply, encoding: .utf8)
        #expect(text.contains("\"status\":\"executed\""))
        #expect(text.contains("\"reason\":\"replay\""))
        #expect(text.contains("\"reason\":\"impersonation\""))
        #expect(text.contains("\"reason\":\"invalidCapability\""))
        #expect(text.contains("\"status\":\"denied\""))
        #expect(text.contains("\"status\":\"pending\""))
        #expect(text.contains("\"status\":\"http\""))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: "/tmp/rv-pty-deny-marker") == false)
    }

    @Test func admittedCommandStopsWhenContainedProcessExits() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let sleeper = try compileC(
            admissionSleeperSource,
            named: "admission-sleeper",
            in: tree.workspaceURL
        )
        let client = try compileC(
            admissionLifetimeClientSource,
            named: "admission-lifetime",
            in: tree.workspaceURL
        )
        let escaped = tree.workspaceURL.appendingPathComponent("escaped")
        let started = tree.workspaceURL.appendingPathComponent("command-started")
        let command = try #require(
            IsolatedCommand(executable: client.path, arguments: [sleeper.path])
        )
        let configuration = RuntimeAdmissionConfiguration(
            normalize: allowAdmittedCommand,
            executor: .containedCommand,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .file(tree.rootURL.appendingPathComponent("sessions.jsonl")),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: started.path))
        #expect(FileManager.default.fileExists(atPath: escaped.path) == false)
    }
    #endif
}

/// Phase 5 credential broker: supervisor-side grants injected at approved
/// endpoints over the capability-bound admission pipes. Binding and replay
/// protection are the gate's, unchanged; values never reach the cage, the
/// pipes, or the logs. Presence assertions use names only.
@Suite("RuntimeCredentialBroker")
struct RuntimeCredentialBrokerTests {
    @Test func brokerDeliversForApprovedEndpointOnly() throws {
        let transport = BrokerHTTPTransport()
        let delivery = BrokerDeliveryCapture()
        let harness = try AdmissionHarness(
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }

        let granted = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        guard case .http(let receipt) = granted.response else {
            Issue.record("approved endpoint must execute, got \(granted.response)")
            return
        }
        #expect(receipt.status == 200)
        #expect(transport.runs == 1)
        #expect(delivery.all.count == 1)
        #expect(delivery.all.first?.credentialName == "API_KEY")
        #expect(delivery.all.first?.host == "approved.example.com")
        #expect(delivery.all.first?.value == brokerSecretValue)
        let grantedEvents = harness.evidence.snapshot().filter {
            $0.result.hasPrefix("credential")
        }
        #expect(grantedEvents.count == 1)
        #expect(grantedEvents.first?.result == "credentialGranted:API_KEY")
        #expect(grantedEvents.first?.authorization == .allowed)
        #expect(grantedEvents.first?.executionAttempted == false)

        // Authorized request, unapproved endpoint: executes without injection.
        let other = harness.session.submitLegacy(
            .success(harness.httpFrame("https://other.example.net/x", id: UUID()))
        )
        guard case .http = other.response else {
            Issue.record("unapproved endpoint request must still execute, got \(other.response)")
            return
        }
        #expect(transport.runs == 2)
        #expect(delivery.all.count == 1)
        #expect(
            harness.evidence.snapshot().contains {
                $0.result == "credentialWithheld:endpointNotApproved" && $0.authorization == .denied
            }
        )

        // Values never in the evidence structs.
        let encoded = try JSONEncoder().encode(harness.evidence.snapshot())
        #expect(String(decoding: encoded, as: UTF8.self).contains(brokerSecretValue) == false)
    }

    @Test func brokeredRequestsHonorBindingAndReplay() throws {
        let transport = BrokerHTTPTransport()
        let delivery = BrokerDeliveryCapture()
        let harness = try AdmissionHarness(
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }
        let url = "https://approved.example.com/v1/models"

        let first = harness.session.submitLegacy(.success(harness.httpFrame(url, id: UUID())))
        guard case .http = first.response else {
            Issue.record("first brokered request must execute, got \(first.response)")
            return
        }
        #expect(delivery.all.count == 1)

        // Same request id: replay, no second delivery.
        let sameID = harness.session.submitLegacy(
            .success(harness.httpFrame(url, id: first.event.requestID.flatMap { UUID(uuidString: $0) } ?? UUID()))
        )
        #expect(sameID.response == .rejected(.replay))
        #expect(delivery.all.count == 1)

        // Same URL, fresh id: fingerprint replay, no second delivery.
        let sameURL = harness.session.submitLegacy(.success(harness.httpFrame(url, id: UUID())))
        #expect(sameURL.response == .rejected(.replay))
        #expect(delivery.all.count == 1)

        // Forged capability and session claim: rejected before the broker.
        let badCap = harness.session.submitLegacy(
            .success(harness.httpFrame(
                "https://other.example.net/y", capability: RuntimeCapability(), id: UUID()))
        )
        #expect(badCap.response == .rejected(.invalidCapability))
        let impersonated = harness.session.submitLegacy(
            .success(harness.httpFrame("https://other.example.net/z", claim: UUID(), id: UUID()))
        )
        #expect(impersonated.response == .rejected(.impersonation))
        #expect(delivery.all.count == 1)
        #expect(transport.runs == 1)
        #expect(
            harness.evidence.snapshot().filter { $0.result.hasPrefix("credential") }.count == 1
        )
    }

    @Test func unauthorizedActionsNeverConsultBroker() throws {
        let transport = BrokerHTTPTransport()
        let delivery = BrokerDeliveryCapture()
        let harness = try AdmissionHarness(
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }

        // Allowed shell: executes, no broker event (the broker serves HTTP).
        let shell = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        #expect(shell.response == .executed(exitStatus: 0))

        // Denied shell and failed evaluations: no consultation.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-broker-outside-\(UUID().uuidString)")
        let denied = harness.session.submitLegacy(
            .success(harness.frame("touch \(outside.path)", id: UUID()))
        )
        guard case .denied = denied.response else {
            Issue.record("outside touch must be denied, got \(denied.response)")
            return
        }
        let unsupported = harness.session.submitLegacy(
            .success(harness.httpFrame("http://approved.example.com/x", id: UUID()))
        )
        #expect(unsupported.response == .evaluationFailed)
        let blocked = harness.session.submitLegacy(
            .success(harness.httpFrame("https://localhost/x", id: UUID()))
        )
        if case .http = blocked.response {
            Issue.record("blocked host must not execute, got \(blocked.response)")
        }

        #expect(delivery.all.isEmpty)
        #expect(transport.runs == 0)
        #expect(
            harness.evidence.snapshot().allSatisfy { $0.result.hasPrefix("credential") == false }
        )
    }

    @Test func pipeBytesCarryNoSecret() throws {
        let transport = BrokerHTTPTransport()
        let delivery = BrokerDeliveryCapture()
        let harness = try AdmissionHarness(
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }

        // Real pipe on the response side: the session writes actual bytes.
        var pipes = RuntimeAdmissionPipes()
        let pipesOpened = pipes.open()
        try #require(pipesOpened)
        defer { pipes.closeRemaining() }
        let evidence = RuntimeAdmissionEvidence()
        let workspace = try #require(WorkingDirectory(validating: harness.root.path))
        let session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: harness.runtime, capability: harness.capability),
            configuration: RuntimeAdmissionConfiguration(
                normalize: brokerCombinedNormalize,
                executor: .effect(harness.effect.run),
                http: .effect(transport.run),
                approval: { _, _ in nil },
                policy: { _ in .empty },
                evidence: evidence,
                credentialBroker: brokerFixture(),
                credentialDelivery: delivery.deliver
            ),
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: workspace),
                profileSource: "(deny file-link)",
                profileIsContainedCompilerOutput: true,
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: pipes.responseWrite
        )
        pipes.responseWrite = -1

        // Request bytes exactly as the codec frames them for the pipe.
        let requestBytes = try RuntimeAdmissionCodec.encodeRequest(
            harness.httpFrame("https://approved.example.com/v1/models", id: UUID())
        ).get()
        #expect(String(decoding: requestBytes, as: UTF8.self).contains(brokerSecretValue) == false)
        let grantBytes = try RuntimeAdmissionCodec.encodeGrant(
            capability: harness.capability, session: harness.runtime.id.rawValue
        ).get()
        #expect(String(decoding: grantBytes, as: UTF8.self).contains(brokerSecretValue) == false)

        let decisions = session.accept(requestBytes)
        #expect(decisions.count == 1)
        guard case .http = decisions.first?.response else {
            Issue.record("piped brokered request must execute, got \(String(describing: decisions.first?.response))")
            session.finish()
            return
        }
        session.finish()
        let responseBytes = admissionReadAvailable(pipes.responseRead)
        let responseText = String(decoding: responseBytes, as: UTF8.self)
        #expect(responseText.contains("\"status\":\"http\""))
        #expect(responseText.contains(brokerSecretValue) == false)

        // Host-side only: the value resolved, but never crossed.
        #expect(delivery.all.count == 1)
        #expect(delivery.all.first?.value == brokerSecretValue)
    }

    @Test func evidenceLogCarriesNamesNotValues() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-broker-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let transport = BrokerHTTPTransport()
        let delivery = BrokerDeliveryCapture()
        let harness = try AdmissionHarness(
            evidenceFile: log,
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }
        _ = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        _ = harness.session.submitLegacy(
            .success(harness.httpFrame("https://other.example.net/x", id: UUID()))
        )
        #expect(delivery.all.count == 1)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("credentialGranted:API_KEY"))
        #expect(text.contains("credentialWithheld:endpointNotApproved"))
        #expect(text.contains("API_KEY"))
        #expect(text.contains(brokerSecretValue) == false)
    }

    @Test func unwiredBrokerDropsGrantFailClosed() throws {
        let transport = BrokerHTTPTransport()
        let harness = try AdmissionHarness(
            normalize: brokerCombinedNormalize,
            http: .effect(transport.run),
            broker: brokerFixture(),
            delivery: nil
        )
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        // The broker never breaks the request: it executes unauthenticated.
        guard case .http = decision.response else {
            Issue.record("unwired broker must not break the request, got \(decision.response)")
            return
        }
        let brokerEvents = harness.evidence.snapshot().filter {
            $0.result.hasPrefix("credential")
        }
        #expect(brokerEvents.count == 1)
        #expect(brokerEvents.first?.result == "credentialUnwired:API_KEY")
        #expect(brokerEvents.first?.authorization == .executorFailed)
        #expect(brokerEvents.first?.executionAttempted == false)
    }

    @Test func resolveRequiresGrantAndHostApproval() {
        let broker = ContainedCredentialBroker(
            credentials: [
                "API_KEY": ContainedCredentialBroker.Credential(
                    value: brokerSecretValue, kind: .secret,
                    approvedHosts: ["approved.example.com"])
            ],
            grants: [
                "approved.example.com": "API_KEY",
                "rogue.example": "API_KEY",
                "ghost.example": "MISSING",
            ]
        )
        #expect(
            broker.resolve(host: "approved.example.com")
                == .granted(BrokeredCredentialInjection(
                    credentialName: "API_KEY", host: "approved.example.com",
                    value: brokerSecretValue))
        )
        #expect(
            broker.resolve(host: "APPROVED.EXAMPLE.COM")
                == .granted(BrokeredCredentialInjection(
                    credentialName: "API_KEY", host: "approved.example.com",
                    value: brokerSecretValue))
        )
        // Routing without host approval withholds.
        #expect(broker.resolve(host: "rogue.example") == .withheld(.endpointNotApproved))
        // Routing to a missing credential withholds.
        #expect(broker.resolve(host: "ghost.example") == .withheld(.credentialMissing))
        // Host approval without routing withholds.
        let unrouted = ContainedCredentialBroker(
            credentials: [
                "API_KEY": ContainedCredentialBroker.Credential(
                    value: brokerSecretValue, kind: .secret,
                    approvedHosts: ["lonely.example"])
            ],
            grants: [:]
        )
        #expect(unrouted.resolve(host: "lonely.example") == .withheld(.endpointNotApproved))
        // Unknown host withholds.
        #expect(broker.resolve(host: "unknown.example") == .withheld(.endpointNotApproved))
    }

    @Test func selectorsCrossAsPreparedEntriesButNeverInject() {
        let broker = ContainedCredentialBroker(
            credentials: [
                "AWS_CREDENTIAL_PROFILE": ContainedCredentialBroker.Credential(
                    value: "prod-profile", kind: .selector,
                    approvedHosts: ["approved.example.com"])
            ],
            grants: ["approved.example.com": "AWS_CREDENTIAL_PROFILE"]
        )
        #expect(broker.resolve(host: "approved.example.com") == .withheld(.credentialNotSecret))
        #expect(broker.preparedEntries() == [
            BrokerPreparedEntry(name: "AWS_CREDENTIAL_PROFILE", value: "prod-profile")
        ])
    }

    @Test func credentialClassDeniesByDefault() {
        for name in [
            "GH_TOKEN", "MY_API_KEY", "db_password", "AWS_SECRET_ACCESS_KEY",
            "BEARER_TOKEN", "SESSION_AUTH", "PRIVATE_KEY_FILE", "MY_AUTHORIZATION",
            "SSH_AUTH_SOCK", "KUBECONFIG", "AWS_SHARED_CREDENTIALS_FILE",
            "GPG_AGENT_INFO", "GIT_ASKPASS", "OCTO_COOKIE", "TOTP_SEED",
            "LICENSE_KEY", "NETRC_FILE", "MY_CREDENTIALS",
        ] {
            #expect(ContainedEnvironmentPolicy.isCredentialClass(name), "credential class: \(name)")
            #expect(
                ContainedEnvironmentPolicy.isBlockedVariableName(name),
                "class implies blocked: \(name)"
            )
        }
        for name in [
            "RUSTUP_TOOLCHAIN", "PYENV_VERSION", "TOKENIZERS_PARALLELISM",
            "KEYNOTE", "MY_TOKENIZER", "ANTHROPIC_BASE_URL", "PATH", "LANG",
            "NVM_DIR", "JAVA_HOME",
        ] {
            #expect(
                ContainedEnvironmentPolicy.isCredentialClass(name) == false,
                "not credential class: \(name)"
            )
        }
        // Deny-by-default in the projection, including adversarial host values.
        let projected = ContainedEnvironmentPolicy.project(host: [
            "GH_TOKEN": "test-fake-secret",
            "ANTHROPIC_API_KEY": "test-fake-secret",
            "RUSTUP_TOOLCHAIN": "stable",
            "TOKENIZERS_PARALLELISM": "false",
        ])
        #expect(projected.contains { $0.0 == "GH_TOKEN" } == false)
        #expect(projected.contains { $0.0 == "ANTHROPIC_API_KEY" } == false)
        #expect(projected.contains { $0 == ("RUSTUP_TOOLCHAIN", "stable") })
        #expect(projected.contains { $0 == ("TOKENIZERS_PARALLELISM", "false") })
        #expect(projected.allSatisfy { $0.1.contains("test-fake-secret") == false })
    }

    @Test func toolchainNamesPassProjection() {
        let toolchain = [
            "RUSTUP_TOOLCHAIN": "stable-aarch64-apple-darwin",
            "RUSTUP_HOME": "/Users/test/.rustup",
            "CARGO_HOME": "/Users/test/.cargo",
            "PYENV_VERSION": "3.12.1",
            "PYENV_ROOT": "/Users/test/.pyenv",
            "NODE_VERSION": "20.11.0",
            "NVM_DIR": "/Users/test/.nvm",
            "GOENV_VERSION": "1.22.0",
            "JAVA_HOME": "/Library/Java/Home",
            "SDKMAN_DIR": "/Users/test/.sdkman",
            "CONDA_PREFIX": "/Users/test/miniconda3",
            "VOLTA_HOME": "/Users/test/.volta",
            "DENO_DIR": "/Users/test/.deno",
            "BUN_INSTALL": "/Users/test/.bun",
            "MISE_DATA_DIR": "/Users/test/.mise",
            "ASDF_DIR": "/Users/test/.asdf",
            "SWIFTLY_HOME": "/Users/test/.swiftly",
            "PYTHON_VERSION": "3.12",
            "RUBY_VERSION": "3.3",
            "TOKENIZERS_PARALLELISM": "false",
            "HF_HUB_OFFLINE": "1",
        ]
        let projected = ContainedEnvironmentPolicy.project(host: toolchain)
        for name in toolchain.keys {
            #expect(ContainedEnvironmentPolicy.isCredentialClass(name) == false)
            #expect(
                ContainedEnvironmentPolicy.isBlockedVariableName(name) == false,
                "toolchain survives denylist: \(name)"
            )
            #expect(projected.contains { $0.0 == name }, "toolchain survives: \(name)")
        }
    }

    @Test func brokerPreparedEntriesApplyAfterStrip() {
        let entries = brokerFixture().preparedEntries()
        // Secret values are never minted; placeholders carry name+revision only.
        #expect(entries.contains { $0.name == "API_KEY" && $0.value == "rv-brokered:API_KEY@7" })
        #expect(entries.contains {
            $0.name == "AWS_CREDENTIAL_PROFILE" && $0.value == "prod-profile"
        })
        #expect(entries.allSatisfy { $0.value.contains(brokerSecretValue) == false })
        // Secrets without the placeholder opt-in leave no trace.
        let bare = ContainedCredentialBroker(
            credentials: [
                "GH_TOKEN": ContainedCredentialBroker.Credential(
                    value: "test-fake-bare", kind: .secret, approvedHosts: [])
            ],
            grants: [:]
        )
        #expect(bare.preparedEntries().isEmpty)
        // The strip wins over hostile host values; broker entries apply after.
        let projected = ContainedEnvironmentPolicy.project(
            host: ["API_KEY": "host-injected-fake", "RUSTUP_TOOLCHAIN": "stable"],
            brokerPrepared: entries
        )
        #expect(projected.contains { $0 == ("API_KEY", "rv-brokered:API_KEY@7") })
        #expect(projected.contains { $0 == ("AWS_CREDENTIAL_PROFILE", "prod-profile") })
        #expect(projected.contains { $0.0 == "RUSTUP_TOOLCHAIN" })
        #expect(projected.allSatisfy { $0.1.contains("host-injected-fake") == false })
        // Adversarial prepared entries are dropped fail-closed.
        let hostile = ContainedEnvironmentPolicy.project(
            host: [:],
            brokerPrepared: [
                BrokerPreparedEntry(name: "RUSTUP_TOOLCHAIN", value: "x"),
                BrokerPreparedEntry(name: "9BAD", value: "x"),
                BrokerPreparedEntry(name: "GH_TOKEN", value: "a\nb"),
                BrokerPreparedEntry(name: "GH_TOKEN", value: "first"),
                BrokerPreparedEntry(name: "GH_TOKEN", value: "second"),
            ]
        )
        #expect(hostile.count == 1)
        #expect(hostile.first?.0 == "GH_TOKEN" && hostile.first?.1 == "first")
    }
}

private final class AdmissionDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private final class AdmissionEffect: Sendable {
    let url: URL
    private let runsBox = Mutex(0)

    var runs: Int { runsBox.withLock { $0 } }

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-effect-\(UUID().uuidString)")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func run(_: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        runsBox.withLock { $0 += 1 }
        guard FileManager.default.createFile(atPath: url.path, contents: Data("once".utf8)) else {
            return .failure(.spawnFailed)
        }
        return .success(0)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct AdmissionHarness {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let requestID: UUID
    let effect: AdmissionEffect
    let evidence: RuntimeAdmissionEvidence
    let session: RuntimeAdmissionSession

    init(
        approval: @escaping @Sendable (RuntimeActionRequestID, PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>? = { _, _ in nil },
        evidenceFile: URL? = nil,
        normalize: @escaping @Sendable (RuntimeAdmissionSubject, RuntimeRequestedAction) -> Result<
            ProposedAction, RuntimeAdmissionEvaluationError
        > = isolationAdmissionNormalize,
        http: RuntimeHTTPExecutor = .refuse,
        broker: ContainedCredentialBroker? = nil,
        delivery: (@Sendable (BrokeredCredentialInjection) -> Void)? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let effect = AdmissionEffect()
        let evidence = RuntimeAdmissionEvidence(appendingTo: evidenceFile)
        let configuration = RuntimeAdmissionConfiguration(
            normalize: normalize,
            executor: .effect(effect.run),
            http: http,
            approval: approval,
            policy: { _ in .empty },
            evidence: evidence,
            credentialBroker: broker,
            credentialDelivery: delivery
        )
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.requestID = UUID()
        self.effect = effect
        self.evidence = evidence
        session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                profileIsContainedCompilerOutput: true,
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
    }

    func frame(
        _ command: String,
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        id: UUID? = nil
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: (id ?? requestID).uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? runtime.id.rawValue).uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }

    func httpFrame(
        _ url: String,
        method: String = "GET",
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        id: UUID? = nil
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: (id ?? requestID).uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? runtime.id.rawValue).uuidString)!,
            action: .http(method: method, url: url)
        )
    }

    func cleanup() {
        effect.cleanup()
        try? FileManager.default.removeItem(at: root)
    }
}

private extension RuntimeAdmissionEvent {
    var eventExecutionWasRejected: Bool {
        authorization == .rejected
    }
}

/// Classifies the fixture commands without linking RVEngine.
/// Inside `touch` is allowed, an absolute `touch` is an outside write, and
/// shell substitutions produce no proposal. Anything else stays pending.
private func isolationAdmissionNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .shell(let command) = action else {
        return .failure(.failed)
    }
    let raw = command.rawValue
    if raw.contains("$") || raw.contains("`") || raw.contains("\"") || raw.contains("'") {
        return .failure(.failed)
    }
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(raw)"
    )
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    if tokens.count == 2, tokens[0] == "touch" {
        let inside = tokens[1].hasPrefix("/") == false
        let scope: FilesystemScope = inside ? .insideRepository : .outsideRepository
        let kinds: [ActionEffectKind] = inside
            ? [.filesystemCreate]
            : [.filesystemOverwrite, .outsideRepositoryMutation]
        return .success(
            .shell(
                ShellAction.effectOnly(
                    EffectShell(
                        fingerprint: fingerprint,
                        effects: ActionEffects(kinds: kinds),
                        resources: ActionResources(
                            path: tokens[1],
                            filesystemScope: scope,
                            resourceKind: .unknown
                        ),
                        scope: ActionScope(workingDirectory: subject.policyWorkspace),
                        supportingCommand: command
                    )
                )
            )
        )
    }
    return .success(
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: fingerprint,
                    effects: ActionEffects(),
                    resources: ActionResources(),
                    scope: ActionScope(workingDirectory: subject.policyWorkspace),
                    supportingCommand: command
                )
            )
        )
    )
}

/// Distinctive broker secret. Leak-surface assertions check for its absence;
/// presence assertions use credential and host names only, never this value.
private let brokerSecretValue = "test-broker-secret-AAA111"

private func brokerFixture(revision: UInt64 = 7) -> ContainedCredentialBroker {
    ContainedCredentialBroker(
        credentials: [
            "API_KEY": ContainedCredentialBroker.Credential(
                value: brokerSecretValue,
                kind: .secret,
                approvedHosts: ["approved.example.com"],
                placeholder: true
            ),
            "AWS_CREDENTIAL_PROFILE": ContainedCredentialBroker.Credential(
                value: "prod-profile",
                kind: .selector,
                approvedHosts: []
            ),
        ],
        grants: ["approved.example.com": "API_KEY"],
        revision: revision
    )
}

private final class BrokerHTTPTransport: Sendable {
    private let runsBox = Mutex(0)

    var runs: Int { runsBox.withLock { $0 } }

    func run(
        _ action: HTTPAction,
        _: HTTPCancellation,
        _: @escaping @Sendable () -> Bool
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        runsBox.withLock { $0 += 1 }
        return .success(
            HTTPExecutionReceipt(
                status: 200,
                destination: action.destination.auditedResource,
                headers: [],
                body: Data("ok".utf8)
            )
        )
    }
}

private final class BrokerDeliveryCapture: Sendable {
    private let box = Mutex<[BrokeredCredentialInjection]>([])

    var all: [BrokeredCredentialInjection] { box.withLock { $0 } }

    func deliver(_ injection: BrokeredCredentialInjection) {
        box.withLock { $0.append(injection) }
    }
}

/// Shell rules plus stub-resolved HTTPS GETs: two public hosts so an
/// authorized request can still hit an unapproved endpoint.
private func brokerCombinedNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .http(let method, let url) = action else {
        return isolationAdmissionNormalize(subject: subject, action: action)
    }
    return normalizeRuntimeHTTP(subject: subject, method: method, url: url) { host in
        switch host {
        case "approved.example.com", "other.example.net":
            return .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!])
        default:
            return .failure(.failed)
        }
    }
}

/// Shell rules plus one public HTTPS GET, so a PTY payload can use fds 4 and 5
/// for both without touching its terminal.
private func containedPipeNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    if case .http(let method, let url) = action {
        return normalizeRuntimeHTTP(
            subject: subject,
            method: method,
            url: url
        ) { host in
            guard host == "example.com" else { return .failure(.failed) }
            return .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!])
        }
    }
    return isolationAdmissionNormalize(subject: subject, action: action)
}

#if os(macOS)
/// Test double that authorizes the requested argv. Production normalization
/// stays in RVEngine; this only lets a lifetime probe reach the spawner.
private func allowAdmittedCommand(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .shell(let command) = action else {
        return .failure(.failed)
    }
    return .success(
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "runtime:lifetime:\(command.rawValue)"),
                    effects: ActionEffects(kinds: [.filesystemCreate]),
                    resources: ActionResources(
                        path: "command-started",
                        filesystemScope: .insideRepository,
                        resourceKind: .unknown
                    ),
                    scope: ActionScope(workingDirectory: subject.policyWorkspace),
                    supportingCommand: command
                )
            )
        )
    )
}
#endif

#if os(macOS)
private func compileAdmissionClient(in workspace: URL) throws -> URL {
    try compileC(admissionClientSource, named: "admission-client", in: workspace)
}

private func compileC(_ source: String, named name: String, in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("\(name).c")
    let binary = workspace.appendingPathComponent(name)
    try Data(source.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private let admissionClientSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, void *buffer, size_t count) {
    unsigned char *bytes = buffer;
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    size_t sent = 0;
    while (sent < count) {
        ssize_t n = write(fd, bytes + sent, count - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_frame(int fd, char *body, size_t cap) {
    unsigned char header[4];
    if (read_full(fd, header, 4) != 0) return -1;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | (size_t)header[3];
    if (length == 0 || length + 1 > cap) return -1;
    if (read_full(fd, body, length) != 0) return -1;
    body[length] = 0;
    return (int)length;
}

static int write_frame(int fd, const char *body) {
    size_t length = strlen(body);
    unsigned char header[4] = {
        (unsigned char)((length >> 24) & 0xff),
        (unsigned char)((length >> 16) & 0xff),
        (unsigned char)((length >> 8) & 0xff),
        (unsigned char)(length & 0xff),
    };
    if (write_full(fd, header, 4) != 0) return -1;
    return write_full(fd, body, length);
}

static int extract(const char *json, const char *key, char *out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *found = strstr(json, pattern);
    if (found == NULL) return -1;
    found += strlen(pattern);
    size_t used = 0;
    while (found[used] != 0 && found[used] != '"' && used + 1 < cap) {
        out[used] = found[used];
        used++;
    }
    if (found[used] != '"') return -1;
    out[used] = 0;
    return 0;
}

static int exchange(int request, int response, const char *body, FILE *reply) {
    if (write_frame(request, body) != 0) return -1;
    char incoming[8192];
    if (read_frame(response, incoming, sizeof incoming) < 0) return -1;
    if (fprintf(reply, "%s\n", incoming) < 0) return -1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char grant[8192];
    if (read_frame(5, grant, sizeof grant) < 0) return 3;
    char capability[80];
    char session[80];
    if (extract(grant, "capability", capability, sizeof capability) != 0) return 4;
    if (extract(grant, "session", session, sizeof session) != 0) return 4;
    FILE *reply = fopen(argv[1], "w");
    if (reply == NULL) return 5;
    char body[1024];
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 6;
    if (exchange(4, 5, body, reply) != 0) return 7;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\",\"capability\":\"%s\",\"session\":\"00000000-0000-0000-0000-000000000001\",\"command\":\"touch admitted-marker\"}",
        capability);
    if (exchange(4, 5, body, reply) != 0) return 8;
    char fake[65];
    memset(fake, 'a', 64);
    fake[64] = 0;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"cccccccc-cccc-cccc-cccc-cccccccccccc\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        fake, session);
    if (exchange(4, 5, body, reply) != 0) return 9;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"dddddddd-dddd-dddd-dddd-dddddddddddd\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch /tmp/rv-pty-deny-marker\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 10;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"echo hello\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 11;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"ffffffff-ffff-ffff-ffff-ffffffffffff\",\"capability\":\"%s\",\"session\":\"%s\",\"method\":\"GET\",\"url\":\"https://example.com/a\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 12;
    fclose(reply);
    return 0;
}
"""#

private let admissionSleeperSource = #"""
#include <fcntl.h>
#include <unistd.h>

int main(void) {
    int started = open("command-started", O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (started < 0) return 2;
    close(started);
    sleep(20);
    return 0;
}
"""#

private let admissionLifetimeClientSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, void *buffer, size_t count) {
    unsigned char *bytes = buffer;
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    size_t sent = 0;
    while (sent < count) {
        ssize_t n = write(fd, bytes + sent, count - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_frame(int fd, char *body, size_t cap) {
    unsigned char header[4];
    if (read_full(fd, header, 4) != 0) return -1;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | (size_t)header[3];
    if (length == 0 || length + 1 > cap) return -1;
    if (read_full(fd, body, length) != 0) return -1;
    body[length] = 0;
    return (int)length;
}

static int write_frame(int fd, const char *body) {
    size_t length = strlen(body);
    unsigned char header[4] = {
        (unsigned char)((length >> 24) & 0xff),
        (unsigned char)((length >> 16) & 0xff),
        (unsigned char)((length >> 8) & 0xff),
        (unsigned char)(length & 0xff),
    };
    if (write_full(fd, header, 4) != 0) return -1;
    return write_full(fd, body, length);
}

static int extract(const char *json, const char *key, char *out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *found = strstr(json, pattern);
    if (found == NULL) return -1;
    found += strlen(pattern);
    size_t used = 0;
    while (found[used] != 0 && found[used] != '"' && used + 1 < cap) {
        out[used] = found[used];
        used++;
    }
    if (found[used] != '"') return -1;
    out[used] = 0;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    pid_t child = fork();
    if (child < 0) return 3;
    if (child == 0) {
        for (int attempt = 0; attempt < 400; attempt++) {
            if (access("command-started", F_OK) == 0) break;
            usleep(50000);
        }
        sleep(8);
        int escaped = open("escaped", O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (escaped >= 0) close(escaped);
        _exit(0);
    }
    char grant[8192];
    if (read_frame(5, grant, sizeof grant) < 0) return 4;
    char capability[80];
    char session[80];
    if (extract(grant, "capability", capability, sizeof capability) != 0) return 5;
    if (extract(grant, "session", session, sizeof session) != 0) return 5;
    char body[2048];
    int wrote = snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"dddddddd-dddd-dddd-dddd-dddddddddddd\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"%s\"}",
        capability, session, argv[1]);
    if (wrote < 0 || (size_t)wrote >= sizeof body) return 6;
    if (write_frame(4, body) != 0) return 7;
    for (int attempt = 0; attempt < 200; attempt++) {
        if (access("command-started", F_OK) == 0) _exit(0);
        usleep(50000);
    }
    return 8;
}
"""#
#endif
