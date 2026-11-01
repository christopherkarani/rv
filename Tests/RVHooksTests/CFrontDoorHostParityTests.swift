import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// Parity lock between the C front door (`Sources/rv-c/rv.c`) and Swift.
/// A host missing from `is_valid_host` silently misses as operator; a host
/// accepted there without its own `deny_hook` wire falls to the generic
/// `{"decision":"deny"}`, which Muse ignores (fail open).
@Suite struct CFrontDoorHostParityTests {
    @Test func isValidHostMatchesEveryHookHost() throws {
        let body = try cFunctionBody(named: "static int is_valid_host(")
        let hosts = Set(try captures(of: #"strcmp\(s, "([a-z]+)"\)"#, in: body))
        #expect(hosts == Set(HookHost.allCases.map(\.rawValue)))
        #expect(hosts == Set(HookHost.setupSlotOrder.map(\.rawValue)))
    }

    @Test func museDenyLiteralMatchesSwiftEncoder() throws {
        let body = try cFunctionBody(named: "static void deny_hook(")
        let reason = try #require(
            try captures(of: #"const char \*reason = "([^"\\]*)";"#, in: body).first,
            "deny_hook reason constant not found"
        )
        let branchStart = try #require(
            body.range(of: #"strcmp(host, "muse") == 0) {"#),
            "deny_hook has no muse branch; Muse would get the generic deny it ignores"
        )
        let rest = body[branchStart.upperBound...]
        let branchEnd = try #require(rest.range(of: "\n    }"), "unterminated muse branch")
        let branch = String(rest[..<branchEnd.lowerBound])

        let literals = try captures(of: #"printf\("((?:[^"\\]|\\.)*)", reason\);"#, in: branch)
        #expect(literals.count == 1, "muse branch must print exactly one reply")
        // The branch inherits deny_hook's default status; tie it to Swift's.
        #expect(body.contains("int status = \(HookHost.muse.denyExitCode);"))
        #expect(!branch.contains("status"), "Muse deny must exit 0")
        #expect(!branch.contains("stderr"), "Muse deny carries no stderr")
        let literal = try #require(literals.first)
        let template = cUnescape(literal)
        #expect(template.components(separatedBy: "%s").count == 2)
        let cOutput = template.replacingOccurrences(of: "%s", with: reason)
        #expect(Array(cOutput.utf8) == Array(musePermissionDenyJSON(reason: reason).utf8))
    }
}

private func cFunctionBody(named signature: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/rv-c/rv.c")
    let source = try #require(
        try? String(contentsOf: url, encoding: .utf8),
        "Sources/rv-c/rv.c is missing; C/Swift host parity is unverified"
    )
    let start = try #require(source.range(of: signature), "\(signature) not found in rv.c")
    let tail = source[start.lowerBound...]
    let end = try #require(tail.range(of: "\n}\n"), "\(signature) body is unterminated")
    return String(tail[..<end.upperBound])
}

private func captures(of pattern: String, in text: String) throws -> [String] {
    let regex = try Regex(pattern)
    return text.matches(of: regex).compactMap { match in
        match.output[1].substring.map(String.init)
    }
}

/// The escapes rv.c's printf literals use: `\"`, `\\`, `\n`.
private func cUnescape(_ literal: String) -> String {
    var output = ""
    var escaping = false
    for character in literal {
        if escaping {
            switch character {
            case "n": output.append("\n")
            case "t": output.append("\t")
            default: output.append(character)
            }
            escaping = false
        } else if character == "\\" {
            escaping = true
        } else {
            output.append(character)
        }
    }
    return output
}
