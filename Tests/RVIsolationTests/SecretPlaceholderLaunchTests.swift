#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

private let placeholderSecrets = """
    {"version":1,"secrets":[
      {"name":"OPENAI_API_KEY","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                              "placeholderPrefix":"sk-"}}},
      {"name":"APPROVED","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"APPROVED_BASE_URL",
                              "approve":[{"methods":["DELETE"],"path":"/v1/**"}]}}},
      {"name":"CODEX_ONLY","agents":["codex"],
       "source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"CODEX_BASE_URL"}}},
      {"name":"HOST_SOURCED","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"HOST_BASE_URL"}}},
      {"name":"GH_TOKEN","source":{"keychain":{"service":"rv.secrets","account":"GH_TOKEN"}},
       "delivery":{"environment":{}}}
    ]}
    """

/// Keychain items by account; anything else as `fakeResolver` answers it.
private let placeholderResolver = SecretResolver { source in
    switch source {
    case .keychain(_, "OPENAI_API_KEY"): return .success(SecretValue("sk-live-REAL-0123456789")!)
    case .keychain(_, "GH_TOKEN"): return .success(SecretValue("ghp_realtoken")!)
    default: return fakeResolver.resolve(source)
    }
}

private let realOpenAI = "sk-live-REAL-0123456789"

/// Whether the real suspended spawn and kernel peer check work here.
private let hostBindsPlaceholders = SecretRunCapability.check(.runtime) == nil

private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-placeholder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func definitions() throws -> SecretsConfiguration {
    try SecretsConfiguration.decode(Data(placeholderSecrets.utf8)).get()
}

/// Polls `condition` for up to `seconds`; never blocks in a wait call.
private func eventually(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        usleep(20_000)
    }
    return true
}

