import Testing
@testable import RVIsolation

// Conformance corpus adapted from Varlock's env-spec-parser tests
// (packages/env-spec-parser/test/*.test.ts; MIT License, Copyright (c) 2026 DMNO Inc.).
// Number and boolean coercion cases are left out: rv keeps every value as text.
@Suite("Varlock env-spec grammar")
struct EnvSpecConformanceTests {
    typealias Value = EnvSpec.Value

    struct Case: Sendable, CustomTestStringConvertible {
        var input: String
        /// nil: Varlock refuses to parse the input.
        var expected: Expected?
        var testDescription: String { input.replacingOccurrences(of: "\n", with: "↩") }
    }

    enum Expected: Sendable, Equatable {
        case value(Value?)
        case decorators([EnvSpec.Decorator])
    }

    static func text(_ text: String, _ quote: EnvSpec.Quote? = nil) -> Value { .text(text, quote: quote) }
    static func args(_ values: Value...) -> [EnvSpec.Argument] { values.map { EnvSpec.Argument(key: nil, value: $0) } }
    static func named(_ pairs: KeyValuePairs<String, Value>) -> [EnvSpec.Argument] {
        pairs.map { EnvSpec.Argument(key: $0.key, value: $0.value) }
    }
    static func value(_ input: String, _ expected: Value?) -> Case { Case(input: input, expected: .value(expected)) }
    static func error(_ input: String) -> Case { Case(input: input, expected: nil) }
    static func decorators(_ input: String, _ expected: [EnvSpec.Decorator]) -> Case {
        Case(input: input, expected: .decorators(expected))
    }
    static func flag(_ name: String) -> EnvSpec.Decorator { EnvSpec.Decorator(name: name, form: .flag) }
    static func set(_ name: String, _ value: Value) -> EnvSpec.Decorator { EnvSpec.Decorator(name: name, form: .value(value)) }
    static func bare(_ name: String, _ arguments: [EnvSpec.Argument]) -> EnvSpec.Decorator {
        EnvSpec.Decorator(name: name, form: .call(arguments))
    }

