import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// Parity lock between the C front door (`Sources/rv-c/rv.c`) and Swift.
/// A host missing from `is_valid_host` silently misses as operator; a host
/// accepted there without its own `render_deny` wire (hook_fallback.c) falls
/// to the generic `{"decision":"deny"}`, which Muse ignores (fail open).
@Suite struct CFrontDoorHostParityTests {
    @Test func isValidHostMatchesEveryHookHost() throws {
        let body = try cFunctionBody(in: "rv.c", named: "static int is_valid_host(")
        let hosts = Set(try captures(of: #"strcmp\(s, "([a-z]+)"\)"#, in: body))
        #expect(hosts == Set(HookHost.allCases.map(\.rawValue)))
        #expect(hosts == Set(HookHost.setupSlotOrder.map(\.rawValue)))
    }

    @Test func museDenyLiteralMatchesSwiftEncoder() throws {
        let body = try cFunctionBody(in: "hook_fallback.c", named: "static int render_deny(")
        let branchStart = try #require(
            body.range(of: #"strcmp(host, "muse") == 0) {"#),
            "render_deny has no muse branch; Muse would get the generic deny it ignores"
        )
        let rest = body[branchStart.upperBound...]
        let branchEnd = try #require(rest.range(of: "\n    } else"), "unterminated muse branch")
        let branch = String(rest[..<branchEnd.lowerBound])

        // The snprintf format is adjacent C literals followed by `msg`.
        let literals = try captures(of: #""((?:[^"\\]|\\.)*)""#, in: branch)
        #expect(!literals.isEmpty, "muse branch must print a reply")
        let template = cUnescape(literals.joined())
        #expect(template.components(separatedBy: "%s").count == 2)
        let reason = "RV daemon is not reachable (dev.rv.evaluate)."
        let cOutput = template.replacingOccurrences(of: "%s", with: reason)
        #expect(Array(cOutput.utf8) == Array(musePermissionDenyJSON(reason: reason).utf8))

        // The branch sets no status or stderr, so it inherits the renderer's
        // initial exit 0 and empty stderr; tie that to Swift's contract.
        #expect(!branch.contains("exit_code"), "Muse deny must exit 0")
        #expect(!branch.contains("out->err"), "Muse deny carries no stderr")
        let renderer = try cFunctionBody(in: "hook_fallback.c", named: "int rv_hook_fallback_render(")
        #expect(renderer.contains("out->exit_code = 0;"))
        #expect(HookHost.muse.denyExitCode == 0)
    }
}

private func cFunctionBody(in file: String, named signature: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/rv-c/\(file)")
    let source = try #require(
        try? String(contentsOf: url, encoding: .utf8),
        "Sources/rv-c/\(file) is missing; C/Swift host parity is unverified"
    )
    let start = try #require(source.range(of: signature), "\(signature) not found in \(file)")
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
