import Foundation
import Synchronization
import Testing
@testable import RVIsolation

@Suite struct SecretServiceToolTests {
    private static func probe(
        tools: Set<String> = ["/usr/bin/secret-tool"],
        ownedSockets: Set<String> = ["/run/user/1000/bus"],
        environment: [String: String] = [:]
    ) -> SecretServiceTool.Probe {
        SecretServiceTool.Probe(
            environment: environment, uid: 1000,
            isExecutable: { tools.contains($0) },
            isOwnedSocket: { path, uid in uid == 1000 && ownedSockets.contains(path) })
    }

    @Test func resolvesTheToolOnlyFromSystemPaths() {
        #expect(SecretServiceTool.availability(Self.probe(tools: [])) == .missingTool)
        #expect(SecretServiceTool.availability(Self.probe(tools: ["/home/me/bin/secret-tool"])) == .missingTool)
        guard case .available(let tool, _) = SecretServiceTool.availability(Self.probe(tools: ["/bin/secret-tool"])) else {
            Issue.record("expected /bin/secret-tool")
            return
        }
        #expect(tool == "/bin/secret-tool")
    }

    @Test func prefersTheUidBusOverTheEnvironment() {
        let availability = SecretServiceTool.availability(Self.probe(environment: [
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/agent-bus", "XDG_RUNTIME_DIR": "/tmp/agent",
        ]))
        guard case .available(_, let environment) = availability else {
            Issue.record("expected available")
            return
        }
        #expect(environment["DBUS_SESSION_BUS_ADDRESS"] == "unix:path=/run/user/1000/bus")
        #expect(environment["XDG_RUNTIME_DIR"] == "/run/user/1000")
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test func fallsBackToTheEnvironmentBusOnlyWithoutTheUidBus() {
        let availability = SecretServiceTool.availability(Self.probe(
            ownedSockets: [], environment: ["DBUS_SESSION_BUS_ADDRESS": "unix:abstract=/tmp/dbus-x"]))
        guard case .available(_, let environment) = availability else {
            Issue.record("expected available")
            return
        }
        #expect(environment["DBUS_SESSION_BUS_ADDRESS"] == "unix:abstract=/tmp/dbus-x")
    }

    @Test func noBusMeansNothingRuns() {
        #expect(SecretServiceTool.availability(Self.probe(ownedSockets: [])) == .noSessionBus)
        #expect(SecretServiceTool.availability(Self.probe(
            ownedSockets: [], environment: ["DBUS_SESSION_BUS_ADDRESS": "  "])) == .noSessionBus)
        let ran = Mutex(false)
        let runner: SecretServiceTool.Runner = { _, _, _, _, _ in
            ran.withLock { $0 = true }
            return BoundedProcess.Outcome(status: 0, stdout: [], stderr: [])
        }
        #expect(SecretServiceTool.store(
            service: "rv.secrets", account: "K", value: Data("v".utf8), availability: .noSessionBus, run: runner) == false)
        #expect(SecretServiceTool.lookup(service: "rv.secrets", account: "K", availability: .missingTool, run: runner) == nil)
        #expect(SecretServiceTool.delete(service: "rv.secrets", account: "K", availability: .noSessionBus, run: runner) == false)
        // No secret-tool: rv never stored anything, so nothing is left to remove.
        #expect(SecretServiceTool.delete(service: "rv.secrets", account: "K", availability: .missingTool, run: runner))
        #expect(ran.withLock { $0 } == false)
    }

    private static let available = SecretServiceTool.Availability.available(
        tool: "/usr/bin/secret-tool",
        environment: ["PATH": "/usr/bin:/bin", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"])

    @Test func storeSendsTheValueOnStdinOnly() {
        let value = "sk-live-0123456789abcdef"
        let seen = Mutex<(args: [String], env: [String: String], input: [UInt8]?)?>(nil)
        let ok = SecretServiceTool.store(
            service: "rv.secrets", account: "OPENAI_API_KEY", value: Data(value.utf8), availability: Self.available
        ) { tool, args, env, _, input in
            #expect(tool == "/usr/bin/secret-tool")
            seen.withLock { $0 = (args, env, input) }
            return BoundedProcess.Outcome(status: 0, stdout: [], stderr: [])
        }
        #expect(ok)
        let call = seen.withLock { $0 }
        #expect(call?.args == [
            "store", "--label=rv: OPENAI_API_KEY (rv.secrets)", "service", "rv.secrets", "account", "OPENAI_API_KEY",
        ])
        #expect(call?.input == Array(value.utf8))
        #expect(call?.args.contains { $0.contains(value) } == false)
        #expect(call?.env.values.contains { $0.contains(value) } == false)
    }

    @Test func storeFailsOnAToolFailure() {
        #expect(SecretServiceTool.store(
            service: "rv.secrets", account: "K", value: Data("v".utf8), availability: Self.available
        ) { _, _, _, _, _ in BoundedProcess.Outcome(status: 1, stdout: [], stderr: Array("locked".utf8)) } == false)
        #expect(SecretServiceTool.store(
            service: "rv.secrets", account: "K", value: Data("v".utf8), availability: Self.available
        ) { _, _, _, _, _ in nil } == false)
        #expect(SecretServiceTool.store(
            service: "rv.secrets", account: "K", value: Data(), availability: Self.available
        ) { _, _, _, _, _ in BoundedProcess.Outcome(status: 0, stdout: [], stderr: []) } == false)
    }

    @Test func lookupReadsStdoutAndTreatsAMissAsNil() {
        let args = Mutex<[String]>([])
        let found = SecretServiceTool.lookup(service: "openai", account: "me", availability: Self.available) { _, a, _, _, input in
            args.withLock { $0 = a }
            #expect(input == nil)
            return BoundedProcess.Outcome(status: 0, stdout: Array("value-bytes".utf8), stderr: [])
        }
        #expect(found == Data("value-bytes".utf8))
        #expect(args.withLock { $0 } == ["lookup", "service", "openai", "account", "me"])
        #expect(SecretServiceTool.lookup(service: "s", account: "a", availability: Self.available) { _, _, _, _, _ in
            BoundedProcess.Outcome(status: 1, stdout: [], stderr: [])
        } == nil)
        #expect(SecretServiceTool.lookup(service: "s", account: "a", availability: Self.available) { _, _, _, _, _ in
            BoundedProcess.Outcome(status: 0, stdout: [], stderr: [])
        } == nil)
    }

    /// `secret-tool clear` exits 1 both for "nothing matched" and for an
    /// error (checked against gnome-keyring), so a miss is confirmed by a
    /// silent lookup miss before delete reports the item gone.
    @Test(arguments: [
        // clear, lookup → gone?
        (0, "", 9, "", "", true),
        (1, "", 1, "", "", true),
        (1, "", 0, "value", "", false),
        (1, "Cannot autolaunch D-Bus", 1, "", "", false),
        (1, "", 1, "", "The name org.freedesktop.secrets was not provided", false),
    ] as [(Int32, String, Int32, String, String, Bool)])
    func deleteReportsGoneOnlyWhenItIs(
        _ clearStatus: Int32, _ clearErr: String, _ lookupStatus: Int32, _ lookupOut: String, _ lookupErr: String,
        _ gone: Bool
    ) {
        let calls = Mutex<[[String]]>([])
        let result = SecretServiceTool.delete(service: "rv.secrets", account: "K", availability: Self.available) {
            _, args, _, _, _ in
            calls.withLock { $0.append(args) }
            if args.first == "clear" {
                return BoundedProcess.Outcome(status: clearStatus, stdout: [], stderr: Array(clearErr.utf8))
            }
            return BoundedProcess.Outcome(
                status: lookupStatus, stdout: Array(lookupOut.utf8), stderr: Array(lookupErr.utf8))
        }
        #expect(result == gone)
        #expect(calls.withLock { $0 }.first == ["clear", "service", "rv.secrets", "account", "K"])
    }

    @Test func failureTextNamesWhatIsMissing() {
        #expect(SecretServiceTool.storeFailureSuffix(.missingTool).contains("libsecret-tools"))
        #expect(SecretServiceTool.storeFailureSuffix(.noSessionBus).contains("session bus"))
        #expect(SecretServiceTool.storeFailureSuffix(Self.available).contains("unlocked"))
    }

    /// The real `secret-tool` against a fake one at the same interface: the
    /// value reaches the tool on stdin and comes back on stdout.
    @Test func roundTripsThroughAToolOnStdinAndStdout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-secret-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("item")
        let tool = dir.appendingPathComponent("secret-tool")
        try """
        #!/bin/sh
        case "$1" in
          store) cat > \(store.path); printf '%s\\n' "$*" > \(store.path).args ;;
          lookup) [ -f \(store.path) ] || exit 1; cat \(store.path) ;;
          clear) [ -f \(store.path) ] || exit 1; rm -f \(store.path) ;;
        esac
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let availability = SecretServiceTool.Availability.available(tool: tool.path, environment: ["PATH": "/usr/bin:/bin"])
        let value = Data("tok-\(UUID().uuidString)".utf8)
        #expect(SecretServiceTool.store(service: "rv.secrets", account: "K", value: value, availability: availability))
        let args = try String(contentsOf: URL(fileURLWithPath: store.path + ".args"), encoding: .utf8)
        #expect(args.contains(String(decoding: value, as: UTF8.self)) == false)
        #expect(SecretServiceTool.lookup(service: "rv.secrets", account: "K", availability: availability) == value)
        #expect(SecretServiceTool.delete(service: "rv.secrets", account: "K", availability: availability))
        #expect(SecretServiceTool.lookup(service: "rv.secrets", account: "K", availability: availability) == nil)
        // Deleting what is not there is not a failure (the tool exits 1, silently).
        #expect(SecretServiceTool.delete(service: "rv.secrets", account: "K", availability: availability))
    }
}
