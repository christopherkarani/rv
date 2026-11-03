import Testing
import RVDomain

/// REQ-006 / AC-005: producers build fingerprints through one injective
/// encoder. Components without `\ , :` keep their historical spelling.
@Suite("ActionFingerprint injective encoding")
struct ActionFingerprintInjectiveTests {
    private func target(_ path: String) -> FilesystemTarget {
        FilesystemTarget(apparent: path, canonical: path, scope: .insideRepository, kind: .unknown)
    }

    private func fs(_ action: FilesystemAction) -> String {
        action.proposedAction(command: ShellCommand(rawValue: "x"), workingDirectory: nil).fingerprint.rawValue
    }

    private func git(_ action: GitAction) -> String {
        action.proposedAction(command: ShellCommand(rawValue: "x"), workingDirectory: nil).fingerprint.rawValue
    }

    // MARK: collisions that existed before the encoder

    @Test func move_commaInTargetDoesNotCollide() {
        let a = fs(.move(sources: [target("/r/a")], destination: target("/r/b,/r/c")))
        let b = fs(.move(sources: [target("/r/a,/r/b")], destination: target("/r/c")))
        #expect(a != b)
        #expect(a == #"shell:fs.move:/r/a,/r/b\,/r/c"#)
        #expect(b == #"shell:fs.move:/r/a\,/r/b,/r/c"#)
    }

