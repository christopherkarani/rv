import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test(arguments: [
    (
        HookHost.claude,
        "deny-file-env.json",
        FileToolKind.read,
        "/tmp/rv-oracle/.env"
    ),
    (
        HookHost.grok,
        "deny-file-env.json",
        FileToolKind.read,
        "/tmp/rv-oracle/.env"
    ),
    (
        HookHost.cursor,
        "deny-file-ssh.json",
        FileToolKind.read,
        "/tmp/rv-oracle/.ssh/id_ed25519"
    ),
])
func proposedAction_hostFileRequest_isFileNotShell(
    host: HookHost,
    fixture: String,
    kind: FileToolKind,
    path: String
) throws {
    let stdin = try fileHostFixture(host: host, name: fixture)
    let codec = codecForHost(host)
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for \(host.rawValue) \(fixture)")
        return
    }
    guard case .file(_, let file, let cwd, let session) = request else {
        Issue.record("expected HookRequest.file for \(host.rawValue) \(fixture)")
        return
    }
    #expect(file.kind == kind)
    #expect(file.path.rawValue == path)

    let action = codec.proposedAction(from: request)
    #expect(action.supportingCommand == nil)
    guard case .file(let fileAction) = action else {
        Issue.record("expected ProposedAction.file for \(host.rawValue) file request")
        return
    }
    let expected = ActionFingerprint.make(
        host: host,
        session: session,
        cwd: cwd,
        file: file
    )
    #expect(fileAction.fingerprint == expected)
    #expect(action.fingerprint == expected)
    #expect(fileAction.file == file)
    #expect(fileAction.resources.path == file.path.rawValue)
    #expect(fileAction.effects.kinds.isEmpty)
    #expect(fileAction.scope.workingDirectory == cwd)
}

private func codecForHost(_ host: HookHost) -> any HostCodec {
    switch host {
    case .claude:
        return ClaudeHostCodec()
    case .grok:
        return GrokHostCodec()
    case .cursor:
        return CursorHostCodec()
    case .pi, .opencode, .openclaw, .hermes, .codex, .antigravity:
        Issue.record("file-tool codec test is Claude/Grok/Cursor only")
        return ClaudeHostCodec()
    }
}

private func fileHostFixture(host: HookHost, name: String) throws -> String {
    let folder: String
    switch host {
    case .claude:
        folder = "claude"
    case .grok:
        folder = "grok"
    case .cursor:
        folder = "cursor"
    case .pi, .opencode, .openclaw, .hermes, .codex, .antigravity:
        folder = "claude"
    }
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(folder)/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
