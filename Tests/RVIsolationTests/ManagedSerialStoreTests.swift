#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import RVPolicy
import Testing

@Suite("ManagedSerialStore")
struct ManagedSerialStoreTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-serial-\(UUID().uuidString)")
        var managed: URL { root.appendingPathComponent("managed") }
        var config: URL { root.appendingPathComponent("config") }
        var state: URL { config.appendingPathComponent("managed-state.json") }
        let key = ManagedPolicyVerifier.generateKeyPair()

        init() throws {
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            chmod(root.path, 0o755)
            chmod(managed.path, 0o755)
            try install(serial: nil)
            try Data((key.publicKey + "\n").utf8).write(to: managed.appendingPathComponent("org-key.pub"))
        }

        func install(serial: Int?) throws {
            let policy = Data((serial.map { #"{"version": 1, "serial": \#($0)}"# } ?? #"{"version": 1}"#).utf8)
            let signature = try #require(ManagedPolicyVerifier.sign(policy, privateKey: Data(key.privateKey.utf8)))
            try policy.write(to: managed.appendingPathComponent("policy.json"))
            try Data(signature.utf8).write(to: managed.appendingPathComponent("policy.json.sig"))
        }

        func load() -> ManagedPolicyState {
            ManagedPolicyLocation(directory: managed, requiredOwner: getuid(), trustRoot: root.path)
                .load(serialsIn: config)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func replayingAnOlderSignedPolicyIsARollback() throws {
        let fixture = try Fixture()
        #expect(fixture.load().policy != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.state.path) == false)

        try fixture.install(serial: 3)
        guard case .active(let bundle) = fixture.load() else {
            Issue.record("serial 3 must be accepted")
            return
        }
        #expect(bundle.highestSerial == 3)
        let saved = try #require(try? Data(contentsOf: fixture.state))
        #expect(ManagedSerialRecord.decode(saved) == .success(ManagedSerialRecord(highest: [fixture.managed.path: 3])))
        var info = stat()
        #expect(stat(fixture.state.path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        try fixture.install(serial: 2)
        #expect(fixture.load().invalidReason?.hasPrefix("rollback: policy.json serial 2 is lower than serial 3") == true)
        try fixture.install(serial: nil)
        #expect(fixture.load().invalidReason?.hasPrefix("rollback: policy.json has no serial") == true)
        try fixture.install(serial: 4)
        #expect(fixture.load().policy?.serial == 4)
        #expect(ManagedSerialRecord.decode(try Data(contentsOf: fixture.state))
            == .success(ManagedSerialRecord(highest: [fixture.managed.path: 4])))
    }

    @Test func anUnusableRecordFailsClosed() throws {
        let fixture = try Fixture()
        try fixture.install(serial: 1)
        try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: fixture.state)
        chmod(fixture.state.path, 0o600)
        #expect(fixture.load().invalidReason?.contains("cannot be checked for rollback") == true)
        chmod(fixture.state.path, 0o666)
        #expect(fixture.load().invalidReason?.contains("cannot be checked for rollback") == true)
    }
}
