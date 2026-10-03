import Foundation
import Testing
import RVDomain

/// Step 6 canonical action digest: every security-relevant distinction must
/// survive, including pairs the legacy `:`-concatenated fingerprints
/// collide on. Legacy fingerprint constructors are untouched (their live
/// uses are deny-lists and describe-only APIs); these tests pin the new
/// binding that authorizes exact actions.
@Suite("Canonical action digest")
struct CanonicalActionDigestTests {
    private func shell(
        _ command: String,
        cwd: String = "/work",
        fingerprint: String = "test-shell"
    ) -> ProposedAction {
        .shell(ShellAction(
            fingerprint: ActionFingerprint(rawValue: fingerprint),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: cwd)),
            supportingCommand: ShellCommand(rawValue: command)))
    }

    private func file(kind: FileToolKind = .read, path: String) -> ProposedAction {
        .file(FileAction(
            fingerprint: ActionFingerprint(rawValue: "test-file"),
            file: FileToolAction(kind: kind, path: FileToolPath(rawValue: path))))
    }

    @Test func deterministic() {
        let action = shell("echo hello")
        #expect(CanonicalActionDigest.sha256Hex(of: action) == CanonicalActionDigest.sha256Hex(of: action))
        #expect(CanonicalActionDigest.sha256Hex(of: action).count == 64)
    }

    @Test func commandTextDistinguishes() {
        #expect(
            CanonicalActionDigest.sha256Hex(of: shell("echo hello"))
                != CanonicalActionDigest.sha256Hex(of: shell("echo goodbye")))
    }

    @Test func argvOrderingDistinguishes() {
        #expect(
            CanonicalActionDigest.sha256Hex(of: shell("cp a b"))
                != CanonicalActionDigest.sha256Hex(of: shell("cp b a")))
    }

    @Test func workingDirectoryDistinguishes() {
        #expect(
            CanonicalActionDigest.sha256Hex(of: shell("make", cwd: "/a"))
                != CanonicalActionDigest.sha256Hex(of: shell("make", cwd: "/b")))
    }

    @Test func colonSplitCollisionDistinguished() {
        // Legacy shell spelling `host:session:cwd:command` collides here:
        // cwd="a:b" + command="c" versus cwd="a" + command="b:c" spell the
        // same fingerprint string. The canonical digest must not.
        let legacyLeft = ActionFingerprint.make(
            host: .opencode, session: nil,
            cwd: WorkingDirectory(rawValue: "a:b"), command: ShellCommand(rawValue: "c"))
        let legacyRight = ActionFingerprint.make(
            host: .opencode, session: nil,
            cwd: WorkingDirectory(rawValue: "a"), command: ShellCommand(rawValue: "b:c"))
        #expect(legacyLeft == legacyRight)
        #expect(
            CanonicalActionDigest.sha256Hex(of: shell("c", cwd: "a:b"))
                != CanonicalActionDigest.sha256Hex(of: shell("b:c", cwd: "a")))
    }

    @Test func sessionSplitCollisionDistinguished() {
        // Same flaw through the session slot: session="s:x" + cwd="w" versus
        // session="s" + cwd="x:w" spell the same legacy string.
        let legacyLeft = ActionFingerprint.make(
            host: .opencode, session: SessionID(validating: "s:x"),
            cwd: WorkingDirectory(rawValue: "w"), command: ShellCommand(rawValue: "c"))
        let legacyRight = ActionFingerprint.make(
            host: .opencode, session: SessionID(validating: "s"),
            cwd: WorkingDirectory(rawValue: "x:w"), command: ShellCommand(rawValue: "c"))
        #expect(legacyLeft == legacyRight)
    }

    @Test func fileKindDistinguishes() {
        #expect(
            CanonicalActionDigest.sha256Hex(of: file(kind: .read, path: "/tmp/x"))
                != CanonicalActionDigest.sha256Hex(of: file(kind: .write, path: "/tmp/x")))
        #expect(
            CanonicalActionDigest.sha256Hex(of: file(kind: .read, path: "/tmp/x"))
                != CanonicalActionDigest.sha256Hex(of: file(kind: .edit, path: "/tmp/x")))
    }

    @Test func filePathDistinguishes() {
        #expect(
            CanonicalActionDigest.sha256Hex(of: file(path: "/tmp/a"))
                != CanonicalActionDigest.sha256Hex(of: file(path: "/tmp/b")))
    }

    @Test func caseLabelDistinguishes() {
        // A shell and a file action sharing one fingerprint string must
        // still digest apart: the case discriminator participates.
        let shellAction = shell("x", fingerprint: "shared")
        let fileAction = file(path: "/y")
        #expect(
            CanonicalActionDigest.sha256Hex(of: shellAction)
                != CanonicalActionDigest.sha256Hex(of: fileAction))
    }

    @Test func effectsDistinguish() {
        let plain = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            supportingCommand: ShellCommand(rawValue: "git push"))
        let withEffects = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
            supportingCommand: ShellCommand(rawValue: "git push"))
        #expect(
            CanonicalActionDigest.sha256Hex(of: .shell(plain))
                != CanonicalActionDigest.sha256Hex(of: .shell(withEffects)))
    }

    @Test func resourcesDistinguish() {
        let a = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            resources: ActionResources(remoteName: "origin", branchName: "main"),
            supportingCommand: ShellCommand(rawValue: "git push"))
        let b = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            resources: ActionResources(remoteName: "origin", branchName: "dev"),
            supportingCommand: ShellCommand(rawValue: "git push"))
        #expect(
            CanonicalActionDigest.sha256Hex(of: .shell(a))
                != CanonicalActionDigest.sha256Hex(of: .shell(b)))
    }

    @Test func semanticAnalysisDistinguishes() {
        let plain = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            supportingCommand: ShellCommand(rawValue: "git push"))
        let analyzed = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            supportingCommand: ShellCommand(rawValue: "git push"),
            gitAction: .push(remote: "origin", refspec: "main", force: .none))
        #expect(
            CanonicalActionDigest.sha256Hex(of: .shell(plain))
                != CanonicalActionDigest.sha256Hex(of: .shell(analyzed)))
        let forced = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "f"),
            supportingCommand: ShellCommand(rawValue: "git push"),
            gitAction: .push(remote: "origin", refspec: "main", force: .force))
        #expect(
            CanonicalActionDigest.sha256Hex(of: .shell(analyzed))
                != CanonicalActionDigest.sha256Hex(of: .shell(forced)))
    }

    @Test func domainSeparatedFromBareHash() {
        // The digest must differ from a bare SHA-256 of the JSON bytes, so
        // these digests can never collide with another project's hashes of
        // the same encoding.
        let action = shell("echo hello")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bare = RVDigest.sha256Hex(Array((try! encoder.encode(action))))
        #expect(CanonicalActionDigest.sha256Hex(of: action) != bare)
    }
}
