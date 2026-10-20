import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

private func touchedSession(_ raw: String) -> SessionID {
    SessionID(validating: raw)!
}

private func touchedWorkspace(_ url: URL) -> WorkingDirectory {
    WorkingDirectory(rawValue: url.path)!
}

private func touchedTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-touched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("SessionTouchedStore")
struct SessionTouchedStoreTests {
    @Test func emptyLookup() {
        let store = SessionTouchedStore()
        #expect(store.lookup(session: touchedSession("s"), workspace: nil) == [])
    }

    @Test func recordAndLookupFormatsTrainingPaths() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: [dir.appendingPathComponent("dist/bundle.js").path], session: touchedSession("s"), workspace: ws)
        #expect(store.lookup(session: touchedSession("s"), workspace: ws) == ["./dist/", "./dist/bundle.js"])
    }

    @Test func relativeInputNormalizes() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: ["./a/b/c.txt"], session: touchedSession("s"), workspace: ws)
        #expect(store.lookup(session: touchedSession("s"), workspace: ws) == ["./a/", "./a/b/", "./a/b/c.txt"])
    }

    @Test func dirInputKeepsTrailingSlash() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: [dir.path + "/out/"], session: touchedSession("s"), workspace: ws)
        #expect(store.lookup(session: touchedSession("s"), workspace: ws) == ["./out/"])
    }

    @Test func outsideWorkspaceKeepsBasenameOnly() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: ["/etc/passwd", dir.path + "/../escape.txt"], session: touchedSession("s"), workspace: ws)
        #expect(store.lookup(session: touchedSession("s"), workspace: ws) == ["./escape.txt", "./passwd"])
    }

    @Test func ttlExpiry() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(paths: ["./a.txt"], session: touchedSession("s"), workspace: ws, now: base)
        #expect(store.lookup(session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(29 * 60)) == ["./a.txt"])
        #expect(store.lookup(session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(31 * 60)) == [])
    }

    @Test func retouchRefreshesTTL() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(paths: ["./a.txt"], session: touchedSession("s"), workspace: ws, now: base)
        store.record(paths: ["./b.txt"], session: touchedSession("s"), workspace: ws, now: base)
        store.record(paths: ["./a.txt"], session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(29 * 60))
        let got = store.lookup(session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(40 * 60))
        #expect(got == ["./a.txt"])
    }

    @Test func capEvictsOldest() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        for i in 0..<205 {
            store.record(paths: ["./f\(i).txt"], session: touchedSession("s"), workspace: ws)
        }
        #expect(store.entryCount(session: touchedSession("s"), workspace: ws) == 200)
    }

    @Test func maxEightPrefersMostRecentDirs() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<10 {
            let name = String(format: "d%02d", i)
            store.record(paths: ["./\(name)/f.txt"], session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(Double(i)))
        }
        let want = (2..<10).map { String(format: "./d%02d/", $0) }
        #expect(store.lookup(session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(100)) == want)
    }

    @Test func dirsWinOverNewerFiles() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(paths: ["./old/f.txt"], session: touchedSession("s"), workspace: ws, now: base)
        for i in 1...9 {
            store.record(paths: ["./f\(i).txt"], session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(Double(i)))
        }
        let got = store.lookup(session: touchedSession("s"), workspace: ws, now: base.addingTimeInterval(100))
        #expect(got.count == 8)
        #expect(got.contains("./old/"))
        #expect(got.contains("./f9.txt"))
        #expect(got.contains("./f1.txt") == false)
        #expect(got.contains("./f2.txt") == false)
    }

    @Test func workspaceIsolation() throws {
        let first = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: second) }
        let store = SessionTouchedStore()
        store.record(paths: ["./a.txt"], session: touchedSession("s"), workspace: touchedWorkspace(first))
        #expect(store.lookup(session: touchedSession("s"), workspace: touchedWorkspace(first)) == ["./a.txt"])
        #expect(store.lookup(session: touchedSession("s"), workspace: touchedWorkspace(second)) == [])
    }

    @Test func sessionIsolation() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: ["./a.txt"], session: touchedSession("a"), workspace: ws)
        #expect(store.lookup(session: touchedSession("a"), workspace: ws) == ["./a.txt"])
        #expect(store.lookup(session: touchedSession("b"), workspace: ws) == [])
    }

    @Test func noSessionKeysOnWorkspaceAlone() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: ["./a.txt"], session: nil, workspace: ws)
        #expect(store.lookup(session: nil, workspace: ws) == ["./a.txt"])
        #expect(store.lookup(session: touchedSession("s"), workspace: ws) == [])
    }
}

