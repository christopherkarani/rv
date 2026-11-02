import Testing
import RVDomain
import RVEngine
@testable import RVHooks

private let codec = ClaudeHostCodec()

private func claudePre(_ tool: String, _ input: String) -> String {
    """
    {"hook_event_name":"PreToolUse","tool_name":"\(tool)","tool_input":\(input)}
    """
}

private func decodedFile(_ stdin: String) -> FileToolAction? {
    guard case .request(let request) = codec.decode(stdin),
          case .file(_, let action, _, _) = request
    else { return nil }
    return action
}

@Test(arguments: [
    ("Grep", #"{"pattern":"x","path":"/Users/me/.ssh/id_rsa"}"#, "/Users/me/.ssh/id_rsa"),
    ("Grep", #"{"pattern":"x","path":"/p","glob":".env*"}"#, "/p/.env"),
    ("Grep", #"{"pattern":"x","glob":"**/.env.*"}"#, "**/.env.*"),
    ("Grep", #"{"pattern":"x","path":"/p","glob":"*.{js,npmrc}"}"#, "/p/.npmrc"),
    ("Grep", #"{"pattern":"x","path":"/p","glob":".ssh/*"}"#, "/p/.ssh/*"),
    ("Glob", #"{"pattern":"**/.env*"}"#, ".env"),
    ("Glob", #"{"pattern":"**/id_rsa","path":"/h"}"#, "/h/**/id_rsa"),
    ("Glob", #"{"pattern":"*","path":"/h/.aws"}"#, "/h/.aws"),
])
func claudeSearchTools_secretTargetsDecodeToReadAction(
    tool: String, input: String, path: String
) {
    let action = decodedFile(claudePre(tool, input))
    #expect(action?.kind == .read)
    #expect(action?.path.rawValue == path)
    if let action {
        #expect(SecretPathCatalog.dayOne.firstMatch(of: action.path.rawValue) != nil)
    }
}

@Test(arguments: [
    ("Grep", #"{"pattern":"TODO","path":"/p/src"}"#, "/p/src"),
    ("Grep", #"{"pattern":"TODO","path":"/p/src","glob":"*.swift"}"#, "/p/src"),
    ("Glob", #"{"pattern":"**/*.swift","path":"/p"}"#, "/p"),
    ("Glob", #"{"pattern":"**/*","path":"/p"}"#, "/p"),
])
func claudeSearchTools_benignTargetsKeepExplicitPath(tool: String, input: String, path: String) {
    let action = decodedFile(claudePre(tool, input))
    #expect(action?.kind == .read)
    #expect(action?.path.rawValue == path)
}

@Test(arguments: [
    ("Grep", #"{"pattern":"TODO"}"#),
    ("Grep", #"{"pattern":"TODO","glob":"*.swift"}"#),
    ("Glob", #"{"pattern":"**/*.swift"}"#),
])
func claudeSearchTools_cwdWideBenignSearchIsForeign(tool: String, input: String) {
    #expect(codec.decode(claudePre(tool, input)) == .foreign)
}

@Test(arguments: [
    ("NotebookEdit", #"{"notebook_path":"/p/a.ipynb","new_source":"x"}"#, "/p/a.ipynb"),
    ("MultiEdit", #"{"file_path":"/p/.env","edits":[]}"#, "/p/.env"),
])
func claudeEditTools_decodeToEditAction(tool: String, input: String, path: String) {
    let action = decodedFile(claudePre(tool, input))
    #expect(action?.kind == .edit)
    #expect(action?.path.rawValue == path)
}

@Test func claudeEditTools_missingPathDecodesToEmptyPath() {
    #expect(decodedFile(claudePre("NotebookEdit", "{}"))?.path.isEmpty == true)
    #expect(decodedFile(claudePre("MultiEdit", "{}"))?.path.isEmpty == true)
}

@Test(arguments: ["TodoWrite", "WebFetch", "WebSearch", "Task"])
func claudeUnrelatedToolsStayForeign(tool: String) {
    #expect(codec.decode(claudePre(tool, #"{"path":"/p/.env"}"#)) == .foreign)
}

// End to end through the real catalog gate.
private func gateWire(_ stdin: String) async -> HookWire {
    await hookWire(
        host: .claude,
        stdin: stdin,
        world: hookWorld(
            evaluate: { _, _ in EvaluationResult(outcome: .plain) },
            evaluateFile: { action, _ in evaluateFileTool(action) }
        )
    )
}

@Test func claudeGrepOnSshKey_isDeniedByRealGate() async {
    let wire = await gateWire(claudePre("Grep", #"{"pattern":"x","path":"~/.ssh/id_rsa","output_mode":"content"}"#))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("core.secrets"))
}

@Test func claudeGrepWithSecretGlob_isDeniedByRealGate() async {
    let wire = await gateWire(claudePre("Grep", #"{"pattern":"x","path":"/p","glob":".env*"}"#))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
}

@Test func claudeBenignGrep_isAllowedByRealGate() async {
    let wire = await gateWire(claudePre("Grep", #"{"pattern":"TODO","path":"/p/src"}"#))
    #expect(wire.stdout.isEmpty)
    #expect(wire.exitCode == 0)
}