    // values.test.ts: each input is the value in `VAL=<input>`.
    static let valueCases: [Case] = [
        // strings and quotes
        value("", nil),
        value(#""""#, text("", .double)),
        value("unquoted", text("unquoted")),
        value(#"inner"'`quotes"#, text(#"inner"'`quotes"#)),
        value("'squote'", text("squote", .single)),
        value(#""dquote""#, text("dquote", .double)),
        value("`backtick`", text("backtick", .backtick)),
        value(#""this has spaces""#, text("this has spaces", .double)),
        value(#""mixed`quote""#, text("mixed`quote", .double)),
        value(#""escaped\"quote""#, text(#"escaped"quote"#, .double)),
        value("unquoted spaces", text("unquoted spaces")),
        value("  extra-spaces  ", text("extra-spaces")),
        error("'not'escaped'"),
        error(#""not ok"#),
        error(#" "not ok"#),
        // multi-line strings
        value("\"this\nhas\nmultiple\nlines\"", text("this\nhas\nmultiple\nlines", .double)),
        value("\"with\\\"escaped\nquotes\"", text("with\"escaped\nquotes", .double)),
        value("\"with #comments\ninside\" # and after", text("with #comments\ninside", .double)),
        value("\"\"\"triple quotes\nalso work\"\"\"", text("triple quotes\nalso work", .double)),
        value("\"\"\"\n  hello\n\"\"\"", text("\n  hello\n", .double)),
        value("```triple backticks\nalso work```", text("triple backticks\nalso work", .backtick)),
        value("```check `internal` quotes \\```\nare ok```", text("check `internal` quotes ```\nare ok", .backtick)),
        error(#""""triple quotes on one line are not ok""""#),
        error(#""""no end"#),
        error("\"\"\"no end\nagain"),
        // function calls
        value("foo()", .call("foo", [])),
        value("foo( )", .call("foo", [])),
        value(#""foo()""#, text("foo()", .double)),
        value("bad-fn-name()", text("bad-fn-name()")),
        value("0badFn()", text("0badFn()")),
        value("foo(abc,true,123)", .call("foo", args(text("abc"), text("true"), text("123")))),
        value("foo( 1 , 2 , 3 )", .call("foo", args(text("1"), text("2"), text("3")))),
        value(
            #"foo( 'sq' , "dq" , `bt`, nq )"#,
            .call("foo", args(text("sq", .single), text("dq", .double), text("bt", .backtick), text("nq")))),
        value("foo(unq#uoted)", .call("foo", args(text("unq#uoted")))),
        value("foo(key1=foo, key2=bar)", .call("foo", named(["key1": text("foo"), "key2": text("bar")]))),
        value(#"foo(key1=123, key2="\")#")"#, .call("foo", named(["key1": text("123"), "key2": text(#"")#"#, .double)]))),
        // post-comment handling
        value("#comment", nil),
        value(" #comment", nil),
        value("#", nil),
        value("foo#comment", text("foo")),
        value(#""foo" #comment"#, text("foo", .double)),
        value(##""foo#comment"#more"##, text("foo#comment", .double)),
        value("123 # @dec", text("123")),
        value("foo(fn#arg) #post-comment", .call("foo", args(text("fn#arg")))),
        // regex-like strings and paths with slashes
        value("/foo/", text("/foo/")),
        value("/usr/local/bin/", text("/usr/local/bin/")),
        value("foo(/some/path, bar)", .call("foo", args(text("/some/path"), text("bar")))),
        value("foo(path=/some/dir/file.txt)", .call("foo", named(["path": text("/some/dir/file.txt")]))),
        value(#"foo(matches=/^https:\/\//)"#, .call("foo", named(["matches": text(#"/^https:\/\//"#)]))),
        // array and object literal values
        value("[a, b]", .array([text("a"), text("b")])),
        value(#"["a@example.com", "b@example.com"]"#, .array([text("a@example.com", .double), text("b@example.com", .double)])),
        value("[]", .array([])),
        value("[\n  one,\n  two,\n]", .array([text("one"), text("two")])),
        value("[a, ${OTHER}]", .array([text("a"), text("${OTHER}")])),
        value("[a, [b, c], {k=v}]", .array([text("a"), .array([text("b"), text("c")]), .object(named(["k": text("v")]))])),
        value("[a, b] # comment", .array([text("a"), text("b")])),
        value("[\n  one, # first\n  two # last\n]", .array([text("one"), text("two")])),
        value("[color#1, plain]", .array([text("color#1"), text("plain")])),
        value("{k=v, n=2}", .object(named(["k": text("v"), "n": text("2")]))),
        value("{}", .object([])),
        value(
            "{\n  api=https://a.com, # main api\n  docs=https://b.com # docs site\n}",
            .object(named(["api": text("https://a.com"), "docs": text("https://b.com")]))),
        value(
            "{\n  api=https://a.com,\n  # comment\n  docs=https://b.com,\n}",
            .object(named(["api": text("https://a.com"), "docs": text("https://b.com")]))),
        value(#"{"json": "blob"}"#, text(#"{"json": "blob"}"#)),
    ]

    @Test(arguments: valueCases)
    func valueGrammar(_ spec: Case) {
        let parsed = EnvSpec.parse("VAL=" + spec.input)
        switch (parsed, spec.expected) {
        case (.success(let file), .value(let expected)?):
            #expect(file.items.map(\.key) == ["VAL"])
            #expect(file.items.first?.value == expected)
        case (.failure, nil): break
        default: Issue.record("parsed \(parsed), expected \(String(describing: spec.expected))")
        }
    }

    // decorators.test.ts: each input is the comment block above `VAL=`.
    static let decoratorCases: [Case] = [
        // static values
        decorators("# @dec", [flag("dec")]),
        decorators("# @dec=true", [set("dec", text("true"))]),
        decorators("# @dec=foo", [set("dec", text("foo"))]),
        decorators("# @dec=foo#bar", [set("dec", text("foo"))]),
        decorators(#"# @dec="foo""#, [set("dec", text("foo", .double))]),
        decorators(#"# @dec="@#\"()""#, [set("dec", text(#"@#"()"#, .double))]),
        decorators("# @dec=@bar@", [set("dec", text("@bar@"))]),
        // function calls
        decorators("# @dec=decFn()", [set("dec", .call("decFn", []))]),
        decorators(#"# @dec=decFn(arrArg1, "arrArg2")"#, [set("dec", .call("decFn", args(text("arrArg1"), text("arrArg2", .double))))]),
        decorators(#"# @dec=decFn(k1=v1, k2="v2")"#, [set("dec", .call("decFn", named(["k1": text("v1"), "k2": text("v2", .double)])))]),
        decorators("# @enableFoo()", [bare("enableFoo", [])]),
        decorators("# @import(../some/path)", [bare("import", args(text("../some/path")))]),
        // object and array literal values
        decorators("# @sensitive={preventLeaks=false}", [set("sensitive", .object(named(["preventLeaks": text("false")])))]),
        decorators("# @dec=[a, b, c]", [set("dec", .array([text("a"), text("b"), text("c")]))]),
        decorators(
            "# @dec=fn(opts={x=1}, items=[1, 2])",
            [set("dec", .call("fn", named(["opts": .object(named(["x": text("1")])), "items": .array([text("1"), text("2")])])))]),
        // multi-line literals and calls (`#` continuation)
        decorators("# @dec=[\n#   a,\n#   b,\n#   c,\n# ]", [set("dec", .array([text("a"), text("b"), text("c")]))]),
        decorators("# @dec=[\n#   a,\n#   b\n# ]", [set("dec", .array([text("a"), text("b")]))]),
        decorators(
            "# @sensitive={\n#   preventLeaks=false, # leaves the system intentionally\n#   # enabled=false,\n# }",
            [set("sensitive", .object(named(["preventLeaks": text("false")])))]),
        decorators(
            "# @dec=[\n#   VAL1,\n# # COMMENTED_VAL,\n#   VAL3, # post comment\n# ]",
            [set("dec", .array([text("VAL1"), text("VAL3")]))]),
        decorators(
            "# @import(\n#   ./.env.shared,\n#   pick=[\n#     #frontend,\n#     # #legacy,\n#     KEY1, # note\n#   ],\n# )",
            [bare("import", args(text("./.env.shared")) + named(["pick": .array([text("#frontend"), text("KEY1")])]))]),
        decorators(
            "# @import(\n#   ./.env.import,\n#   ITEM1,\n#   ITEM2,\n# )",
            [bare("import", args(text("./.env.import"), text("ITEM1"), text("ITEM2")))]),
        decorators("# @dec=someFn(\n#   arg1,\n#   arg2\n# )", [set("dec", .call("someFn", args(text("arg1"), text("arg2"))))]),
        decorators("# @import(\n#ITEM1,\n#  ITEM2,\n#    ITEM3\n#)", [bare("import", args(text("ITEM1"), text("ITEM2"), text("ITEM3")))]),
        decorators("# @import(\n#   ITEM1\n# ) @required", [bare("import", args(text("ITEM1"))), flag("required")]),
        decorators("# @doSomething(\n# )", [bare("doSomething", [])]),
        error("# @import(\n./.env.import,\n#   ITEM1,\n#   ITEM2,\n# )"),
        decorators(
            "# @import(\n#   ./.env.import,\n# #  ITEM1,\n#   ITEM2,\n# )",
            [bare("import", args(text("./.env.import"), text("ITEM2")))]),
        // regex-like values follow the ordinary value rules
        decorators("# @dec=decFn(matches=/^[A-Z]+$/)", [set("dec", .call("decFn", named(["matches": text("/^[A-Z]+$/")])))]),
        decorators(
            #"# @dec=decFn(matches="^[0-9a-f]{7,40}$")"#,
            [set("dec", .call("decFn", named(["matches": text("^[0-9a-f]{7,40}$", .double)])))]),
        decorators("# @dec=/folder/foo/bar", [set("dec", text("/folder/foo/bar"))]),
        // whitespace
        decorators("#@dec=1", [set("dec", text("1"))]),
        decorators("#\t@dec=1", [set("dec", text("1"))]),
        // errors and weird cases
        error("# @dec="),
        error(#"# @dec=""#),
        error(#"# @dec="foo"#),
        decorators(#"# @dec="`""#, [set("dec", text("`", .double))]),
        decorators(#"# @dec="\"""#, [set("dec", text(#"""#, .double))]),
        decorators(#"# @dec=qu"ote"#, [set("dec", text(#"qu"ote"#))]),
        error(#"# @dec=""""#),
        error("# @dec1@dec2"),
        error("# @"),
        error("# @0badDecorator"),
        // comments and line breaks
        decorators("# comment before\n# @dec1\n# comment after\n#@dec2", [flag("dec1"), flag("dec2")]),
        decorators(
            "# @bool  @email=\"me@example.com\" \t @num=123 ",
            [flag("bool"), set("email", text("me@example.com", .double)), set("num", text("123"))]),
        decorators("# @foo=bar @bool", [set("foo", text("bar")), flag("bool")]),
        decorators("# will be @ignored\n# @dec", [flag("dec")]),
        decorators("# @dec\n", []),
        decorators("# @dec\n# ---", []),
        decorators("# @dec # more comments", [flag("dec")]),
        decorators("# @dec # @ignored", [flag("dec")]),
        // stray text after decorators
        decorators("# @foo blah", [flag("foo")]),
        decorators("# @dec1 extra @dec2 extra", [flag("dec1"), flag("dec2")]),
        decorators(#"# @dec="foo" not commented"#, [set("dec", text("foo", .double))]),
        decorators("# @todo: fix me later", [flag("todo:")]),
    ]

    @Test(arguments: decoratorCases)
    func decoratorGrammar(_ spec: Case) {
        let parsed = EnvSpec.parse(spec.input + "\nVAL=")
        switch (parsed, spec.expected) {
        case (.success(let file), .decorators(let expected)?):
            let item = file.items.first
            let found = (item?.preComments ?? []).flatMap { comment -> [EnvSpec.Decorator] in
                if case .decorators(let decorators) = comment { decorators } else { [] }
            }
            #expect(found == expected)
        case (.failure, nil): break
        default: Issue.record("parsed \(parsed), expected \(String(describing: spec.expected))")
        }
    }

    @Test func unclosedDecoratorLiteralDoesNotSwallowItems() throws {
        let file = try EnvSpec.parse("# @dec=[\nKEY1=v1\nKEY2=v2\nVAL=").get()
        #expect(file.items.map(\.key) == ["KEY1", "KEY2", "VAL"])
    }

    @Test func postCommentCarriesDecorators() throws {
        let file = try EnvSpec.parse("KEY=v # @sensitive @type=string\nOTHER=x # note").get()
        #expect(file.items.first?.value == Self.text("v"))
        #expect(file.items.first?.postComment == .decorators([Self.flag("sensitive"), Self.set("type", Self.text("string"))]))
        #expect(file.items.last?.postComment == .text("note"))
    }

    @Test func exportAndKeyGrammar() throws {
        let file = try EnvSpec.parse("export A=1\nmy.dotted-key=2\n_UNDER=3\nexport=4").get()
        #expect(file.items.map(\.key) == ["A", "my.dotted-key", "_UNDER", "export"])
        #expect(EnvSpec.parse("9BAD=1").failureLine == 1)
    }

    // general.test.ts
    @Test func lineEndingsAndWhitespaceOnlyLines() throws {
        #expect(try EnvSpec.parse("FOO=foo\r\nBAR=bar\r\n").get().items.map(\.key) == ["FOO", "BAR"])
        let spaced = try EnvSpec.parse("  \n\t\nFOO=foo\n   \n  \nBAR=bar\r\n \r\nBAZ=baz\n").get()
        #expect(spaced.items.map(\.key) == ["FOO", "BAR", "BAZ"])
        #expect(try EnvSpec.parse("FOO=foo\nBAR=bar\n   ").get().items.map(\.key) == ["FOO", "BAR"])
        let detached = try EnvSpec.parse("# @required\n   \nFOO=foo\n").get()
        #expect(detached.items.first?.preComments == [])
    }

    @Test func multiLineStringsKeepTheirInterior() throws {
        let file = try EnvSpec.parse("FOO=\"\"\"\nline1\n\n  \nline2\t\n\"\"\"\nBAR=\"line1\n  \nline2\"\n").get()
        #expect(file.items.map(\.value) == [Self.text("\nline1\n\n  \nline2\t\n", .double), Self.text("line1\n  \nline2", .double)])
    }

    // header.test.ts: every comment block before the first item is header.
    @Test func headerBlocksPrecedeTheFirstItem() throws {
        let file = try EnvSpec.parse("""

            # first block
            # @import(../.env)
            # ---
            # second block
            # @defaultRequired

            # attached
            VAL=foo

            # orphan
            # @required

            VAL2=bar
            """).get()
        let blocks = file.nodes.prefix { if case .item = $0 { false } else { true } }.filter {
            if case .block = $0 { true } else { false }
        }
        #expect(blocks.count == 2)
        #expect(file.items.first?.preComments == [.text("attached")])
        #expect(file.items.last?.preComments == [])
    }

    @Test func errorsNameALineAndNoText() {
        let parsed = EnvSpec.parse("A=1\nB=2\nC=\"sk-live-unclosed\nD=4")
        #expect(parsed.failureLine == 3)
    }

    /// Varlock has no depth limit; rv refuses deep nesting rather than overflow the stack.
    @Test func nestingIsBounded() {
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(EnvSpec.parse("VAL=" + deep).failureLine == 1)
        #expect(EnvSpec.parse("# @dec=" + deep + "\nVAL=").failureLine == 1)
        #expect(EnvSpec.parse("VAL=" + String(repeating: "f(", count: 10_000)).failureLine == nil)
    }

    /// A failed nested call or literal is retried by every enclosing level, so
    /// the depth cap alone leaves unclosed `f(x,f(x,...` input exponential.
    @Test(.timeLimit(.minutes(1)), arguments: [
        "VAL=" + String(repeating: "f(x,", count: 64),
        "VAL=" + String(repeating: "[x,", count: 64),
        "# @d=f(x,\n" + String(repeating: "# f(x,\n", count: 63) + "VAL=",
    ])
    func unclosedNestingDoesNotBlowUp(source: String) {
        #expect(EnvSpec.parse(source).failureLine != nil)
    }

    /// Calls as unquoted text are still found when the budget is not spent.
    @Test func closedNestingStillParses() {
        let source = "VAL=" + String(repeating: "f(x,", count: 8) + "y" + String(repeating: ")", count: 8)
        #expect(EnvSpec.parse(source).failureLine == nil)
    }

    /// `${` with no closing brace is scanned once per line, not once per `${`.
    @Test(.timeLimit(.minutes(1)))
    func unclosedInterpolationInAnArrayIsLinear() throws {
        let source = "VAL=[" + String(repeating: "${", count: 200_000)
        let parsed = EnvSpec.parse(source)
        #expect(parsed.failureLine == nil)
        #expect(try parsed.get().items.first?.value == .text(String(source.dropFirst(4)), quote: nil))
    }

    @Test func closedInterpolationInAnArrayStaysOneElement() throws {
        let parsed = try EnvSpec.parse("VAL=[${A},${B C},${D ${E}]").get()
        #expect(parsed.items.first?.value == .array([
            Self.text("${A}"), Self.text("${B C}"), Self.text("${D ${E}"),
        ]))
    }
}

extension Result where Success == EnvSpec.File, Failure == EnvSpec.ParseError {
    fileprivate var failureLine: Int? {
        if case .failure(let error) = self { return error.line }
        return nil
    }
}
