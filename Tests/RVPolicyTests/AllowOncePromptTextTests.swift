import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// The text the owner reads before approving one allow-once redemption,
/// and the memory-only record rvd keeps of each code it issued so that
/// text can name the whole command.
struct AllowOncePromptTextTests {
    @Test func namesTheWholeCommandSoDifferentTargetsLookDifferent() {
        let main = AllowOncePromptText.reason(
            command: "git push --force origin main", cwd: wd("/tmp/ws"), ruleID: nil)
        let feature = AllowOncePromptText.reason(
            command: "git push --force origin feature", cwd: wd("/tmp/ws"), ruleID: nil)
        #expect(main == "allow once \"git push --force origin main\" in /tmp/ws")
        #expect(main != feature)
    }

    @Test func namesTheCwdAndTheRule() {
        let rule = RuleID(pack: .coreGit, pattern: "push-force")
        #expect(AllowOncePromptText.reason(command: "git push --force", cwd: wd("/tmp/ws"), ruleID: rule)
            == "allow once \"git push --force\" in /tmp/ws (rule core.git:push-force)")
    }

    @Test func controlBidiAndEscapeCharactersAreShownEscapedNotRaw() {
        let text = AllowOncePromptText.reason(
            command: "rm -rf x\u{1B}[2K\u{202E}niam\u{0A}ok", cwd: wd("/tmp/ws"), ruleID: nil)
        #expect(text.unicodeScalars.contains { DisplayedText.needsEscape($0) } == false)
        #expect(text.contains("\\u001b"))
        #expect(text.contains("\\u202e"))
        #expect(text.contains("\\n"))
    }

    @Test func aLongCommandIsCappedWithAVisibleEllipsis() {
        let long = "curl " + String(repeating: "a", count: 1_000)
        let text = AllowOncePromptText.reason(command: long, cwd: wd("/tmp/ws"), ruleID: nil)
        #expect(text.contains("curl aaaa"))
        #expect(text.contains("…\" in /tmp/ws"))
        #expect(text.count < AllowOncePromptText.maxCommandCharacters + 40)
    }

    @Test func aLongCwdKeepsItsTail() {
        let deep = "/tmp/" + String(repeating: "d/", count: 200) + "repo"
        let text = AllowOncePromptText.reason(command: "ls", cwd: wd(deep), ruleID: nil)
        #expect(text.hasSuffix("/repo"))
        #expect(text.contains(" in …"))
        #expect(text.count < AllowOncePromptText.maxCwdCharacters + 40)
    }

    @Test func invokedCommandPrefixesTheWrapperTag() {
        #expect(AllowOncePromptText.invoked(view: "git reset --hard", invocationDisplay: "sudo")
            == "sudo git reset --hard")
        #expect(AllowOncePromptText.invoked(view: "git reset --hard", invocationDisplay: nil)
            == "git reset --hard")
    }

    // MARK: rvd's memory of the codes it issued

    @Test func aDenyMintRemembersTheWholeCommandInMemoryOnly() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RuleID(pack: .coreGit, pattern: "push-force")
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force origin main", cwd: wd("/tmp/ws"), ruleID: rule, now: now,
            maskedSegments: [], invocationPrefix: ["sudo"], invocationDisplay: "sudo"
        )?.code)
        let issued = try #require(await store.issued(codeHash: sha256Hex(code.rawValue), now: now))
        #expect(issued.command == "sudo git push --force origin main")
        #expect(issued.cwd == wd("/tmp/ws"))
        #expect(issued.ruleID == rule)
        #expect(issued.fingerprint
            == grantFingerprint(MatchingView("git push --force origin main"), invocationPrefix: ["sudo"]))
        #expect(issued.payloadDigest == maskedPayloadContentDigest([]))
        #expect(issued.redeemed == false)
        // The same-user file keeps only the redacted head.
        let disk = try String(
            contentsOf: RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory), encoding: .utf8)
        #expect(disk.contains("origin main") == false)
    }

    @Test func onlyCodesThisStoreIssuedAreKnown() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let manual = try await store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), ruleID: nil, tty: tty, now: now)
        // A pre-armed (CLI) mint is not something rvd saw.
        #expect(await store.issued(codeHash: sha256Hex(manual.rawValue), now: now) == nil)
        #expect(await store.issued(codeHash: sha256Hex("abcdef"), now: now) == nil)
        // A second store (a restarted rvd) has no memory of the first's codes.
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)?.code)
        let restarted = AllowOnceStore(baseDirectory: store.baseDirectory)
        #expect(await restarted.issued(codeHash: sha256Hex(code.rawValue), now: now) == nil)
    }

    @Test func anIssuedCodeExpiresWithItsPendingRow() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now, ttl: 60)?.code)
        let hash = sha256Hex(code.rawValue)
        #expect(await store.issued(codeHash: hash, now: now.addingTimeInterval(59)) != nil)
        #expect(await store.issued(codeHash: hash, now: now.addingTimeInterval(61)) == nil)
    }

    @Test func markingRedeemedIsRemembered() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)?.code)
        let hash = sha256Hex(code.rawValue)
        await store.markIssuedRedeemed(codeHash: hash)
        #expect(await store.issued(codeHash: hash, now: now)?.redeemed == true)
    }

    @Test func pendingRowIsReadByCodeHash() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), ruleID: nil, tty: tty, now: now)
        let byCode = try #require(await store.validatePending(code: code.rawValue, now: now))
        let byHash = try #require(await store.pendingRow(codeHash: sha256Hex(code.rawValue), now: now))
        #expect(byHash.row == byCode.row)
        #expect(byHash.fingerprint == byCode.fingerprint)
        let missing = await store.pendingRow(codeHash: sha256Hex("abcdef"), now: now)
        #expect(missing.map(\.fingerprint) == nil)
    }
}

private func promptStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-prompt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