@Suite("SessionTouched judge context")
struct SessionTouchedJudgeContextTests {
    @Test func touchedLinesRenderTrainingFormat() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let session = touchedSession("s")
        store.record(paths: [dir.appendingPathComponent("dist/bundle.js").path], session: session, workspace: ws)
        let lines = JudgeRuntime.judgeContextLines(cwd: ws, session: session, touched: store)
        #expect(lines == ["cwd-inside-repo: no", "agent-touched: ./dist/,./dist/bundle.js"])
    }

    @Test func suppliedEmptyLogsFull() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        // A looked-up empty list is a true negative (nothing touched yet),
        // not unknown: full, with the agent-touched line omitted exactly as
        // training omits it.
        #expect(JudgeRuntime.judgeContextLines(cwd: ws, session: touchedSession("fresh"), touched: store) == ["cwd-inside-repo: no"])
        #expect(JudgeRuntime.judgeContextPartial(cwd: ws, session: touchedSession("fresh"), touched: store) == false)
    }

    @Test func nilSessionKeepsV1Behavior() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        store.record(paths: ["./a.txt"], session: nil, workspace: ws)
        // No session: no lookup, so rendering and note match v1 exactly.
        #expect(JudgeRuntime.judgeContextLines(cwd: ws, touched: store) == ["cwd-inside-repo: no"])
        #expect(JudgeRuntime.judgeContextPartial(cwd: ws, touched: store) == true)
    }

    @Test func touchedDistRendersAgentTouchedLine() throws {
        // Regression for the motivating case: the agent created dist/, so a
        // later `rm -rf ./dist` scores with agent-touched context. Rendering
        // itself is golden-tested in Tests/RVLayaTests/FineTunedJudgeTests.swift
        // ("touched-only omits the other lines"); here the store output feeds it.
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionTouchedStore()
        let ws = touchedWorkspace(dir)
        let session = touchedSession("s")
        store.record(paths: [dir.appendingPathComponent("dist/bundle.js").path], session: session, workspace: ws)
        let touched = store.lookup(session: session, workspace: ws)
        #expect(touched.contains("./dist/"))
        let line = "agent-touched: " + touched.sorted().joined(separator: ",")
        #expect(line.contains("./dist/"))
        #expect(JudgeRuntime.judgeContextLines(cwd: ws, session: session, touched: store).contains(line))
    }
}

@Suite("SessionTouched shell extractor")
struct SessionTouchedExtractorTests {
    private func targets(_ command: String) -> [String] {
        GatedEvaluate.shellRedirectWriteTargets(in: command)
    }

    @Test func redirectTarget() {
        #expect(targets("echo hello > ./dist/out.txt") == ["./dist/out.txt"])
    }

    @Test func attachedRedirectTarget() {
        #expect(targets("echo x >./o.txt") == ["./o.txt"])
        #expect(targets("cmd 2> ./err.log") == ["./err.log"])
    }

    @Test func mkdirAddsDirHint() {
        #expect(targets("mkdir -p ./dist") == ["./dist/"])
    }

    @Test func touchRecordsFile() {
        #expect(targets("touch ./f.txt") == ["./f.txt"])
    }

    @Test func teeMatchesAnywhere() {
        #expect(targets("generate | tee ./a.txt ./b.txt") == ["./a.txt", "./b.txt"])
        #expect(targets("generate | tee -a ./x.txt") == ["./x.txt"])
    }

    @Test func mkdirMustBeFirstToken() {
        #expect(targets("echo mkdir") == [])
    }

    @Test func ambiguousSegmentsSkipped() {
        #expect(targets("echo $X > ./a.txt") == [])
        #expect(targets("cat *.log > ./all.txt") == [])
        #expect(targets("FOO=1 ./run.sh > ./a.txt") == [])
        #expect(targets("curl http://x/y > ./a.txt") == [])
    }

    @Test func devNullSinkNotRecorded() {
        #expect(targets("cmd 2>/dev/null > ./out.txt") == ["./out.txt"])
        #expect(targets("cmd > /dev/null") == [])
    }

    @Test func bareRelativeRejected() {
        #expect(targets("echo hi > out.txt") == [])
    }

    @Test func analysisCreateIsPrimary() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FilesystemTarget(
            apparent: "a.txt", canonical: dir.appendingPathComponent("a.txt").path,
            scope: .insideRepository, kind: .generatedOutput
        )
        let analysis = SemanticAnalysis.filesystem(.create(targets: [target]))
        let got = GatedEvaluate.shellWriteTargets(command: ShellCommand(rawValue: "make"), analysis: analysis)
        #expect(got == [target.canonical])
    }

    @Test func analysisDeleteNeverRecords() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FilesystemTarget(
            apparent: "a.txt", canonical: dir.appendingPathComponent("a.txt").path,
            scope: .insideRepository, kind: .generatedOutput
        )
        let analysis = SemanticAnalysis.filesystem(.delete(targets: [target], recursive: true, force: true))
        let got = GatedEvaluate.shellWriteTargets(command: ShellCommand(rawValue: "rm -rf ./x"), analysis: analysis)
        #expect(got == [])
    }
}

