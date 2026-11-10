import Foundation
import Testing
import RVDomain
import RVEngine

private func threadCPUSeconds() -> Double {
    var spec = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
    return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
}

private func isDenied(_ result: EvaluationResult) -> Bool {
    if case .deny = result.decision { return true }
    return false
}

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
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
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
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    /// A safe pattern vouches for a whole pack, so it must match the command
    /// itself, never a word inside a destructive command's operands.
    @Test(
        "safe pattern word inside a destructive command does not skip the pack",
        arguments: [
            "mkfs.ext4 -L df /dev/sdb1",
            "diskutil eraseDisk APFS df disk4",
            "wipefs -a /dev/sdb --backup=lvs",
            "wipefs -a /dev/sdb lsblk",
            "mkfs.ext4 /dev/sdb1 mount",
            "wipefs -a /dev/sdb -- fdisk -l",
            "wipefs -a /dev/sdb >& lsblk",
            "wipefs -a $(lsblk -no PATH /dev/sdb)",
            "dd if=/x/of=y.img of=/dev/sda",
            "git clean -fdx -- $PWD checkout -b y",
            "git --no-pager clean -fdx -- $PWD checkout -b y",
            "git clean -fdx -- . restore --staged",
            "rm -rf ~ rm -rf /tmp/x",
        ]
    )
    func safeWordInOperandsDoesNotSkipPack(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "read-only disk and branch commands stay allowed",
        arguments: [
            "df -h /dev/sda1",
            "lsblk /dev/sdb",
            "blkid /dev/sda1",
            "sudo fdisk -l /dev/sda",
            "ls && df -h /dev/sda1",
            "mount",
            "dd if=/dev/sda of=/dev/null bs=1M count=1",
            "git checkout -b feat",
            "git -C repo checkout -b feat",
            "git --no-pager checkout -b feat",
            "git restore --staged src/a.txt",
            "git clean -n",
        ]
    )
    func readOnlyCommandsStayAllowed(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        let result = harness.pin(command)
        #expect(result.decision == .allow, "\(command): \(describeDecision(result))")
    }

    /// The 6 KB `rm --recursive` run took 7.8 s in `rv test` on main.
    /// Measured in this thread's CPU time: wall time on a loaded host says
    /// nothing about backtracking.
    @Test func longRecursiveRunFinishesQuickly() throws {
        let harness = try StressHarness.dayOne()
        for command in [
            String(repeating: "rm --recursive ", count: 400),
            String(repeating: "rm --force ", count: 550),
            "rm " + String(repeating: "-r ", count: 2000),
            "rm -" + String(repeating: "r", count: 6000),
        ] {
            let started = threadCPUSeconds()
            let result = harness.door(command)
            #expect(threadCPUSeconds() - started < 1, "\(command.prefix(20))…")
            if result.decision == .indeterminate(.budgetExhausted) { continue }
            #expect(result.decision != .indeterminate(.commandTooLarge))
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
