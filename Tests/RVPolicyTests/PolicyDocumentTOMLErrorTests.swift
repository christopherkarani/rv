import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Every refusal names the line, the key and the fix (F1).
struct PolicyDocumentTOMLErrorTests {
    private func problem(_ source: String) -> PolicyDocumentProblem? {
        do {
            _ = try PolicyDocumentTOML.parse(source)
            Issue.record("expected a parse error")
            return nil
        } catch let error as PolicyDocumentError {
            return error.problem
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func badVerdict_namesLineKeyAndChoices() throws {
        let found = try #require(problem("""
        schema_version = 1

        [[rule]]
        id = "typed.git:x"
        verdict = "block"
        predicate = "gitPush"
        """))
        #expect(found.line == 5)
        #expect(found.key == "verdict")
        #expect(found.problem == #"verdict "block" is not a verdict"#)
        #expect(found.fix == "use one of: deny, ask, allow")
        #expect(found.lines(file: "c.toml") == [
            #"✕ c.toml:5  verdict "block" is not a verdict"#,
            "→ use one of: deny, ask, allow",
        ])
    }

    @Test func misspelledPredicate_suggestsTheSpelling() throws {
        let found = try #require(problem("""
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitpush"
        """))
        #expect(found.line == 5)
        #expect(found.key == "predicate")
        #expect(found.fix == "did you mean gitPush?")
    }

    @Test func unknownRuleKey_suggestsNearestKey() throws {
        let found = try #require(problem("""
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        brnach = "main"
        """))
        #expect(found.line == 6)
        #expect(found.key == "brnach")
        #expect(found.fix == "did you mean branch?")
    }

    @Test func missingSchemaVersion_hasNoLineButAFix() throws {
        let found = try #require(problem("""
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        """))
        #expect(found.line == nil)
        #expect(found.key == "schema_version")
        #expect(found.fix == "add schema_version = 1 as the first line")
        #expect(found.lines(file: "p.toml") == ["✕ p.toml  schema_version is missing", "→ add schema_version = 1 as the first line"])
    }

    @Test func missingVerdict_pointsAtTheRuleHeader() throws {
        let found = try #require(problem("""
        schema_version = 1

        [[rule]]
        id = "typed.git:x"
        predicate = "gitPush"
        """))
        #expect(found.line == 3)
        #expect(found.key == "verdict")
    }

    @Test func duplicateID_namesBothLines() throws {
        let found = try #require(problem("""
        schema_version = 1
        [[rule]]
        id = "typed.git:same"
        verdict = "deny"
        predicate = "gitReset"
        [[rule]]
        id = "typed.git:same"
        verdict = "ask"
        predicate = "gitClean"
        """))
        #expect(found.line == 6)
        #expect(found.problem.contains("first rule on line 2"))
    }

    @Test func badTableHeader_saysUseDoubleBrackets() throws {
        let found = try #require(problem("""
        schema_version = 1
        [rule]
        """))
        #expect(found.line == 2)
        #expect(found.fix == "write the table header as [[rule]]")
    }

    @Test func valueInProblem_isEscapedAndCapped() throws {
        let found = try #require(problem("""
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "\u{1B}[2J\(String(repeating: "x", count: 80))"
        predicate = "gitPush"
        """))
        #expect(found.problem.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(found.problem.count < 80)
    }

    @Test func commentAfterValue_isFine() throws {
        let document = try PolicyDocumentTOML.parse("""
        schema_version = 1   # the only version
        [[rule]]
        id = "typed.git:x" # why
        verdict = "deny"   # stop it
        predicate = "gitPush"
        branch = "main"    # the shared one
        english = "keep # this"
        """)
        #expect(document.rules.count == 1)
        #expect(document.rules[0].verdict == .deny)
        #expect(document.rules[0].predicate == .gitPush(force: .any, branch: "main"))
        #expect(document.rules[0].english == "keep # this")
    }

    @Test func valueAndRest_cases() {
        func split(_ text: String) -> (String, String?) {
            let found = PolicyDocumentTOML.valueAndRest(text)
            return (found.value, found.rest)
        }
        #expect(split(#""deny" # x"#) == (#""deny""#, nil))
        #expect(split(#""a # b""#) == (#""a # b""#, nil))
        #expect(split(#""a\" # b" # c"#) == (#""a\" # b""#, nil))
        #expect(split("1 # v") == ("1", nil))
        #expect(split("feat#1") == ("feat#1", nil))
        #expect(split(#"[".env"] # x"#) == (#"[".env"]"#, nil))
        #expect(split(#"[".env"] # see ] below"#) == (#"[".env"]"#, nil))
        #expect(split(#"["a]b"] # x"#) == (#"["a]b"]"#, nil))
        #expect(split(#""deny" x"#) == (#""deny""#, "x"))
        #expect(split("true trailing") == ("true", "trailing"))
        #expect(split("# only comment") == ("", nil))
    }

    /// Review of #669: words after a value used to be kept or dropped
    /// silently. They are an error with the line and the fix.
    @Test(arguments: [
        (#"branch = "main" trailing"#, "branch", #""trailing" after the value is not a comment"#),
        ("branch = # only comment", "branch", "branch has no value"),
        ("recursive = true trailing", "recursive", #""trailing" after the value is not a comment"#),
    ])
    func junkAfterAValue_isLocated(line: String, key: String, message: String) throws {
        let found = try #require(problem("""
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        \(line)
        """))
        #expect(found.line == 6)
        #expect(found.key == key)
        #expect(found.problem == message)
        #expect(found.fix.isEmpty == false)
    }

    @Test func arrayWithBracketInItsComment_parses() throws {
        let document = try PolicyDocumentTOML.parse("""
        schema_version = 1
        secret.allow_paths = [".env", "fixtures/key.pem"] # not ] these
        """)
        #expect(document.allowPaths == [".env", "fixtures/key.pem"])
    }

    @Test func ruleHeaderWithAComment_isARule() throws {
        let document = try PolicyDocumentTOML.parse("""
        schema_version = 1
        [[rule]] # keep main safe
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        branch = "main"
        """)
        #expect(document.rules.count == 1)
        #expect(document.rules.first?.predicate == .gitPush(force: .any, branch: "main"))
    }

    @Test func layerFailure_carriesTheLocatedProblem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-toml-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TypedRuleStore(baseDirectory: directory)
        #expect(store.machineDocumentFailure() == nil)
        try "schema_version = 1\n[[rule]]\nid = \"typed.git:x\"\nverdict = \"block\"\npredicate = \"gitPush\"\n"
            .write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let failure = try #require(store.machineDocumentFailure())
        #expect(failure.file == store.machineFileURL)
        guard case .parse(let located) = failure.reason else {
            Issue.record("expected a parse failure, got \(failure.reason)")
            return
        }
        #expect(located.line == 4)
        #expect(located.key == "verdict")
    }
}
