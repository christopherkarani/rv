import Testing
import RVDomain

@Suite("ActionFingerprint")
struct ActionFingerprintTests {
    @Test func make_nilSessionOccupiesEmptyField() {
        let fingerprint = ActionFingerprint.make(
            host: .pi,
            session: nil,
            cwd: WorkingDirectory(validating: "/repo"),
            command: ShellCommand(rawValue: "git status")
        )
        #expect(fingerprint.rawValue == "pi::/repo:git status")
    }

    @Test func make_nilCwdOccupiesEmptyField() {
        let fingerprint = ActionFingerprint.make(
            host: .pi,
            session: SessionID(validating: "s1"),
            cwd: nil,
            command: ShellCommand(rawValue: "git status")
        )
        #expect(fingerprint.rawValue == "pi:s1::git status")
    }

    @Test(arguments: HookHost.allCases)
    func make_usesHostRawValue(_ host: HookHost) {
        let fingerprint = ActionFingerprint.make(
            host: host,
            session: SessionID(validating: "s1"),
            cwd: WorkingDirectory(validating: "/repo"),
            command: ShellCommand(rawValue: "git status")
        )
        #expect(fingerprint.rawValue == "\(host.rawValue):s1:/repo:git status")
    }
}
