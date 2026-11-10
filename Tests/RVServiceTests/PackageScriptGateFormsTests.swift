import Foundation
import Testing
@testable import RVService
import RVDomain
import RVLaya

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

    static func needsJudge(_ verdict: PackageScriptGate.Verdict) -> Bool {
        if case .needsJudge = verdict { return true }
        return false
    }

    static func emptyDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scriptforms-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        "yarn add left-pad",
        "yarn install",
        "pnpm install",
        "pnpm add left-pad",
        "bun test",
        "bun build ./x.ts",
        "bun install",
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

    @Test("lifecycle verbs run their lifecycle scripts", arguments: [
        "npm install", "npm i", "npm ci", "npm install lodash", "npm it", "npm rebuild", "npm update",
        "npm audit fix", "npm pack", "npm publish", "npm version patch",
        "yarn", "yarn install", "yarn add lodash", "pnpm install", "pnpm i", "pnpm add lodash",
        "bun install", "bun add lodash", "node --run evil",
    ])
    func lifecycleVerbsDeny(command: String) throws {
        let dir = try Self.makeDir([
            "preinstall": Self.poison, "postinstall": Self.poison, "prepare": Self.poison,
            "prepack": Self.poison, "preversion": Self.poison, "prepublishOnly": Self.poison,
            "evil": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isDeny(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("verbs, flags and runners outside the exact grammar are unresolved", arguments: [
        "npm tes", "npm runScript test",
        "corepack yarn test", "corepack pnpm run build",
        "npm --pre /tmp test", "npm --scri=/x test", "npm test --script-sh=/x", "npm --frobnicate test",
        "npm -X test", "npm config set script-shell /x", "npm set script-shell /x",
        "npm pkg set scripts.test=x", "yarn config set x y", "pnpm config set x y",
        // A bin runner that runs a shell string or preloads code is not a bin run.
        "npx -c 'rm -rf ~'", "npx --call='rm -rf ~'", "npm exec -c 'rm -rf ~'", "npm exec foo --call=x",
        "pnpm dlx -c 'rm -rf ~'", "pnpm exec -c 'rm -rf ~'", "npx --node-options=--require=/x tsc",
        // Global flags that are not a plain global install of named packages.
        "npm install -g .", "npm i -g ./tool", "npm install --global ../x", "npm -g run evil",
        "npm test -g", "npm i -g --prefix /tmp x", "npm install -g",
    ])
    func outsideGrammarUnresolved(command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js", "build": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    /// Package bins, not package scripts: the gate has no script graph to
    /// read, so the judge decides with the safe lane closed (as before the
    /// script floor existed). Never clear, never the human-only floor.
    @Test("package-bin runs go to the judge, not the floor", arguments: [
        "npm exec foo", "npm x foo", "npm exec tsc -- --noEmit", "npx foo", "npx tsc --noEmit",
        "npx --yes prettier --check .", "npx -p typescript tsc", "npx eslint -c .eslintrc.json src",
        "pnpx foo", "pnpm dlx foo", "pnpm dlx create-vite", "pnpm exec foo", "yarn dlx foo",
        "bunx foo", "bun x foo", "corepack enable", "deno task build", "npm init vite",
        "yarn eslint .", "pnpm tsc", "pnpm vitest", "bun eslint", "yarn notascript",
        "npm i -g typescript", "npm install -g @anthropic-ai/claude-code", "sudo npm install -g pnpm",
        "npm install --global typescript", "npm i --location=global typescript",
        "docker run -v $(pwd):/app node:20 npm test", "ssh host npm test",
    ])
    func binRunsNeedTheJudge(command: String) throws {
        let dir = try Self.makeDir([
            "test": "node ok.js", "build": "node ok.js",
            "postinstall": Self.poison, "prepare": Self.poison,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.needsJudge(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("a bare word that is a script key is still read as the script")
    func bareScriptWordStillRead() throws {
        let dir = try Self.makeDir(["vitest": Self.poison])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isDeny(Self.evaluate("pnpm vitest", cwd: dir)))
        #expect(Self.isDeny(Self.evaluate("yarn vitest && yarn eslint .", cwd: dir)))
    }

    @Test("a bin run under config that preloads code is unresolved")
    func binRunUnderPreloadConfigUnresolved() throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try "node-options=--require=/tmp/x.js\n"
            .write(to: dir.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        #expect(Self.isUnresolved(Self.evaluate("npx tsc", cwd: dir)))
        #expect(Self.isUnresolved(Self.evaluate("NODE_OPTIONS=--require=/x npx tsc", cwd: dir)))
    }

    @Test("a process pattern naming a runner launches nothing", arguments: [
        "pkill -f 'npm run dev'", "pgrep -f 'npm test'", "killall npm", "ps aux | grep 'npm run dev'",
    ])
    func processPatternsClear(command: String) throws {
        let dir = try Self.makeDir(["dev": Self.poison, "test": Self.poison])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("read-only runner forms execute no script", arguments: [
        "npm", "npm --version", "npm -v", "npm help", "npm ls", "npm view react", "npm outdated",
        "npm config get prefix", "yarn --version", "yarn why left-pad", "pnpm ls", "pnpm --version",
        "bun --version", "bun test", "bun run ./x.ts",
    ])
    func readOnlyFormsClear(command: String) throws {
        let dir = try Self.makeDir(["test": Self.poison, "install": Self.poison, "prepare": Self.poison])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("dynamic, launcher-wrapped and env-overridden runners are never clear", arguments: [
        "$NPM test", #""$(which npm)" test"#, "xargs npm test", "watch npm test",
        #"find . -name x -exec npm test \;"#, "caffeinate npm test", "script -q /dev/null npm test",
        "export npm_config_script_shell=/x; npm test", "export NODE_OPTIONS=--require=/x && npm test",
        "PATH=/tmp/evil:$PATH npm test", "source ./env.sh && npm test",
    ])
    func wrappedRunnersNotClear(command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)) == false, "\(command)")
    }

    @Test("persistent runner config that swaps the shell or preloads code is unresolved", arguments: [
        (".npmrc", "script-shell=/tmp/evil.sh\n", "npm test"),
        (".npmrc", "node-options=--require=/tmp/x.js\n", "npm test"),
        (".yarnrc.yml", "shell: /tmp/evil.sh\n", "yarn test"),
        ("bunfig.toml", "preload = [\"./x.ts\"]\n", "bun run test"),
    ])
    func persistentConfigUnresolved(file: String, content: String, command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: dir)), "\(file)")
    }

    @Test("an ordinary .npmrc keeps the graph resolvable")
    func ordinaryNpmrcClear() throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try "registry=https://registry.npmjs.org/\nsave-exact=true\n"
            .write(to: dir.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        #expect(Self.isClear(Self.evaluate("npm test", cwd: dir)))
    }

    @Test("workspace and recursive runs target other packages: unresolved", arguments: [
        "npm -w pkg run evil",
        "npm --workspace=pkg test",
        "npm test --workspaces",
        "npm test --ws",
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
        let dir = try Self.emptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate("npm test", cwd: dir)))
        // A bare word with no manifest may still run a bin: the judge decides.
        #expect(Self.needsJudge(Self.evaluate("yarn evil", cwd: dir)))
        // An earlier segment may create package.json before the runner
        // reads it: no script runs now, so the judge (which reads the whole
        // chain) decides; one that names a manifest is the floor.
        #expect(Self.needsJudge(Self.evaluate("make && npm test", cwd: dir)))
        #expect(Self.needsJudge(Self.evaluate("npm test && npm run lint", cwd: dir)))
        #expect(Self.needsJudge(Self.evaluate("npm install && npm run build && npm test", cwd: dir)))
        #expect(Self.isUnresolved(Self.evaluate("npm test $(touch package.json)", cwd: dir)))
        #expect(Self.isUnresolved(Self.evaluate(
            #"echo '{"scripts":{"test":"rm -rf ~"}}' > package.json; npm test"#, cwd: dir)))
    }

    @Test("a cwd rvd cannot place is unresolved, never clear")
    func relativeCwdUnresolved() {
        // rvd's own cwd is not the agent's: a relative workdir from a host
        // would be resolved against it and find nothing.
        let verdict = PackageScriptGate.evaluate(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: "web-\(UUID().uuidString)"),
            home: nil
        ) { body, _ in
            EvaluateSession().evaluate(EvaluationRequest(command: body, enabledPacks: dayOnePackIDs))
        }
        #expect(Self.isUnresolved(verdict))
    }

    @Test("another manifest format with no package.json is unresolved", arguments: [
        "package.yaml", "package.json5",
    ])
    func otherManifestUnresolved(file: String) throws {
        let dir = try Self.emptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "scripts:\n  test: rm -rf ~\n".write(
            to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        #expect(Self.isUnresolved(Self.evaluate("pnpm test", cwd: dir)), "\(file)")
        #expect(Self.isUnresolved(Self.evaluate("npm test", cwd: dir)), "\(file)")
        let sub = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(Self.isUnresolved(Self.evaluate("pnpm test", cwd: sub)), "\(file) above cwd")
    }

    @Test("a directory rvd cannot read on the way up is unresolved")
    func unreadableAncestorUnresolved() throws {
        let dir = try Self.emptyDir()
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        let inner = locked.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(Self.isUnresolved(Self.evaluate("npm test", cwd: inner)))
    }

    @Test("an earlier mutation before a run that executes no script goes to the judge")
    func mutationBeforeScriptlessRunNeedsJudge() throws {
        let plain = try Self.makeDir(["test": "node ok.js", "build": "node ok.js"])
        let hooked = try Self.makeDir(["test": "node ok.js", "prepare": "husky install"])
        defer { [plain, hooked].forEach { try? FileManager.default.removeItem(at: $0) } }
        for command in [
            "rm -rf node_modules && npm install", "git pull && npm install", "rm -rf node_modules && npx tsc",
            "mkdir -p dist && npm ci",
        ] {
            #expect(Self.needsJudge(Self.evaluate(command, cwd: plain)), "\(command)")
            // A script that will run after the mutation: TOCTOU, the floor.
            if command.contains("npx") == false {
                #expect(Self.isUnresolved(Self.evaluate(command, cwd: hooked)), "\(command) hooked")
            }
        }
        // A mutation that names a manifest or runner config is the floor
        // even when nothing would run today.
        for command in [
            #"echo '{"scripts":{"install":"rm -rf ~"}}' > package.json && npm install"#,
            "cp /tmp/x .npmrc && npx tsc",
            "rm package.json && npm install",
        ] {
            #expect(Self.isUnresolved(Self.evaluate(command, cwd: plain)), "\(command)")
        }
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

    @Test("a body carrying an inline program only the judge reads is unresolved")
    func inlineProgramBodyUnresolved() throws {
        let dir = try Self.makeDir(["test": #"node -e "require('child_process').execSync('id')""#])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate("npm test", cwd: dir)))
    }

    @Test("the safe lane survives only when every body is itself safe-lane")
    func safeLaneNeedsSafeBodies() throws {
        let safe = try Self.makeDir(["test": "ls", "build": "echo done"])
        let opaque = try Self.makeDir(["test": "jest --ci", "build": "echo done"])
        defer { [safe, opaque].forEach { try? FileManager.default.removeItem(at: $0) } }
        guard case .clear(let safeBodies) = Self.evaluate("npm test && npm run build", cwd: safe),
              case .clear(let opaqueBodies) = Self.evaluate("npm test && npm run build", cwd: opaque)
        else {
            Issue.record("clean graphs must resolve clear")
            return
        }
        #expect(safeBodies)
        #expect(opaqueBodies == false)
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

    @Test("an earlier unit outside the read-only allowlist makes later runners unresolved", arguments: [
        "make && npm test",
        "tee package.json < evil.json && npm test",
        "cat evil.json | tee pkg && npm test",
        "sed -i s/a/b/ pkg && npm test",
        "cp evil.json manifest && npm test",
        "jq . a > b && npm test",
        "echo $(cp evil.json package.json) && npm test",
        "echo x >| out; npm test",
        "echo x <>out; npm test",
        "echo x &>out; npm test",
        "echo x >&out; npm test",
        "./ls && npm test",
        "git -c core.fsmonitor=x status && npm test",
        "git diff --output=pkg && npm test",
        "git branch topic && npm test",
        "git config core.hooksPath x && npm test",
        "rg --pre ./x foo && npm test",
        "python3 tool.py && npm test",
    ])
    func earlierMutatingUnitUnresolved(command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("read-only earlier units keep the graph resolvable", arguments: [
        "git status && npm test",
        "git log --oneline -5 && git diff --stat && npm test",
        "npm run build && npm test",
        "ls 2>/dev/null && npm test",
        "echo hi 2>&1 && npm test",
        "pwd; date; npm test",
        "node --version && npm test",
        "git branch --show-current && npm test",
        "set -e; npm test",
        "npm test 2>&1 | tail -20",
        "npm test > test.log 2>&1",
    ])
    func readOnlyEarlierUnitsClear(command: String) throws {
        let dir = try Self.makeDir(["test": "node ok.js", "build": "node ok.js"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isClear(Self.evaluate(command, cwd: dir)), "\(command)")
    }

    @Test("a write inside a body before a nested runner is unresolved")
    func nestedMutationUnresolved() throws {
        let dir = try Self.makeDir([
            "test": #"cp evil.json package.json && npm run lint"#,
            "lint": "node ok.js",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.isUnresolved(Self.evaluate("npm test", cwd: dir)))
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

/// A judge that allows everything: an unresolved graph must not reach it.
private struct AllowingJudge: JudgePort {
    var choice = "allow"
    var risk = 0.0

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        let json = """
        {"choice":"\(choice)","probabilities":{},"riskScore":\(risk),"malicious":0,
         "risk":\(risk),"checkpoint":"fake","latencyMilliseconds":1,"truncated":false}
        """
        // swiftlint:disable:next force_try
        return .verdict(try! JSONDecoder().decode(LayaVerdict.self, from: Data(json.utf8)))
    }
}

@Suite("Package script gate unresolved floor")
struct PackageScriptGateFloorTests {
    static let fakeBundle = JudgeSelection(
        engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true)
    )

    fileprivate static func gated(
        _ command: String, scripts: [String: String], judge: JudgeSelection,
        port: AllowingJudge = AllowingJudge()
    ) throws -> EvaluationResult {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let dir = try PackageScriptGateFormsTests.makeDir(scripts)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = WorkingDirectory(rawValue: dir.path)
        return GatedEvaluate(EvaluateSession(), judge: port).evaluateAgent(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: cwd, home: home, now: Date(),
            inputs: EvaluationInputs(guardMode: .enforce, judge: judge, store: .gather(home: home, cwd: cwd))
        )
    }

    @Test("an unresolved script graph is indeterminate with or without a judge")
    func unresolvedIsIndeterminate() throws {
        for judge in [Self.fakeBundle, JudgeSelection(engine: .ft, bundle: nil)] {
            let result = try Self.gated(#"cd "$D" && npm test"#, scripts: ["test": "node ok.js"], judge: judge)
            #expect(result.decision == .indeterminate(.packageScriptUnresolved), "\(judge)")
        }
    }

    /// A package bin is not a script graph: it reaches the judge with the
    /// safe lane closed, exactly as before the floor existed. The judge's
    /// verdict decides; without a judge bundle it is packs-only.
    @Test("a package-bin run is decided by the judge, not floored", arguments: [
        "npx tsc --noEmit", "yarn eslint .", "pnpm vitest", "npx prettier --check .",
    ])
    func binRunReachesTheJudge(command: String) throws {
        let scripts = ["test": "node ok.js"]
        let blocked = try Self.gated(
            command, scripts: scripts, judge: Self.fakeBundle, port: AllowingJudge(choice: "block", risk: 0.99))
        #expect(blocked.decision != .allow, "\(command): the judge must be consulted")
        #expect(blocked.decision != .indeterminate(.packageScriptUnresolved), "\(command)")
        let allowed = try Self.gated(command, scripts: scripts, judge: Self.fakeBundle)
        #expect(allowed.decision == .allow, "\(command): \(allowed.decision)")
    }

    @Test("a resolved, clean script graph stays allowed without a judge")
    func resolvedStaysAllowed() throws {
        let result = try Self.gated("npm test", scripts: ["test": "node ok.js"], judge: JudgeSelection(engine: .ft, bundle: nil))
        #expect(result.decision == .allow)
    }
}
