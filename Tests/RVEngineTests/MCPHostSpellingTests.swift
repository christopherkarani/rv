import Foundation
import RVDomain
import Testing
@testable import RVEngine

/// A command the guard must still catch when one word is spelled a way a
/// POSIX or zsh shell resolves to the same word (an empty quote, a backslash,
/// an ANSI-C escape, a brace or glob, a variable or substitution), or the
/// words are separated by something other than a plain space. `knownIssue`
/// marks a residual the guard does not yet catch (also in the README limits).
struct SpellCase: CustomStringConvertible, Sendable {
    let command: String
    let knownIssue: String?
    var description: String { knownIssue == nil ? command : command + "  [known: \(knownIssue!)]" }
}

/// Spelling transforms and dynamic resolution are judged by what a word can
/// produce, not by its literal text. The canonical payloads are a real host
/// mutation (`claude mcp add`) and the `mcp install` installer behind an
/// unknown wrapper; each must still ask under every spelling the shell
/// resolves to it, bare and behind one wrapper.
/// Two hex digits of a lowercase letter (`c` -> `63`); letters are one byte
/// above 0x60, so always two digits.
private func hex(_ c: Character) -> String { String(Int(c.asciiValue ?? 63), radix: 16) }
/// Four hex digits, for `\uXXXX`.
private func hex4(_ c: Character) -> String {
    let h = hex(c)
    return String(repeating: "0", count: max(0, 4 - h.count)) + h
}
/// Up to three octal digits, for `\NNN`.
private func octal(_ c: Character) -> String { String(Int(c.asciiValue ?? 63), radix: 8) }
/// The letter one code point below `c`, for a `{d..e}` range.
private func prior(_ c: Character) -> Character { Character(UnicodeScalar((c.asciiValue ?? 63) - 1)) }
/// Single-quote a line for a wrapper that re-runs it as a string.
private func shQuoted(_ line: String) -> String {
    "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
/// The installer's host word (`mcp`) given as a value rv cannot read — a
/// documented residual: asking there would fire on every `$PM install`. A
/// dynamic subcommand after a literal `mcp` asks.
private func installerDynamicIsAResidual(payload: Int, position: Int, dynamic: Bool) -> Bool {
    payload == 1 && dynamic && position == 1
}

@Suite("MCP host spelling and dynamic resolution")
struct MCPHostSpellingTests {
    /// `claude mcp add evil -- x` and `chronic mcp install srv`, by word.
    static let payloads: [[String]] = [
        ["claude", "mcp", "add", "evil", "--", "x"],
        ["chronic", "mcp", "install", "srv"],
    ]

    /// A one-word rewrite the shell resolves back to `word`; nil when it does
    /// not apply (too short). `dynamic` transforms stand for a value rv cannot
    /// read.
    static let transforms: [(name: String, dynamic: Bool, apply: @Sendable (String) -> String?)] = [
        ("single-whole", false, { "'\($0)'" }),
        ("double-whole", false, { "\"\($0)\"" }),
        ("single-first", false, { w in w.count >= 2 ? "'\(w.first!)'\(w.dropFirst())" : nil }),
        ("empty-single", false, { w in w.count >= 2 ? "\(w.first!)''\(w.dropFirst())" : nil }),
        ("empty-double", false, { w in w.count >= 2 ? "\(w.first!)\"\"\(w.dropFirst())" : nil }),
        ("backslash-letter", false, { w in w.count >= 2 ? "\(w.first!)\\\(w.dropFirst())" : nil }),
        ("line-continuation", false, { w in w.count >= 2 ? "\(w.first!)\\\n\(w.dropFirst())" : nil }),
        ("ansi-hex", false, { w in w.count >= 2 ? "$'\\x\(hex(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-octal", false, { w in w.count >= 2 ? "$'\\\(octal(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-unicode", false, { w in w.count >= 2 ? "$'\\u\(hex4(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-whole", false, { "$'\($0)'" }),
        ("brace-alt", false, { w in w.count >= 3 ? "{\(w),zzqx}" : nil }),
        ("brace-range", false, { w in w.count >= 3 ? "\(w.dropLast()){\(prior(w.last!))..\(w.last!)}" : nil }),
        ("glob-question", false, { w in w.count >= 3 ? "\(w.first!)?\(w.dropFirst(2))" : nil }),
        ("glob-class", false, { w in w.count >= 3 ? "\(w.first!)[\(Array(w)[1])]\(w.dropFirst(2))" : nil }),
        ("glob-star", false, { w in w.count >= 3 ? "\(w.first!)*\(w.last!)" : nil }),
        ("var", true, { _ in "$HOSTSPELLW" }),
        ("var-default", true, { "${HOSTSPELLW:-\($0)}" }),
        ("cmdsub", true, { "$(printf %s \($0))" }),
        ("backtick", true, { "`printf %s \($0)`" }),
    ]

    static let wrappers: [@Sendable (String) -> String] = [
        { $0 },
        { "sh -c \(shQuoted($0))" },
        { "watch \(shQuoted($0))" },
        { "echo \(shQuoted($0)) | sh" },
        { "stdbuf -o0 \($0)" },
    ]

    static let spellingCases: [SpellCase] = {
        var cases: [SpellCase] = []
        for (payloadIndex, payload) in payloads.enumerated() {
            for position in payload.indices {
                for transform in transforms {
                    guard let spelled = transform.apply(payload[position]) else { continue }
                    var words = payload
                    words[position] = spelled
                    let line = words.joined(separator: " ")
                    // A dynamic value at the installer's group or subcommand
                    // is a residual the guard cannot resolve, bare or wrapped:
                    // every wrapper re-runs the same unresolved words.
                    let known = installerDynamicIsAResidual(
                        payload: payloadIndex, position: position, dynamic: transform.dynamic)
                        ? "mcp install installer: a value rv cannot read at the host position"
                        : nil
                    for wrap in wrappers {
                        cases.append(SpellCase(command: wrap(line), knownIssue: known))
                    }
                }
            }
            // Separators other than a plain space, applied across the line.
            for joiner in ["\t", "   "] {
                cases.append(SpellCase(command: payload.joined(separator: joiner), knownIssue: nil))
            }
            // `$IFS` splits words where rv's tokenizer sees none (`$IFS''`
            // ends the name without adding a word), bare and wrapped.
            for joiner in ["$IFS ", "${IFS}", "$IFS''"] {
                let line = payload.joined(separator: joiner)
                for wrap in wrappers {
                    cases.append(SpellCase(command: wrap(line), knownIssue: nil))
                }
            }
        }
        return cases
    }()

    @Test("every spelling of a host mutation still asks", arguments: spellingCases)
    func spellingStillAsks(_ item: SpellCase) {
        if let reason = item.knownIssue {
            withKnownIssue("\(reason)") {
                #expect(judgeSpelling(item.command), "\(item.command)")
            }
        } else {
            #expect(judgeSpelling(item.command), "\(item.command)")
        }
    }

    /// The same transforms on commands that name no host and no `mcp` never
    /// fire the guard: guard-on reads exactly like guard-off.
    static let lookAlikes: [[String]] = [
        ["git", "commit", "-m", "update-docs"],
        ["ls", "-la", "src"],
        ["npm", "install", "lodash"],
        ["make", "install"],
    ]

    static let mirrorCases: [SpellCase] = {
        var cases: [SpellCase] = []
        for payload in lookAlikes {
            for position in payload.indices {
                for transform in transforms {
                    guard let spelled = transform.apply(payload[position]) else { continue }
                    var words = payload
                    words[position] = spelled
                    cases.append(SpellCase(command: words.joined(separator: " "), knownIssue: nil))
                }
            }
        }
        return cases
    }()

    @Test("spellings of a look-alike never fire the guard", arguments: mirrorCases)
    func lookAlikeNeverAsks(_ item: SpellCase) {
        #expect(judgeSpelling(item.command) == false, "\(item.command)")
    }
}

/// The MCP guard's verdict on `command` in isolation: true asks.
private func judgeSpelling(_ command: String) -> Bool {
    var reads = HostTextReads()
    let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
    return mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context, reads: &reads)
}
