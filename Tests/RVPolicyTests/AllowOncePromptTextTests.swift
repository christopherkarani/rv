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

    @Test func namesTheCodeSoTheOwnerCanTellPromptsApart() {
        // The CLI says which code to approve; a prompt the agent raised for
        // another code reads differently.
        let rule = RuleID(pack: .coreGit, pattern: "push-force")
        #expect(AllowOncePromptText.reason(
            command: "git push --force", cwd: wd("/tmp/ws"), ruleID: rule, code: "abc123")
            == "allow once \"git push --force\" in /tmp/ws (rule core.git:push-force, code abc123)")
        #expect(AllowOncePromptText.reason(command: "ls", cwd: wd("/tmp/ws"), ruleID: nil, code: "abc123")
            == "allow once \"ls\" in /tmp/ws (code abc123)")
    }

    @Test func quotesAndBackslashesCannotFakeTheEndOfTheCommand() throws {
        // Unescaped, this reads as `allow once "rm -rf ~" in /tmp (rule x,
        // code 000000)` with the real cwd and code pushed out of view.
        let text = try #require(AllowOncePromptText.reason(
            command: #"rm -rf ~" in /tmp (rule x, code 000000) \"#, cwd: wd(#"/tmp/a"b\c"#),
            ruleID: nil, code: "abc123"))
        #expect(text == #"allow once "rm -rf ~\" in /tmp (rule x, code 000000) \\" in /tmp/a\"b\\c (code abc123)"#)
        // The only unescaped quotes are the two around the command.
        let body = text.replacingOccurrences(of: #"\\"#, with: "").replacingOccurrences(of: #"\""#, with: "")
        #expect(body.filter { $0 == "\"" }.count == 2)
    }

    @Test func controlBidiAndEscapeCharactersAreShownEscapedNotRaw() throws {
        let text = try #require(AllowOncePromptText.reason(
            command: "rm -rf x\u{1B}[2K\u{202E}niam\u{0A}ok", cwd: wd("/tmp/ws"), ruleID: nil))
        #expect(text.unicodeScalars.contains { DisplayedText.needsEscape($0) } == false)
        #expect(text.contains("\\u001b"))
        #expect(text.contains("\\u202e"))
        #expect(text.contains("\\n"))
    }

    @Test func blankLookingAndIgnorableCharactersAreShownEscaped() throws {
        // Hangul fillers, braille blank, halfwidth filler, no-break and
        // ideographic spaces, zero-width space, joiner, variation selector:
        // each renders as nothing or as a plain space.
        let hidden: [Unicode.Scalar] = [
            "\u{3164}", "\u{115F}", "\u{1160}", "\u{2800}", "\u{FFA0}", "\u{00A0}", "\u{3000}",
            "\u{200B}", "\u{200D}", "\u{FE0F}", "\u{2060}",
        ]
        for scalar in hidden {
            let text = try #require(AllowOncePromptText.reason(
                command: "git status \(Character(scalar)) rm -rf ~", cwd: wd("/tmp/ws"), ruleID: nil))
            #expect(text.unicodeScalars.allSatisfy { $0.isASCII || $0 == "…" }, "U+\(String(scalar.value, radix: 16))")
            #expect(text.contains(String(format: "\\u%04x", scalar.value)))
        }
    }

    @Test func aCommandThatDoesNotFitIsRefusedNotCut() {
        // The grant covers the whole command, so a cut prompt would hide
        // the part that runs: `git status ; : <fillers> ; rm -rf ~/work`.
        let padded = "git status ; : " + String(repeating: "\u{3164}", count: 230) + " ; rm -rf ~/work"
        #expect(AllowOncePromptText.reason(command: padded, cwd: wd("/tmp/ws"), ruleID: nil) == nil)
        let long = "curl " + String(repeating: "a", count: 1_000)
        #expect(AllowOncePromptText.reason(command: long, cwd: wd("/tmp/ws"), ruleID: nil) == nil)
        let fits = "curl " + String(repeating: "a", count: AllowOncePromptText.maxCommandScalars - 5)
        #expect(AllowOncePromptText.reason(command: fits, cwd: wd("/tmp/ws"), ruleID: nil)?.contains(fits) == true)
    }

    @Test func theCapCountsUnicodeScalarsNotCharacters() {
        // 200 characters, 400 scalars: combining marks stack on one glyph.
        let stacked = String(repeating: "e\u{0301}", count: 200)
        #expect(stacked.count == 200)
        #expect(AllowOncePromptText.reason(command: stacked, cwd: wd("/tmp/ws"), ruleID: nil) == nil)
    }

    @Test func aCwdThatDoesNotFitIsRefusedNotCut() {
        let deep = "/tmp/" + String(repeating: "d/", count: 200) + "repo"
        #expect(AllowOncePromptText.reason(command: "ls", cwd: wd(deep), ruleID: nil) == nil)
    }

    // MARK: rvd's memory of the codes it issued

    @Test func aDenyMintRemembersTheWholeCommandInMemoryOnly() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RuleID(pack: .coreGit, pattern: "push-force")
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force origin main", cwd: wd("/tmp/ws"), ruleID: rule, now: now,
            maskedSegments: [], invocationPrefix: ["LD_PRELOAD=/tmp/x.so", "sudo -u deploy"],
            invocationDisplay: "LD_PRELOAD=… sudo",
            rawCommand: "LD_PRELOAD=/tmp/x.so sudo -u deploy git push --force origin main"
        )?.code)
        let issued = try #require(await store.issued(codeHash: sha256Hex(code.rawValue), now: now))
        // The exact text the hook denied, not the matching view: env
        // values and wrapper flags the view drops are all there.
        #expect(issued.command == "LD_PRELOAD=/tmp/x.so sudo -u deploy git push --force origin main")
        #expect(issued.code == code)
        #expect(issued.cwd == wd("/tmp/ws"))
        #expect(issued.ruleID == rule)
        #expect(issued.fingerprint
            == grantFingerprint(
                MatchingView("git push --force origin main"),
                invocationPrefix: ["LD_PRELOAD=/tmp/x.so", "sudo -u deploy"]))
        #expect(issued.payloadDigest == maskedPayloadContentDigest([]))
        #expect(issued.redeemed == false)
        // The same-user file keeps only the redacted head.
        let disk = try String(
            contentsOf: RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory), encoding: .utf8)
        #expect(disk.contains("origin main") == false)
        #expect(disk.contains("/tmp/x.so") == false)
    }

    @Test func aMintWithoutTheExactTextRemembersNoCommand() async throws {
        // Only the matching view: rvd cannot show what the grant covers,
        // so it will not prompt for this code.
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)?.code)
        let issued = try #require(await store.issued(codeHash: sha256Hex(code.rawValue), now: now))
        #expect(issued.command == nil)
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

    @Test func aPreArmedMintIsRememberedWithTheTypedCommandUntilRvdRestarts() async throws {
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let typed = "LD_PRELOAD=/tmp/x.so git push --force origin main"
        let code = try await store.mintPreArmed(
            matchingView: "git push --force origin main", cwd: wd("/tmp/ws"), now: now,
            maskedSegments: [], invocationPrefix: ["LD_PRELOAD=/tmp/x.so"], invocationDisplay: "LD_PRELOAD=…",
            rawCommand: typed)
        let issued = try #require(await store.issued(codeHash: sha256Hex(code.rawValue), now: now))
        #expect(issued.command == typed)
        #expect(issued.ruleID == nil)
        #expect(issued.fingerprint
            == grantFingerprint(MatchingView("git push --force origin main"), invocationPrefix: ["LD_PRELOAD=/tmp/x.so"]))
        // Pre-armed codes keep the 24 h window of a manual mint.
        #expect(await store.issued(codeHash: sha256Hex(code.rawValue), now: now.addingTimeInterval(23 * 3600)) != nil)
        let pending = try #require(await store.validatePending(code: code.rawValue, now: now))
        #expect(pending.fingerprint == issued.fingerprint.rawValue)
        #expect(pending.row.invocationDisplay == "LD_PRELOAD=…")
        let disk = try String(
            contentsOf: RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory), encoding: .utf8)
        #expect(disk.contains("/tmp/x.so") == false)
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

    @Test func aRedeemedCodeIsNotHandedOutAgainForTheSameCommand() async throws {
        // Before the CLI flips its row the pending row still matches, so a
        // second deny used to reuse the cached code, already spent.
        let store = try promptStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = try #require(await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)?.code)
        let again = await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)
        #expect(again?.code == code)
        await store.markIssuedRedeemed(codeHash: sha256Hex(code.rawValue))
        let afterPlant = await store.mintFromDeny(
            matchingView: "git push --force", cwd: wd("/tmp/ws"), ruleID: nil, now: now)
        #expect(afterPlant?.code != code)
    }
}

private func promptStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-prompt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
