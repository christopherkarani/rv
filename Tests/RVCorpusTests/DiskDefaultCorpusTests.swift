import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

@Suite struct DiskDefaultCorpusTests {
    @Test func mkfsExt4Device_deniesOnDayOne() throws {
        let result = try evaluateDayOne("mkfs.ext4 /dev/disk0")
        guard case .deny(let deny) = result.decision else {
            Issue.record("expected deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.pack == .systemDisk)
        #expect(deny.ruleID.pattern == "mkfs")
    }

    @Test func ddWipeDevice_deniesOnDayOne() throws {
        for command in [
            "dd if=/dev/zero of=/dev/rdisk0 bs=1m",
            "dd if=/dev/zero of=/dev/disk0",
        ] {
            let result = try evaluateDayOne(command)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(command): expected deny, got \(result.decision)")
                continue
            }
            #expect(deny.ruleID.pack == .systemDisk, "\(command)")
        }
    }

    @Test func ddFileOut_allowsOnDiskPack() throws {
        let packs = try PackRegistry.loadDayOne()
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks.compile(packs: packs, using: engine)
        let result = evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "dd if=/dev/zero of=out.bin"),
                enabledPacks: [.systemDisk]
            ),
            packs: packs,
            patterns: engine,
            compiled: compiled
        )
        #expect(result.decision == .allow)
    }

    @Test func ddFileOut_dayOneAllowsRelativeFile() throws {
        for command in [
            "dd if=/dev/zero of=out.bin",
            "dd if=/dev/zero of=./out.bin",
        ] {
            let result = try evaluateDayOne(command)
            #expect(result.decision == .allow, "\(command) got \(result.decision)")
        }
    }

    @Test func ddOverwritePasswd_deniesOnDayOne() throws {
        let result = try evaluateDayOne("dd if=/dev/zero of=/etc/passwd")
        guard case .deny(let deny) = result.decision else {
            Issue.record("expected deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "core.filesystem:dd-overwrite-root-home")
    }

    @Test func ddTmp_allowsOnDayOne() throws {
        let result = try evaluateDayOne("dd if=/dev/zero of=/tmp/x")
        #expect(result.decision == .allow)
    }

    @Test func inventoryCommands_allowOnDayOne() throws {
        for command in ["lsblk", "df", "mount"] {
            let result = try evaluateDayOne(command)
            #expect(result.decision == .allow, "\(command) got \(result.decision)")
        }
    }

    @Test func disableSystemDisk_stopsMkfsDeny() throws {
        let packs = try PackRegistry.loadDayOne()
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks.compile(packs: packs, using: engine)
        let withoutDisk = dayOnePackIDs.filter { $0 != .systemDisk }
        let result = evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "mkfs.ext4 /dev/disk0"),
                enabledPacks: withoutDisk
            ),
            packs: packs,
            patterns: engine,
            compiled: compiled
        )
        #expect(result.decision == .allow)
    }
}

private func evaluateDayOne(_ command: String) throws -> EvaluationResult {
    let packs = try PackRegistry.loadDayOne()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest.makeDayOne(command: ShellCommand(rawValue: command)),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}
