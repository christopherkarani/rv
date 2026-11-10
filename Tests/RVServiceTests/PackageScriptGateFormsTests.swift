import Foundation
import Testing
@testable import RVService
import RVDomain

/// Runner spellings the script gate must resolve to the package.json body
/// they execute, plus the graph bounds and the unresolved floor.
@Suite("Package script gate forms")
struct PackageScriptGateFormsTests {
    static let poison = "rm -rf ~/Documents"

    static func makeDir(_ scripts: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scriptforms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["scripts": scripts])
        try data.write(to: dir.appendingPathComponent("package.json"))
        return dir
    }

    static func evaluate(_ command: String, cwd: URL) -> PackageScriptGate.Verdict {
        let session = EvaluateSession()
        return PackageScriptGate.evaluate(
            command: ShellCommand(rawValue: command),
            cwd: WorkingDirectory(rawValue: cwd.path),
            home: nil
        ) { body, _ in
            session.evaluate(EvaluationRequest(command: body, enabledPacks: dayOnePackIDs))
        }
    }

    static func isDeny(_ verdict: PackageScriptGate.Verdict) -> Bool {
        if case .deny = verdict { return true }
        return false
    }

    static func isUnresolved(_ verdict: PackageScriptGate.Verdict) -> Bool {
        if case .unresolved = verdict { return true }
        return false
    }

    static func isClear(_ verdict: PackageScriptGate.Verdict) -> Bool {
        if case .clear = verdict { return true }
        return false
    }

    @Test("every script-running spelling reads the poisoned body", arguments: [
        "npm --loglevel silent run evil",
        "npm --silent run evil",
        "npm run-script evil",
        "npm rum evil",
        "npm start",
        "npm stop",
        "npm restart",
        "npm t",
        "npm tst",
        "npm test --if-present",
        "yarn evil",
        "yarn run evil",
        "yarn --silent evil",
        "yarn test",
        "pnpm evil",
        "pnpm run evil",
        "pnpm start",
        "bun run evil",
        "bun evil",
        "time npm test",
        "nohup npm test",
        "env FOO=1 npm test",
        "FOO=1 npm test",
        "sudo npm start",
        "timeout 60 npm test",
        "command npm test",
        #"sh -c "npm test""#,
        "bash -lc 'yarn evil'",
        "NPM test",
        "./node_modules/.bin/npm run evil",
    ])
    func spellingsDeny(command: String) throws {
        let dir = try Self.makeDir([
            "evil": Self.poison, "test": Self.poison, "start": Self.poison,
            "stop": Self.poison, "restart": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isDeny(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("builtins and non-script verbs never read scripts", arguments: [
        "npm install left-pad",
        "npm exec foo",
        "yarn add left-pad",
        "yarn install",
        "pnpm install",
        "pnpm add left-pad",
        "bun test",
        "bun build ./x.ts",
        "bun install",
        "yarn notascript",
        "npm run",
        "yarn",
    ])
    func builtinsClear(command: String) throws {
        let dir = try Self.makeDir([
            "test": Self.poison, "build": Self.poison, "install": "node ok.js", "evil": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("workspace and recursive runs target other packages: unresolved", arguments: [
        "npm -w pkg run evil",
        "npm --workspace=pkg test",
        "npm test --workspaces",
        "pnpm -r test",
        "pnpm --filter app test",
        "yarn workspace app run evil",
        "yarn workspaces foreach run evil",
        "bun --filter app run evil",
    ])
    func workspacesUnresolved(command: String) throws {
        let dir = try Self.makeDir(["evil": "node ok.js", "test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("script-shell and node-options overrides run foreign code: unresolved", arguments: [
        "npm --script-shell ./evil.sh test",
        "npm test --script-shell=./evil.sh",
        "npm_config_script_shell=./evil.sh npm test",
        "NODE_OPTIONS=--require=./evil.js npm test",
        "npm --node-options=--require=./evil.js test",
    ])
    func configOverridesUnresolved(command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("nested implicit and wrapped runner bodies are followed")
    func nestedForms() throws {
        let dir = try Self.makeDir([
            "test": "yarn evil",
            "build": "time npm run evil",
            "evil": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isDeny(Self.evaluate("npm test", cwd: dir)))
        #expect(Self.isDeny(Self.evaluate("npm run build", cwd: dir)))
    }

    @Test("a nested runner aimed at another package or dir is unresolved")
    func nestedCrossPackage() throws {
        for body in ["npm --prefix ../other test", "cd ../other && npm test", "pnpm -r test"] {
            let dir = try Self.makeDir(["test": "node a.js", "ci": body])
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(Self.isUnresolved(Self.evaluate("npm run ci", cwd: dir)), "\(body)")
        }
    }

    @Test("a dense script graph is evaluated a bounded number of times")
    func graphIsMemoised() throws {
        let names = (0..<50).map { "s\($0)" }
        let fanOut = names.map { "npm run \($0)" }.joined(separator: " && ")
        var scripts: [String: String] = [:]
        for name in names { scripts[name] = fanOut }
        let dir = try Self.makeDir(scripts)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = EvaluateSession()
        var calls = 0
        let verdict = PackageScriptGate.evaluate(
            command: ShellCommand(rawValue: "npm run s0"),
            cwd: WorkingDirectory(rawValue: dir.path),
            home: nil
        ) { body, _ in
            calls += 1
            return session.evaluate(EvaluationRequest(command: body, enabledPacks: dayOnePackIDs))
        }
        #expect(calls <= PackageScriptGate.maxBodyEvaluations)
        // Every script calls itself: a cycle is never cleared.
        #expect(Self.isUnresolved(verdict))
    }

    @Test("an acyclic graph still resolves after memoisation")
    func acyclicGraphResolves() throws {
        let dir = try Self.makeDir([
            "test": "npm run a && npm run b",
            "a": "npm run c",
            "b": "npm run c",
            "c": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isDeny(Self.evaluate("npm test", cwd: dir)))
    }

    @Test("no package.json and nothing earlier in the chain: nothing executes, clear")
    func missingPackageAloneIsClear() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scriptforms-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate("npm test", cwd: dir)))
        #expect(Self.isClear(Self.evaluate("yarn evil", cwd: dir)))
        // An earlier segment may create package.json before the runner reads it.
        #expect(Self.isUnresolved(Self.evaluate("make && npm test", cwd: dir)))
        #expect(Self.isUnresolved(Self.evaluate("npm test $(touch package.json)", cwd: dir)))
    }

    @Test("malformed package.json stays unresolved")
    func malformedUnresolved() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scriptforms-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{not json".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        #expect(Self.isUnresolved(Self.evaluate("npm test", cwd: dir)))
    }

    @Test("runners inside subshells and brace groups are read", arguments: [
        "(npm test)",
        "{ npm test; }",
        "(npm run evil)",
        "(cd . ; npm test)",
        "if true; then npm test; fi",
    ])
    func groupedRunnersNotClear(command: String) throws {
        let dir = try Self.makeDir(["test": Self.poison, "evil": Self.poison])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)) == false, "\(command)")
    }

    @Test("input the launcher parser stops following is not clear")
    func truncatedLaunchNotClear() throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(#"{sh,bash} -c "npm test""#, cwd: dir)) == false)
    }

    @Test("an earlier write to package.json makes the graph unresolved")
    func earlierPackageWriteUnresolved() throws {
        let dir = try Self.makeDir(["build": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rewrite = #"echo '{"scripts":{"test":"rm -rf ~"}}' > package.json && npm test"#
        #expect(Self.isUnresolved(Self.evaluate(rewrite, cwd: dir)))
    }

    @Test("a cd that does not persist leaves the cwd untracked", arguments: [
        "cd sub & npm test",
        "cd sub | npm test",
        "(cd sub && true); npm test",
        "{ cd sub; }; npm test",
        "if cd sub; then npm test; fi",
        "builtin cd sub && npm test",
        "pushd sub && npm test",
        "env -C sub npm test",
    ])
    func nonPersistentCD(command: String) throws {
        let root = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["scripts": ["test": "node ok.js"]])
            .write(to: sub.appendingPathComponent("package.json"))
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: root)), "\(command)")
    }
}

@Suite("Package script gate packs-only floor")
struct PackageScriptGateFloorTests {
    static func packsOnly(_ command: String, scriptGraphResolved: Bool) throws -> EvaluationResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scriptfloor-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try #require(HomePath(validating: root.path))
        return JudgeRuntime.apply(
            to: EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: command),
            inputs: .gather(home: home, cwd: nil, environment: [:]), judge: LiveJudgePort(),
            provenance: .unknown, now: Date(), cwd: nil,
            allowSafeLane: scriptGraphResolved, isPeek: false
        ).result
    }

    @Test("no judge and an unresolved script graph is indeterminate, not allow")
    func unresolvedIsIndeterminate() throws {
        let result = try Self.packsOnly(#"cd "$D" && npm test"#, scriptGraphResolved: false)
        #expect(result.decision == .indeterminate(.packageScriptUnresolved))
    }

    @Test("no judge and a resolved script graph stays allowed")
    func resolvedStaysAllowed() throws {
        #expect(try Self.packsOnly("npm test", scriptGraphResolved: true).decision == .allow)
    }
}