/// `path` with every symlink resolved (`/var` is `/private/var`), or `path`.
private func physical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func contents(_ directory: URL, _ name: String) -> String {
    let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Secret placeholders for a process rv starts")
struct SecretPlaceholderLaunchTests {
    @Test func aLeaseMustHoldEveryRequestedSecretAsOnePlaceholderWithoutApproveRules() throws {
        let configuration = try definitions()
        let openAI = try #require(configuration.secret(named: "OPENAI_API_KEY"))
        let approved = try #require(configuration.secret(named: "APPROVED"))
        #expect(SecretPlaceholderBroker.refusal(staged: [openAI], placeholders: 1, requested: ["OPENAI_API_KEY"]) == nil)
        #expect(SecretPlaceholderBroker.refusal(
            staged: [openAI], placeholders: 1, requested: ["OPENAI_API_KEY", "APPROVED"]) == .incomplete)
        #expect(SecretPlaceholderBroker.refusal(staged: [openAI], placeholders: 0, requested: ["OPENAI_API_KEY"]) == .incomplete)
        #expect(SecretPlaceholderBroker.refusal(staged: [], placeholders: 0, requested: []) == .incomplete)
        #expect(SecretPlaceholderBroker.refusal(staged: [approved], placeholders: 1, requested: ["APPROVED"])
            == .approvalRules("APPROVED"))
        #expect(SecretPlaceholderBroker.hasApprovalRules(approved))
        #expect(SecretPlaceholderBroker.hasApprovalRules(openAI) == false)
        let hostSourced = try #require(configuration.secret(named: "HOST_SOURCED"))
        #expect(SecretPlaceholderBroker.refusal(staged: [hostSourced], placeholders: 1, requested: ["HOST_SOURCED"])
            == .hostEnvironmentSource("HOST_SOURCED"))
    }

    /// A real value as is or trimmed; contained, from 8 bytes on, as is or
    /// base64 (standard or URL-safe, padded or not, at any byte offset),
    /// hex (either case) or percent-encoded. Shorter values: exact only.
    @Test func aLaunchHoldsARealValueWhenAnyVariableOrArgumentIsOrContainsOne() throws {
        let long = "sk-live-REAL-0123456789"
        let real = [try #require(SecretValue(long)), try #require(SecretValue("hunter22")), try #require(SecretValue("pin-42"))]
        func holds(_ environment: [String: String], _ arguments: [String] = []) -> Bool {
            SecretPlaceholderLease.holdsRealValue(environment: environment, arguments: arguments, realValues: real)
        }
        #expect(holds(["OPENAI_API_KEY": "sk-rvph_abc", "PATH": "/usr/bin:/bin"], ["--port", "3000"]) == false)
        #expect(holds(["ALIAS": long]))
        #expect(holds(["ALIAS": " \(long)\n"]))
        #expect(holds(["AUTH": "Bearer \(long)"]))
        #expect(holds([:], ["--token", long]))
        #expect(holds([:], ["--token=\(long)"]))

        // Contained from the 8-byte floor on.
        #expect(holds(["URL": "postgres://u:hunter22@db"]))
        #expect(holds([:], ["--password=hunter22"]))
        #expect(holds(["NEAR": "hunter2 hunter-22"]) == false)

        // Shorter than the floor: an exact copy only.
        #expect(holds(["SHORT": "pin-42"]))
        #expect(holds([:], ["pin-42"]))
        #expect(holds(["SHORT": "id pin-42 here"]) == false)

        // Encoded copies, at every byte offset inside the encoded text.
        for prefix in ["", "u", "us", "user:"] {
            for value in [long, "hunter22"] {
                let standard = Data((prefix + value).utf8).base64EncodedString()
                let bare = standard.replacingOccurrences(of: "=", with: "")
                let safe = bare.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                #expect(holds(["AUTH": "Basic \(standard)"]), "base64 of \(prefix.count) + value")
                #expect(holds(["AUTH": bare]), "unpadded base64 of \(prefix.count) + value")
                #expect(holds([:], ["--auth=\(safe)"]), "URL-safe base64 of \(prefix.count) + value")
            }
        }
        let hex = Data(long.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(holds(["HEX": "0x\(hex)"]))
        #expect(holds(["HEX": hex.uppercased()]))
        let percent = try #require(long.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(percent != long)
        #expect(holds(["URL": "https://example.com/?key=\(percent)"]))
        #expect(holds([:], ["--url=https://u:hunter%32%32@db"]))
        #expect(holds(["AUTH": "Basic " + Data("x".utf8).base64EncodedString()]) == false)

        #expect(SecretPlaceholderLease.holdsRealValue(environment: ["A": "x"], arguments: ["y"], realValues: []) == false)
    }

    @Test func secretsThatCannotBePlaceholdersStageNothing() throws {
        let fixture = try SecretsFixture(placeholderSecrets)
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: placeholderResolver, transport: RecordingUpstream().transport,
            peers: .alwaysMember)
        defer { broker.stop() }
        guard case .failure(.refused) = broker.lease(["GH_TOKEN"], server: "fixture") else {
            Issue.record("an environment-delivered secret was staged")
            return
        }
        guard case .failure(.refused) = broker.lease(["CODEX_ONLY"], server: "fixture") else {
            Issue.record("an agent-scoped secret was staged")
            return
        }
        #expect(broker.lease(["APPROVED"], server: "fixture").leaseFailure == .approvalRules("APPROVED"))
        #expect(broker.lease(["HOST_SOURCED"], server: "fixture").leaseFailure == .hostEnvironmentSource("HOST_SOURCED"))
        #expect(broker.lease([], server: "fixture").leaseFailure == .noSecretsListed)
        #expect(broker.broker.liveCount == 0)
    }

    @Test func aLeaseCarriesOnlyPlaceholdersAndNamesTheServerInItsRecords() throws {
        let fixture = try SecretsFixture(placeholderSecrets)
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: placeholderResolver, transport: RecordingUpstream().transport,
            peers: .alwaysMember)
        defer { broker.stop() }
        let lease = try broker.lease(["OPENAI_API_KEY"], server: "fixture").get()
        let environment = Dictionary(uniqueKeysWithValues: lease.environment.map { ($0.name, $0.value) })
        #expect(environment["OPENAI_API_KEY"]?.hasPrefix("sk-rvph_") == true)
        #expect(environment["OPENAI_BASE_URL"] == "http://127.0.0.1:\(lease.gatewayPort)/s/OPENAI_API_KEY")
        #expect(lease.environment.contains { $0.value.contains(realOpenAI) } == false)
        #expect(broker.broker.liveCount == 1)
        let staged = fixture.auditLines.filter { $0["reason"] as? String == "staged for launch" }
        #expect(staged.count == 1)
        #expect(staged.first?["runtime"] as? String == "mcp:fixture")
        lease.revoke()
        lease.revoke()
        #expect(broker.broker.liveCount == 0)
    }

    #if os(macOS)
    /// If the group cannot be read after the spawn, the stopped child is
    /// killed and reaped before it ran, and the lease is gone.
    @Test(.enabled(if: SecretRunProcess.isAvailable), .timeLimit(.minutes(1)))
    func aFailedBindLeavesNoChildAndNoLease() throws {
        let fixture = try SecretsFixture(placeholderSecrets)
        defer { fixture.tearDown() }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: placeholderResolver, transport: RecordingUpstream().transport,
            peers: .alwaysMember)
        defer { broker.stop() }
        let lease = try broker.lease(["OPENAI_API_KEY"], server: "fixture").get()
        let spawned = Mutex<pid_t>(0)
        let exits = Mutex(0)
        do throws(SecretPlaceholderLaunchError) {
            let group = try lease.launch(
                executable: "/bin/sh", arguments: ["-c", "touch \"$1/ran\"", "sh", directory.path],
                environment: ["PATH": "/usr/bin:/bin"], descriptors: [:], workingDirectory: nil,
                capture: { pid in
                    spawned.withLock { $0 = pid }
                    return nil
                },
                exited: { _ in exits.withLock { $0 += 1 } })
            group.signal(SIGKILL)
            Issue.record("launched although its group was unreadable")
        } catch {
            #expect(error == .groupUnreadable)
        }
        let pid = spawned.withLock { $0 }
        #expect(pid > 1)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
        #expect(broker.broker.liveCount == 0)
        #expect(exits.withLock { $0 } == 0)
    }

    @Test(.enabled(if: SecretRunProcess.isAvailable), .timeLimit(.minutes(1)))
    func aFailedSpawnRevokesTheLease() throws {
        let fixture = try SecretsFixture(placeholderSecrets)
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: placeholderResolver, transport: RecordingUpstream().transport,
            peers: .alwaysMember)
        defer { broker.stop() }
        let lease = try broker.lease(["OPENAI_API_KEY"], server: "fixture").get()
        do throws(SecretPlaceholderLaunchError) {
            let group = try lease.launch(
                executable: "/nonexistent/rv-placeholder-server", arguments: [], environment: [:], descriptors: [:],
                workingDirectory: nil, exited: { _ in })
            group.signal(SIGKILL)
            Issue.record("launched a missing executable")
        } catch {
            guard case .spawnFailed = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(broker.broker.liveCount == 0)
    }

    /// The real spawn and kernel peer check: the process leads its own
    /// group, holds only the placeholder, spends it through the gateway, a
    /// process outside its group cannot, and once it exits its grandchild is
    /// killed, it is reaped and its lease is gone.
    @Test(.enabled(if: hostBindsPlaceholders), .timeLimit(.minutes(1)))
    func aBoundProcessSpendsItsPlaceholderAndEndsWithItsGroup() throws {
        let fixture = try SecretsFixture(placeholderSecrets)
        defer { fixture.tearDown() }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = RecordingUpstream(status: 200)
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: placeholderResolver, transport: upstream.transport, peers: .runtime)
        defer { broker.stop() }
        let lease = try broker.lease(["OPENAI_API_KEY"], server: "fixture").get()
        var environment = Dictionary(uniqueKeysWithValues: lease.environment.map { ($0.name, $0.value) })
        environment["PATH"] = "/usr/bin:/bin"
        let script = """
            env > "$1/env"; echo $$ > "$1/pid"; ps -o pgid= -p $$ | tr -d ' ' > "$1/pgid"; pwd > "$1/cwd"
            /usr/bin/curl -s --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' \
              -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" > "$1/status"
            sleep 30 & echo $! > "$1/grandchild"
            echo ready > "$1/ready"
            while [ ! -e "$1/stop" ]; do sleep 0.05; done
            exit 3
            """
        let status = Mutex<Int32?>(nil)
        let group: SecretPlaceholderGroup
        do throws(SecretPlaceholderLaunchError) {
            group = try lease.launch(
                executable: "/bin/sh", arguments: ["-c", script, "sh", directory.path], environment: environment,
                descriptors: [:], workingDirectory: directory.path, exited: { code in status.withLock { $0 = code } })
        } catch {
            Issue.record("launch failed: \(error.message)")
            return
        }
        // Whatever is asserted below, nothing outlives the test.
        defer {
            group.signal(SIGKILL)
            _ = group.waitUntilFinished(until: Date().addingTimeInterval(5))
        }
        try #require(eventually { contents(directory, "ready") == "ready" })

        #expect(contents(directory, "pgid") == contents(directory, "pid"))
        #expect(contents(directory, "pid") == String(group.leader))
        #expect(physical(contents(directory, "cwd")) == physical(directory.path))
        let seen = contents(directory, "env")
        #expect(seen.contains("OPENAI_API_KEY=sk-rvph_"))
        #expect(seen.contains("REAL") == false)
        #expect(contents(directory, "status") == "200")
        #expect(upstream.requests.first?.headers["authorization"] == "Bearer \(realOpenAI)")

        // This test process is outside the server's group.
        let placeholder = try #require(environment["OPENAI_API_KEY"])
        let stolen = try gatewayExchange(port: lease.gatewayPort,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n")
        #expect(stolen.status == 403)
        #expect(upstream.requests.count == 1)

        let grandchild = try #require(pid_t(contents(directory, "grandchild")))
        try Data().write(to: directory.appendingPathComponent("stop"))
        #expect(group.waitUntilFinished(until: Date().addingTimeInterval(10)))
        #expect(group.hasExited)
        let exitStatus = try #require(status.withLock { $0 })
        #expect(exitStatus >> 8 == 3)
        #expect(eventually(5) { kill(grandchild, 0) == -1 && errno == ESRCH })
        #expect(broker.broker.liveCount == 0)
        let uses = fixture.auditLines.filter { $0["kind"] as? String == "secret.use" }
        #expect(uses.isEmpty == false)
        #expect(uses.allSatisfy { $0["runtime"] as? String == "mcp:fixture" })
        let misuse = fixture.auditLines.filter { $0["kind"] as? String == "secret.misuse" }
        #expect(misuse.count == 1)
        #expect(misuse.first?["runtime"] as? String == "mcp:fixture")
        #expect((misuse.first?["detail"] as? [String: String])?["refusal"] == "runtimeMismatch")
        #expect(fixture.auditText.contains(realOpenAI) == false)
    }
    #endif
}

extension Result {
    fileprivate var leaseFailure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