@Suite("SessionTouched file door")
struct SessionTouchedFileDoorTests {
    @Test func editAllowRecordsReadDoesNot() throws {
        let dir = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gated = GatedEvaluate()
        let ws = touchedWorkspace(dir)
        let session = touchedSession("s")
        let path = dir.appendingPathComponent("dist/bundle.js").path
        let edit = FileToolAction.make(toolName: "Write", filePath: path)!
        let editResult = gated.runFile(edit, home: nil, cwd: ws, host: .tty, now: Date(), session: session)
        #expect(editResult.decision == .allow)
        #expect(gated.touched.lookup(session: session, workspace: ws).contains("./dist/"))
        let before = gated.touched.entryCount(session: session, workspace: ws)
        let read = FileToolAction.make(toolName: "Read", filePath: path)!
        let readResult = gated.runFile(read, home: nil, cwd: ws, host: .tty, now: Date(), session: session)
        #expect(readResult.decision == .allow)
        #expect(gated.touched.entryCount(session: session, workspace: ws) == before)
    }
}

private enum TouchedE2EError: Error {
    case noReply
}

@Suite("SessionTouched hook end-to-end (integration equivalent)")
struct SessionTouchedHookEndToEndTests {
    private func claudeStdin(session: String?, cwd: String, tool: String, input: [String: String]) -> String {
        var envelope: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "cwd": cwd,
            "tool_name": tool,
            "tool_input": input,
        ]
        if let session { envelope["session_id"] = session }
        return String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
    }

    private func dispatchBody(stdin: String) throws -> Data {
        try IPCJSON.encode(IPCRequest(method: .hookEvaluate(
            HookEvaluateParams(host: .claude, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver)
        )))
    }

    private func hookReply(_ runtime: ServiceRuntime, stdin: String) async throws -> HookEvaluateReply {
        let incoming = await runtime.handleIncoming(
            try dispatchBody(stdin: stdin),
            handshakeOK: false,
            context: peerHookContext()
        )
        #expect(incoming.handshakeAccepted == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: incoming.frame)
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("hookEvaluate must dispatch")
            throw TouchedE2EError.noReply
        }
        return reply
    }

    private func judgeLogNotes(home: URL) throws -> [String?] {
        let file = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("judge-log.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return obj["note"] as? String
        }
    }

    @Test func touchedSessionSuppliesContextFreshDoesNot() async throws {
        let homeDir = try isolatedHomeDirectory()
        let home = HomeDirectory(validating: homeDir.path)!
        let runtime = ServiceRuntime(
            snapshots: nil,
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        let ws = try touchedTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(
            at: ws.appendingPathComponent("dist", isDirectory: true),
            withIntermediateDirectories: true
        )
        let touched = "sess-e2e-touched"
        let fresh = "sess-e2e-fresh"

        // 1. Edit hook in the touched session creates ./dist/bundle.js -> allow.
        let edit = claudeStdin(
            session: touched, cwd: ws.path, tool: "Write",
            input: ["file_path": ws.appendingPathComponent("dist/bundle.js").path]
        )
        let editReply = try await hookReply(runtime, stdin: edit)
        #expect(editReply.exitCode == 0)
        #expect(editReply.stdout == "")

        // 2. Shell hook in the SAME session: pack-allowed, judge scores with
        // the touched context.
        let shell = claudeStdin(session: touched, cwd: ws.path, tool: "Bash", input: ["command": "ls -la"])
        let touchedReply = try await hookReply(runtime, stdin: shell)
        #expect(touchedReply.exitCode == 0)
        #expect(touchedReply.stdout == "")

        // 3. Same shell in a FRESH session: no touched context.
        let freshShell = claudeStdin(session: fresh, cwd: ws.path, tool: "Bash", input: ["command": "ls -la"])
        let freshReply = try await hookReply(runtime, stdin: freshShell)
        #expect(freshReply.exitCode == 0)
        #expect(freshReply.stdout == "")

        // 4. Same shell with NO session: v1 behavior, context partial.
        let noSessionShell = claudeStdin(session: nil, cwd: ws.path, tool: "Bash", input: ["command": "ls -la"])
        let noSessionReply = try await hookReply(runtime, stdin: noSessionShell)
        #expect(noSessionReply.exitCode == 0)

        // Recording landed against the touched session only.
        let store = await runtime.touchedStoreForTests()
        #expect(store.lookup(session: touchedSession(touched), workspace: touchedWorkspace(ws)).contains("./dist/"))
        #expect(store.lookup(session: touchedSession(fresh), workspace: touchedWorkspace(ws)) == [])

        // The judge ran with supplied context for both sessions (fresh is a
        // supplied-empty true negative) and partial context without one. No
        // judge bundle is installed in this environment, so the safe-lane
        // verdict stays allow throughout: the strictness delta of
        // agent-touched allows is the trained model's job (training J6 spot
        // check), proven here at the context-plumbing level.
        let notes = try judgeLogNotes(home: homeDir)
        #expect(notes.count == 3)
        #expect(notes[0] == "safe-lane")
        #expect(notes[1] == "safe-lane")
        #expect(notes[2] == "safe-lane; context: partial")
    }
}