    @Test func gitPathspecs_commaDoesNotCollide() {
        #expect(
            git(.discardWorktree(pathspecs: ["a,b"], source: nil))
                != git(.discardWorktree(pathspecs: ["a", "b"], source: nil)))
    }

    @Test func gitBranch_forcePrefixDoesNotCollideWithBranchName() {
        #expect(
            git(.createBranch(name: "force:x", startPoint: nil, force: false))
                != git(.createBranch(name: "x", startPoint: nil, force: true)))
        #expect(
            git(.switchBranch(name: "force:x", force: false))
                != git(.switchBranch(name: "x", force: true)))
    }

    @Test func gitFields_colonDoesNotCollide() {
        #expect(
            git(.rebase(verb: .start, onto: "a:b")) != git(.rebase(verb: .start, onto: "a")) )
        #expect(
            git(.deleteTag(name: "b:c", remote: "a")) != git(.deleteTag(name: "c", remote: "a:b")))
    }

    @Test func hostDoor_colonInCwdDoesNotCollideWithCommand() throws {
        let session = try #require(SessionID(validating: "s1"))
        let cwdA = try #require(WorkingDirectory(validating: "/a:b"))
        let cwdB = try #require(WorkingDirectory(validating: "/a"))
        let one = ActionFingerprint.make(host: .codex, session: session, cwd: cwdA, command: ShellCommand(rawValue: "c"))
        let two = ActionFingerprint.make(host: .codex, session: session, cwd: cwdB, command: ShellCommand(rawValue: "b:c"))
        #expect(one != two)
    }

    @Test func secretRequest_colonInFieldDoesNotCollide() {
        func fp(secret: String, method: String, host: String) -> ActionFingerprint {
            SecretRequestAction(
                secret: secret, method: method, host: host, path: "/", targetSHA256: "t",
                bodySHA256: "b", bodyBytes: 0, headersSHA256: "h", operationHeaders: []
            ).fingerprint
        }
        #expect(fp(secret: "a", method: "b:c", host: "d") != fp(secret: "a", method: "b", host: "c:d"))
    }

    // MARK: goldens (values with no `\ , :` in a component never change)

    @Test func goldens_unchangedForPlainComponents() throws {
        #expect(fs(.move(sources: [target("/r/a")], destination: target("/r/b"))) == "shell:fs.move:/r/a,/r/b")
        #expect(
            fs(.delete(targets: [target("/r/a")], recursive: true, force: false))
                == "shell:fs.delete:true:false:/r/a")
        #expect(fs(.chmod(targets: [target("/r/a")], mode: "755", recursive: false)) == "shell:fs.chmod:false:755:/r/a")
        #expect(fs(.read(targets: [target("/r/a"), target("/r/b")])) == "shell:fs.read:/r/a,/r/b")
        #expect(git(.createBranch(name: "feat", startPoint: nil, force: true)) == "shell:git.create-branch:force:feat")
        #expect(git(.createBranch(name: "feat", startPoint: nil, force: false)) == "shell:git.create-branch:feat")
        #expect(git(.discardWorktree(pathspecs: ["a", "b"], source: nil)) == "shell:git.discard::a,b")
        #expect(git(.reset(mode: .hard, target: nil)) == "shell:git.reset:hard:")
        #expect(git(.clean(force: true, dryRun: false, directories: true)) == "shell:git.clean:true:false:true")
        #expect(git(.deleteBranch(name: "old", force: false)) == "shell:git.delete-branch:false:old")
        #expect(git(.rebase(verb: .start, onto: "main")) == "shell:git.rebase:start:main")
        let session = try #require(SessionID(validating: "s1"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        #expect(
            ActionFingerprint.make(host: .codex, session: session, cwd: cwd, command: ShellCommand(rawValue: "git status")).rawValue
                == "codex:s1:/tmp/ws:git status")
        #expect(
            ActionFingerprint.make(
                host: .codex, session: session, cwd: cwd,
                file: FileToolAction(kind: .write, path: FileToolPath(rawValue: "/tmp/ws/a"))
            ).rawValue == "file:codex:s1:/tmp/ws:write:/tmp/ws/a")
        let secret = SecretRequestAction(
            secret: "tok", method: "GET", host: "api.example.com", path: "/", targetSHA256: "t",
            bodySHA256: "b", bodyBytes: 0, headersSHA256: "h", operationHeaders: [])
        #expect(secret.fingerprint.rawValue == "secret-request:tok:GET:api.example.com:t:b:h")
    }

    // MARK: encoder

    @Test func component_escapesStructuralCharactersAndRoundTrips() {
        #expect(FingerprintComponent.escape("plain/path-1") == "plain/path-1")
        #expect(FingerprintComponent.escape(#"a\b,c:d"#) == #"a\\b\,c\:d"#)
        for raw in ["", "a", #"\"#, ",", ":", #"\,:"#, "a,,b::c", #"x\\y"#] {
            #expect(FingerprintComponent.unescape(FingerprintComponent.escape(raw)) == raw)
        }
        #expect(FingerprintComponent.unescape(#"a\"#) == nil)
        #expect(FingerprintComponent.unescape("a:b") == nil)
        #expect(FingerprintComponent.unescape(#"\x"#) == nil)
    }

    @Test func make_isInjectiveOverFieldBoundaries() {
        #expect(
            ActionFingerprint.make("k", [.field("a:b"), .field("c")])
                != ActionFingerprint.make("k", [.field("a"), .field("b:c")]))
        #expect(
            ActionFingerprint.make("k", [.list(["a,b"])]) != ActionFingerprint.make("k", [.list(["a", "b"])]))
        #expect(
            ActionFingerprint.make("k", [.field(#"a\"#), .field("b")])
                != ActionFingerprint.make("k", [.field("a"), .field(#"\b"#)]))
        #expect(ActionFingerprint.make("k", [.field("a"), .list(["b", "c"])]).rawValue == "k:a:b,c")
    }

    @Test func make_emptyListDiffersFromListOfOneEmptyItem() {
        let empty = ActionFingerprint.make("k", [.list([]), .field("a")])
        let oneEmpty = ActionFingerprint.make("k", [.list([""]), .field("a")])
        #expect(empty != oneEmpty)
        #expect(oneEmpty.rawValue == "k::a")
        // The empty-list token is one segment and never decodes as a component.
        let segments = FingerprintComponent.split(empty.rawValue, separator: ":")
        #expect(segments.count == 3)
        #expect(FingerprintComponent.unescape(segments[1]) == nil)
        #expect(
            git(.discardWorktree(pathspecs: [], source: nil))
                != git(.discardWorktree(pathspecs: [""], source: nil)))
    }

    /// A structural scalar followed by a combining mark is one `Character`
    /// that is not `":"`; escaping must still see the `:` scalar.
    @Test func make_combiningMarkAfterStructuralScalarDoesNotCollide() {
        #expect(
            ActionFingerprint.make("k", [.field("x"), .field("\u{301}y")])
                != ActionFingerprint.make("k", [.field("x:\u{301}y")]))
        #expect(
            ActionFingerprint.make("k", [.list(["a", "\u{301}b"])])
                != ActionFingerprint.make("k", [.list(["a,\u{301}b"])]))
        #expect(FingerprintComponent.escape("x:\u{301}") == "x\\:\u{301}")
        for raw in ["x:\u{301}", ",\u{301}", "\\\u{301}", "\u{301}:"] {
            #expect(FingerprintComponent.unescape(FingerprintComponent.escape(raw)) == raw)
        }
        let encoded = ActionFingerprint.make("k", [.field("x"), .field("\u{301}y")]).rawValue
        #expect(FingerprintComponent.split(encoded, separator: ":").count == 3)
    }
}
