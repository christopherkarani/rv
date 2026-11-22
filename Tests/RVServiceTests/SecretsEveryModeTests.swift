import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// "Your agents can never leak your keys": an agent's read of a secret file
/// and its switching off of the commit check stop in every mode, as rv's
/// self-protection does. Watch (observe) mode records everything else, but
/// a watched secret read would already have handed the agent the value.
@Suite("Secrets stop in every mode")
struct SecretsEveryModeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let observe = #"{"guard":{"hosts":{"claude":"observe"}}}"#
    private static let block = #"{"guard":{"hosts":{"claude":"block"}}}"#

    private static func home(_ config: String) throws -> HomeDirectory {
        let home = try guardHome(mode: nil)
        let directory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return home
    }

    private static func apply(_ command: String, home: HomeDirectory) async -> EvaluationResult {
        await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { .empty }, host: .hook(.claude)
        )
    }

    @Test("observe host: reading a secret file is stopped, not watched", arguments: [
        "cat .env",
        "cat ./.env.local",
        "head -n 3 .env",
        "grep KEY .env",
        "cat ~/.ssh/id_rsa",
        "cat ~/.aws/credentials",
        "cat ~/.config/gh/hosts.yml",
        "cat ~/.codex/auth.json",
        // A secret read an earlier pack deny would hide from the verdict.
        "git reset --hard; cat .env",
        "git reset --hard && cat ~/.ssh/id_ed25519",
        // A secret read in program text the command feeds a shell.
        "bash -c 'cat .env'",
        "echo 'cat .env' | sh",
    ])
    func observeStopsSecretReads(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let result = await Self.apply(command, home: home)
        #expect(result.decision != .allow, "\(command)")
        #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
    }

    @Test("observe host: everyday commands are still only watched", arguments: [
        "git reset --hard",
        "rm -rf ~/Documents",
    ])
    func observeStillWatchesTheRest(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let result = await Self.apply(command, home: home)
        #expect(result.decision == .allow, "\(command)")
        #expect(ledgerRows(home).map(\.observed) == [true], "\(command)")
    }

    @Test("observe host: an example env file stays readable", arguments: ["cat .env.example", "ls -la"])
    func observeAllowsExampleFiles(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        #expect(await Self.apply(command, home: home).decision == .allow, "\(command)")
    }

    @Test("file door: Read of a secret file is denied on an observe host", arguments: [
        "/.env", "/project/.env.production", "/.ssh/id_rsa", "/.aws/credentials",
    ])
    func observeFileDoorDeniesSecretReads(suffix: String) throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + suffix))
        let result = GatedEvaluate().runFile(action, home: home, host: .hook(.claude), now: Self.now)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(suffix): expected a deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.pack == .coreSecrets)
        #expect(ledgerRows(home).allSatisfy { $0.observed == false })
    }

    // MARK: S2: the commit check's off switch

    @Test("the commit check's off switch is owner-only on every host", arguments: [
        "git config rv.secretsScan false",
        "git config --global rv.secretsScan false",
        "git -c rv.secretsScan=false commit -m x",
        "echo 'config.ts:generic-secret:3' >> .rv-secrets-ignore",
        #"sed -i 's/$/ # rv-secrets:allow/' config.ts"#,
    ])
    func switchIsOwnerOnly(command: String) async throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let result = await Self.apply(command, home: home)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(config) \(command): expected a deny, got \(result.decision)")
                continue
            }
            #expect(deny.ruleID == SecretsScanGuard.ruleID, "\(config) \(command): \(deny.ruleID)")
            #expect(deny.reason == SecretsScanGuard.reason)
            #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
        }
    }

    @Test("reading the switch and searching for allow comments stay allowed", arguments: [
        "git config --get rv.secretsScan",
        "grep -rn rv-secrets:allow .",
        "git config rv.secretsScan true",
    ])
    func readsStayAllowed(command: String) async throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        #expect(await Self.apply(command, home: home).decision == .allow, "\(command)")
    }

    @Test("file door: writing the scan's controls is denied, reading them is not", arguments: [
        "/repo/.rv-secrets-ignore", "/repo/.git/config", "/repo/.git/hooks/pre-commit", "/.gitconfig",
    ])
    func fileDoorGuardsScanControls(suffix: String) throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let path = FileToolPath(rawValue: home.rawValue + suffix)
            for kind in [FileToolKind.write, .edit] {
                let result = GatedEvaluate().runFile(
                    FileToolAction(kind: kind, path: path), home: home, host: .hook(.claude), now: Self.now)
                guard case .deny(let deny) = result.decision else {
                    Issue.record("\(config) \(kind) \(suffix): expected a deny, got \(result.decision)")
                    continue
                }
                #expect(deny.ruleID == SecretsScanGuard.ruleID)
            }
            let read = GatedEvaluate().runFile(
                FileToolAction(kind: .read, path: path), home: home, host: .hook(.claude), now: Self.now)
            #expect(read.decision == .allow, "\(config) read \(suffix)")
        }
    }
}
