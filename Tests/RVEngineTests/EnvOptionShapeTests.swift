import Testing
@testable import RVEngine

/// `env` option words: GNU long options match by unambiguous prefix, value
/// options take the next word, and anything else is unknown (fail closed).
@Suite("env option shape")
struct EnvOptionShapeTests {
    @Test(arguments: [
        ("-i", EnvOptionShape.flag),
        ("-", .flag),
        ("-0v", .flag),
        ("-uFOO", .flag),
        ("--unset=FOO", .flag),
        ("--ignore-environment", .flag),
        ("--ig", .unknown),
        ("--i", .unknown),
        ("-u", .valueNext(chdir: false)),
        ("-a", .valueNext(chdir: false)),
        ("-iu", .valueNext(chdir: false)),
        ("-0a", .valueNext(chdir: false)),
        ("--u", .valueNext(chdir: false)),
        ("--un", .valueNext(chdir: false)),
        ("--a", .valueNext(chdir: false)),
        ("--argv0", .valueNext(chdir: false)),
        ("-C", .valueNext(chdir: true)),
        ("--ch", .valueNext(chdir: true)),
        ("-Csrc", .chdirAttached("src")),
        ("--chdir=src", .chdirAttached("src")),
        ("-S", .splitString),
        ("--sp", .splitString),
        ("--bogus", .unknown),
        ("--", .unknown),
        ("-x", .unknown),
    ])
    func shape(_ option: String, _ expected: EnvOptionShape) {
        #expect(envOptionShape(option) == expected, "\(option)")
    }

    @Test func sudoArgv0FlagTakesValue() {
        #expect(sudoFlagTakesValue("-a"))
    }
}
