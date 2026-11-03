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

    // MARK: exhaustive adversarial injectivity

    /// Scalar identity. `String ==` is canonical equivalence, which would
    /// hide a collision between scalar-distinct encodings; compare scalars.
    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    /// The text after `kind:`, cut on scalars: `String.dropFirst` counts
    /// `Character`s, and `:` plus a combining mark is one.
    private func scalarsAfter(kind: String, in raw: String) -> String? {
        let encoded = Array(raw.unicodeScalars)
        let prefix = Array("\(kind):".unicodeScalars)
        guard encoded.starts(with: prefix) else { return nil }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: encoded.dropFirst(prefix.count))
        return String(rest)
    }

    /// Structural scalars, combining marks, CRLF, ZWJ sequences, and the
    /// empty-list token's own characters.
    private static let atoms: [String] = [
        ":", ",", "\\", "\u{301}", "\r\n", "\u{200D}", "\u{1F468}\u{200D}\u{1F469}", "[", "]", "a",
    ]

    /// "" plus every one- and two-atom concatenation, plus kind-like and
    /// empty-list-token lookalikes.
    private static let components: [String] = {
        var pool = [""] + atoms
        for left in atoms { for right in atoms { pool.append(left + right) } }
        pool += ["\\[]", "\\\\[]", "[]", "k", "shell", "k:a", "a\\"]
        var seen = Set<[UInt32]>()
        return pool.filter { seen.insert($0.unicodeScalars.map(\.value)).inserted }
    }()

    private static let small: [String] = ["", "a", ":", ",", "\\", "\u{301}", "\\[]", "[]", "\r\n", "a\\"]

    private static func lists(of pool: [String], upTo length: Int) -> [[String]] {
        var all: [[String]] = [[]]
        var frontier: [[String]] = [[]]
        for _ in 0..<length {
            frontier = frontier.flatMap { prefix in pool.map { prefix + [$0] } }
            all += frontier
        }
        return all
    }

    /// A one-item list spells exactly like a field. That alias is the only
    /// one the encoding allows, and a kind uses one shape per slot.
    private func aliasNormalized(_ segments: [FingerprintSegment]) -> [FingerprintSegment] {
        segments.map { segment in
            if case .list(let items) = segment, items.count == 1 { return .field(items[0]) }
            return segment
        }
    }

    private func adversarialSegmentArrays() -> [[FingerprintSegment]] {
        let components = Self.components
        let small = Self.small
        let smallLists = Self.lists(of: small, upTo: 3).map(FingerprintSegment.list)
        let shortLists = Self.lists(of: small, upTo: 2).map(FingerprintSegment.list)
        var arrays: [[FingerprintSegment]] = [[]]
        arrays += components.map { [.field($0)] }
        arrays += smallLists.map { [$0] }
        for left in components { for right in components { arrays.append([.field(left), .field(right)]) } }
        for field in small {
            for list in shortLists {
                arrays.append([.field(field), list])
                arrays.append([list, .field(field)])
            }
        }
        for left in shortLists { for right in shortLists { arrays.append([left, right]) } }
        for first in small { for second in small { for third in small {
            arrays.append([.field(first), .field(second), .field(third)])
        } } }
        return arrays
    }

    @Test func make_isInjectiveOverAdversarialSegmentArrays() {
        var seen: [[UInt32]: [FingerprintSegment]] = [:]
        var collisions: [String] = []
        for segments in adversarialSegmentArrays() {
            let key = scalars(ActionFingerprint.make("k", segments).rawValue)
            if let previous = seen[key] {
                if aliasNormalized(previous) != aliasNormalized(segments) {
                    collisions.append("\(previous) == \(segments)")
                }
            } else {
                seen[key] = segments
            }
        }
        #expect(seen.count > 20_000)
        #expect(collisions.isEmpty, "\(collisions.prefix(3))")
    }

    @Test func fieldsDecodeBackThroughSplitAndUnescape() {
        let kind = "egress"
        var checked = 0
        var failures: [String] = []
        func decode(_ fields: [String]) -> [String]? {
            let raw = ActionFingerprint.make(kind, fields.map { .field($0) }).rawValue
            guard let rest = scalarsAfter(kind: kind, in: raw) else { return nil }
            let parts = FingerprintComponent.split(rest, separator: ":")
            let decoded = parts.compactMap(FingerprintComponent.unescape)
            return decoded.count == parts.count ? decoded : nil
        }
        func check(_ fields: [String]) {
            checked += 1
            let decoded = decode(fields)
            if decoded.map({ $0.map(scalars) }) != fields.map(scalars) { failures.append("\(fields)") }
        }
        for first in Self.components {
            check([first])
            for second in Self.components { check([first, second]) }
        }
        for first in Self.small { for second in Self.small { for third in Self.small {
            check([first, second, third])
        } } }
        #expect(checked > 12_000)
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    @Test func listItemsDecodeBackAndEmptyListNeverDecodes() {
        var checked = 0
        var failures: [String] = []
        for items in Self.lists(of: Self.small, upTo: 3) {
            let encoded = ActionFingerprint.make("k", [.list(items)]).rawValue
            let segment = FingerprintComponent.split(scalarsAfter(kind: "k", in: encoded) ?? "", separator: ":")
            guard segment.count == 1 else { failures.append("\(items) segments=\(segment.count)"); continue }
            checked += 1
            if items.isEmpty {
                // `\[]` is not an escape `escape` emits; no reader accepts it as items.
                if FingerprintComponent.split(segment[0], separator: ",").compactMap(FingerprintComponent.unescape).isEmpty == false {
                    failures.append("empty list decoded")
                }
                continue
            }
            let parts = FingerprintComponent.split(segment[0], separator: ",")
            let decoded = parts.compactMap(FingerprintComponent.unescape)
            if decoded.count != parts.count || decoded.map(scalars) != items.map(scalars) {
                failures.append("\(items)")
            }
        }
        #expect(checked == 1 + 10 + 100 + 1000)
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    @Test func emptyListTokenIsNeverProducedByEscaping() {
        let token = ActionFingerprint.make("k", [.list([])]).rawValue
        #expect(token == "k:\\[]")
        for component in Self.components {
            #expect(scalars(FingerprintComponent.escape(component)) != scalars("\\[]"))
            #expect(scalars(ActionFingerprint.make("k", [.field(component)]).rawValue) != scalars(token))
        }
        #expect(FingerprintComponent.unescape("\\[]") == nil)
    }

    /// `kind` is the one unescaped slot, and a host door passes
    /// `host.rawValue` as the kind. A host spelled like another producer's
    /// namespace would let the host door forge that producer's fingerprints.
    @Test func hostDoorKinds_areEscapeFreeAndOutsideOtherNamespaces() {
        let reserved: Set<String> = ["shell", "file", "runtime", "egress", "secret-request"]
        for host in HookHost.allCases {
            #expect(FingerprintComponent.escape(host.rawValue) == host.rawValue)
            #expect(reserved.contains(host.rawValue) == false)
        }
    }
}
