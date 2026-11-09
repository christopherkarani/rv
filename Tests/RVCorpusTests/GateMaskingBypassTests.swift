import Testing
import RVDomain
import RVEngine

/// Verified gate bypasses (prod-readiness pass, 2026-11-10). Every deny row
/// here was allowed on main by both the pack floor and the door.
@Suite("Gate masking bypasses")
struct GateMaskingBypassTests {
    /// A wrapper flag's VALUE (`env -u NAME`, `sudo -p PROMPT`) is not argv0:
    /// taking it for the command masked the real command's operands.
    @Test(
        "wrapper flag value is not taken for the command",
        arguments: [
            "env -u echo diskutil eraseDisk APFS X disk4",
            "sudo -p echo mkfs.ext4 /dev/sdb1",
            "env -u echo rm -rf src",
            "sudo -u echo rm -rf src",
            "sudo -g echo -p echo mkfs.ext4 /dev/sdb1",
            "env --unset echo rm -rf src",
            "env -C echo rm -rf src",
            "sudo -u root -- echo hi && env -u echo rm -rf src",
        ]
    )
    func wrapperFlagValueDoesNotMask(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision.isDeny, "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "wrapped data commands keep their masking",
        arguments: [
            "sudo -u root echo 'rm -rf /'",
            "env -u FOO echo 'git reset --hard'",
            "env FOO=bar echo 'rm -rf src'",
            "sudo echo 'mkfs.ext4 /dev/sdb1'",
        ]
    )
    func wrappedDataCommandsStayAllowed(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(harness.pin(command).decision == .allow, "\(command)")
    }

    /// An input redirect glued to the word before it still opens its file.
    @Test(
        "glued input redirect still names the secret operand",
        arguments: [
            "cat<.env",
            "base64<~/.ssh/id_rsa",
            "base64 -w0<~/.ssh/id_rsa",
            "cat foo<.env",
            "grep x<.env",
            "/bin/cat<.env",
        ]
    )
    func gluedInputRedirectIsASecretRead(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision.isDeny, "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "glued redirects of ordinary files stay allowed",
        arguments: ["cat<README.md", "wc -l<src/a.txt", "sort<in.txt>out.txt", "cat<<EOF\nhi\nEOF"]
    )
    func gluedOrdinaryRedirectStaysAllowed(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(harness.pin(command).decision == .allow, "\(command): \(describeDecision(harness.pin(command)))")
    }
}
