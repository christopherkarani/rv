import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// The hook-local equivalence harness (docs/architecture/hook-local-decide.md).
///
/// Every engine corpus command and ~1000 everyday developer commands go
/// through the Bash tool, and a fixed set of paths through Read / Write /
/// Edit / Grep, in a repo and outside one, under enforce and observe, and
/// with a judge installed. Each call is decided by the local evaluator and
/// then by rvd's hook door over the same home. Every final local answer
/// must be byte-identical to rvd's reply; an escalation is always sound,
/// since rvd then decides. With a judge, both sides ask one pool stub with
/// fixed scores per command (`ScoredPoolClient`), and rvd answers every
/// call so the report can count pool requests per hook call: the
/// evaluator's, plus rvd's when it escalated. `RV_LOCAL_EQUIVALENCE_REPORT=<path>` writes the
/// per-configuration share decided locally. By default every 5th call
/// runs (about 70 s); `RV_LOCAL_EQUIVALENCE_FULL=1` runs all ~12,500.
@Suite("Hook-local equivalence", .serialized)
struct LocalHookEquivalenceTests {
    struct Configuration: Sendable, CustomStringConvertible {
        let guardMode: String?
        let repo: Bool
        let judge: Bool
        var description: String {
            "\(guardMode ?? "enforce")/\(repo ? "repo" : "no-repo")\(judge ? "/judge" : "")"
        }
    }

    static let configurations: [Configuration] = [
        .init(guardMode: nil, repo: true, judge: false),
        .init(guardMode: nil, repo: false, judge: false),
        .init(guardMode: "observe", repo: true, judge: false),
        .init(guardMode: "observe", repo: false, judge: false),
        .init(guardMode: nil, repo: true, judge: true),
        .init(guardMode: "observe", repo: true, judge: true),
    ]

    @Test(arguments: configurations)
    func everyLocalFinalIsRvdsReply(_ configuration: Configuration) async throws {
        let pool = configuration.judge ? ScoredPoolClient() : nil
        let fixture = try LocalHookFixture(
            judgeBundle: configuration.judge, guardMode: configuration.guardMode, repo: configuration.repo,
            judge: pool)
        let runtime = hookTestRuntime(
            home: fixture.home, allowOnceDirectory: try isolatedAllowOnceDirectory(),
            judge: pool.map { PoolJudgePort(client: $0) } ?? LiveJudgePort())
        var tally = Tally()
        let all = EquivalenceCorpus.calls(workspace: fixture.workspace, home: fixture.home.path)
        let stride = ProcessInfo.processInfo.environment["RV_LOCAL_EQUIVALENCE_FULL"] == "1" ? 1 : 5
        for (index, call) in all.enumerated() where index % stride == 0 {
            let before = pool?.count ?? 0
            let local = await fixture.decider.decide(host: .claude, stdin: call.stdin)
            let asked = (pool?.count ?? 0) - before
            switch local {
            case .escalate(let reason):
                tally.escalated[reason.rawValue, default: 0] += 1
                if let pool {
                    // rvd answers the escalated call, asking the pool again
                    // when it judges.
                    let rvdBefore = pool.count
                    _ = try await Self.rvdReply(runtime, stdin: call.stdin)
                    tally.count(local: asked, rvd: pool.count - rvdBefore)
                }
            case .final(let reply):
                if pool != nil { tally.count(local: asked, rvd: 0) }
                let rvd = try await Self.rvdReply(runtime, stdin: call.stdin)
                if reply != rvd {
                    tally.mismatches += 1
                    Issue.record("""
                        \(configuration) \(call.label): local final differs from rvd
                        local: \(reply)
                        rvd:   \(rvd)
                        """)
                }
                if reply.stdout.isEmpty && reply.exitCode == 0 {
                    tally.finalAllow += 1
                } else {
                    tally.finalDeny += 1
                }
            }
            tally.total += 1
            if call.isBash { tally.bash += 1; if case .final = local { tally.bashLocal += 1 } }
        }
        #expect(tally.mismatches == 0)
        // The corpus files and generators are all there.
        #expect(all.count > 2_400)
        try Self.report(configuration, tally)
    }

    struct Tally: Codable {
        var total = 0
        var bash = 0
        var bashLocal = 0
        var finalAllow = 0
        var finalDeny = 0
        var mismatches = 0
        var escalated: [String: Int] = [:]
        /// Hook calls that reached the pool, and pool requests for them
        /// (the evaluator's plus rvd's after an escalation).
        var judgedCalls = 0
        var poolRequests = 0
        /// Judged calls the pool was asked twice (the evaluator, then rvd).
        var askedTwice = 0
        var localJudgedFinal = 0

        mutating func count(local: Int, rvd: Int) {
            guard local + rvd > 0 else { return }
            judgedCalls += 1
            poolRequests += local + rvd
            if local > 0, rvd > 0 { askedTwice += 1 }
            if local > 0, rvd == 0 { localJudgedFinal += 1 }
        }
    }

    static func rvdReply(_ runtime: ServiceRuntime, stdin: String) async throws -> HookEvaluateReply {
        let response = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .claude, stdin: stdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = response.result else {
            throw LocalHookFixtureError.noReply("\(response.result)")
        }
        return reply
    }

    static func report(_ configuration: Configuration, _ tally: Tally) throws {
        guard let path = ProcessInfo.processInfo.environment["RV_LOCAL_EQUIVALENCE_REPORT"] else { return }
        let local = tally.finalAllow + tally.finalDeny
        let share = Double(local) / Double(max(tally.total, 1))
        let bashShare = Double(tally.bashLocal) / Double(max(tally.bash, 1))
        let line = String(
            format: "%@ total=%d local=%d (%.1f%%) bash=%d bashLocal=%d (%.1f%%) allow=%d deny=%d mismatches=%d judged=%d poolRequests=%d askedTwice=%d judgedLocal=%d escalated=%@\n",
            configuration.description, tally.total, local, share * 100, tally.bash, tally.bashLocal,
            bashShare * 100, tally.finalAllow, tally.finalDeny, tally.mismatches, tally.judgedCalls,
            tally.poolRequests, tally.askedTwice, tally.localJudgedFinal,
            tally.escalated.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
        let handle = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)!
        }()
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}

/// The calls the harness sends, as Claude hook payloads.
enum EquivalenceCorpus {
    struct Call {
        let label: String
        let stdin: String
        let isBash: Bool
    }

    static func calls(workspace: String, home: String) -> [Call] {
        var calls: [Call] = []
        for (label, command) in engineCorpus() + everydayCommands().map({ ("everyday", $0) }) {
            calls.append(Call(label: "\(label): \(command)", stdin: claudeBash(command, cwd: workspace), isBash: true))
        }
        for path in filePaths(workspace: workspace, home: home) {
            calls.append(Call(label: "Read \(path)",
                stdin: claudePayload(tool: "Read", input: ["file_path": path], cwd: workspace), isBash: false))
            calls.append(Call(label: "Write \(path)",
                stdin: claudePayload(tool: "Write", input: ["file_path": path, "content": "x\n"], cwd: workspace),
                isBash: false))
            calls.append(Call(label: "Edit \(path)",
                stdin: claudePayload(
                    tool: "Edit", input: ["file_path": path, "old_string": "a", "new_string": "b"], cwd: workspace),
                isBash: false))
            calls.append(Call(label: "Grep \(path)",
                stdin: claudePayload(tool: "Grep", input: ["pattern": "TODO", "path": path], cwd: workspace),
                isBash: false))
        }
        return calls
    }

    /// Every command in Tests/RVEngineTests/Fixtures/corpus (the door-bypass
    /// corpus included).
    static func engineCorpus() -> [(String, String)] {
        struct File: Decodable { let cases: [Case] }
        struct Case: Decodable { let id: String; let command: String? }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RVEngineTests/Fixtures/corpus")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var out: [(String, String)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                let file = try? JSONDecoder().decode(File.self, from: data)
            else { continue }
            out += file.cases.compactMap { row in row.command.map { (row.id, $0) } }
        }
        return out
    }

    /// ~1000 deterministic everyday commands: what an agent runs all day.
    static func everydayCommands() -> [String] {
        let files = ["README.md", "Package.swift", "src/main.swift", "src/app.ts", "Makefile",
                     "package.json", "Cargo.toml", "go.mod", "tests/test_app.py", "docs/guide.md",
                     "index.html", "styles.css", "server.py", "lib/utils.go", "app/models/user.rb"]
        let branches = ["main", "feature/login", "fix/crash-on-start", "release/1.2"]
        var commands: [String] = []
        let git = ["git status", "git status --short", "git diff", "git diff --stat", "git diff --cached",
                   "git log --oneline -20", "git log -p -1", "git branch", "git branch -a", "git fetch",
                   "git fetch origin", "git pull", "git pull --rebase", "git push", "git push -u origin HEAD",
                   "git stash list", "git remote -v", "git show HEAD", "git rev-parse HEAD",
                   "git add -A", "git add .", "git commit -m 'wip'", "git commit --amend --no-edit",
                   "git merge --no-ff main", "git rebase main", "git tag", "git blame README.md",
                   "git restore --staged .", "git clean -n", "git cherry-pick abc123"]
        commands += git
        for branch in branches {
            commands += ["git checkout \(branch)", "git switch \(branch)", "git switch -c \(branch)",
                         "git log \(branch) --oneline", "git diff main...\(branch)", "git push origin \(branch)",
                         "git branch -d \(branch)", "git merge \(branch)"]
        }
        for file in files {
            commands += ["cat \(file)", "head -50 \(file)", "tail -20 \(file)", "wc -l \(file)",
                         "less \(file)", "grep -n TODO \(file)", "rg TODO \(file)", "sed -n '1,40p' \(file)",
                         "git add \(file)", "git diff \(file)", "git log --follow \(file)",
                         "git checkout -- \(file)", "cp \(file) \(file).bak", "mv \(file).bak /tmp/",
                         "rm \(file).bak", "touch \(file)", "chmod 644 \(file)", "stat \(file)",
                         "file \(file)", "md5 \(file)", "shasum \(file)", "diff \(file) \(file).orig",
                         "awk '{print $1}' \(file)", "sort \(file) | uniq -c", "cat \(file) | jq .",
                         "python3 -m json.tool \(file)", "open \(file)", "code \(file)",
                         "vim \(file)", "nano \(file)"]
        }
        let builds = ["swift build", "swift build -c release", "swift test", "swift test --filter AppTests",
                      "swift package resolve", "swift package update", "xcodebuild -list",
                      "npm install", "npm ci", "npm test", "npm run build", "npm run lint", "npm run dev",
                      "npx tsc --noEmit", "npx eslint .", "npx prettier --check .", "pnpm install", "pnpm test",
                      "yarn", "yarn build", "bun install", "bun test", "cargo build", "cargo test",
                      "cargo clippy", "cargo fmt", "go build ./...", "go test ./...", "go vet ./...",
                      "go mod tidy", "make", "make test", "make clean", "cmake --build build",
                      "python3 -m pytest", "pytest -q", "pytest tests/test_app.py -k login",
                      "python3 -m venv .venv", "pip install -r requirements.txt", "pip list",
                      "python3 script.py", "python3 -c 'print(1)'", "node index.js", "node -e 'console.log(1)'",
                      "ruby -v", "bundle install", "bundle exec rspec", "mix test", "gradle test",
                      "./gradlew build", "mvn -q test", "dotnet build", "dotnet test", "docker ps",
                      "docker images", "docker build -t app .", "docker compose up -d", "docker compose logs",
                      "kubectl get pods", "kubectl describe pod web-1", "terraform plan", "terraform fmt",
                      "brew list", "brew install jq", "tsc", "deno test", "flutter test", "rustc --version"]
        commands += builds
        let shell = ["ls", "ls -la", "ls -R src", "pwd", "whoami", "date", "uname -a", "env", "printenv PATH",
                     "echo $PATH", "which swift", "type git", "df -h", "du -sh .", "du -sh node_modules",
                     "ps aux", "top -l 1", "lsof -i :3000", "uptime", "history", "clear", "true",
                     "echo hello", "echo 'done' > /tmp/out.txt", "mkdir -p build", "mkdir -p src/utils",
                     "rm -rf build", "rm -rf node_modules", "rm -rf .build", "rm -rf dist", "rm -f /tmp/out.txt",
                     "find . -name '*.swift'", "find . -type f -name '*.ts' | head", "find src -newer README.md",
                     "tree -L 2", "xargs -n1 echo < list.txt", "tar -czf out.tgz src", "unzip -l a.zip",
                     "curl -s https://example.com", "curl -I https://api.github.com",
                     "wget https://example.com/file.txt", "ping -c 1 example.com", "ssh -V",
                     "jq '.dependencies' package.json", "yq '.services' docker-compose.yml",
                     "sed -i '' 's/foo/bar/' README.md", "perl -pi -e 's/a/b/' README.md",
                     "cat > notes.txt <<'EOF'\nhello\nEOF", "printf 'a\\nb\\n' | sort",
                     "export NODE_ENV=test", "source .venv/bin/activate", "cd src && ls",
                     "for f in *.md; do wc -l \"$f\"; done", "while read l; do echo $l; done < list.txt",
                     "time swift build", "sleep 1", "kill %1", "pkill -f vite", "chmod +x script.sh",
                     "./script.sh", "bash script.sh", "sh -c 'echo hi'", "zsh -c 'echo hi'",
                     "gh pr list", "gh pr view 12", "gh pr create --fill", "gh issue list", "gh run list",
                     "gh pr checks", "gh api repos/o/r", "open -a Xcode .", "code .", "say done",
                     "pbcopy < README.md", "pbpaste", "osascript -e 'beep'", "defaults read com.apple.dock",
                     "launchctl list", "sudo -n true", "crontab -l", "git config user.name",
                     "git config --global core.editor vim", "npm config get registry", "nvm use 20",
                     "pyenv versions", "rbenv versions", "asdf current", "direnv allow"]
        commands += shell
        // Grep / search variations (cheap, very common).
        for term in ["TODO", "FIXME", "func main", "import Foundation", "useState", "async fn", "def test_",
                     "SELECT", "password", "apiKey", "http://", "console.log", "deprecated", "unwrap()",
                     "XXX", "panic(", "throw new", "@MainActor", "class ", "interface "] {
            commands += ["grep -rn '\(term)' .", "rg '\(term)'", "rg -n '\(term)' src", "git grep '\(term)'",
                         "grep -rl '\(term)' --include='*.swift' .", "ag '\(term)'"]
        }
        // Test-runner and script variations.
        for name in ["login", "signup", "checkout", "search", "profile", "settings", "api", "db",
                     "auth", "billing", "cache", "queue", "users", "export"] {
            commands += ["swift test --filter \(name.capitalized)Tests", "npm test -- \(name)",
                         "pytest -k \(name)", "go test ./\(name)/...", "cargo test \(name)",
                         "npm run test:\(name)", "make test-\(name)", "bun test \(name)",
                         "python3 scripts/\(name).py", "node scripts/\(name).js"]
        }
        var seen = Set<String>()
        return commands.filter { seen.insert($0).inserted }
    }

    static func filePaths(workspace: String, home: String) -> [String] {
        let relative = ["README.md", "src/main.swift", "src/app.ts", ".env", ".env.local", ".env.example",
                        "config/secrets.yml", "id_rsa", ".npmrc", ".netrc", ".git/config", ".git/hooks/pre-commit",
                        ".mcp.json", ".claude/settings.json", ".claude/settings.local.json", ".cursor/mcp.json",
                        "node_modules/x/index.js", "Package.swift", "package.json", ".github/workflows/ci.yml",
                        "credentials.json", "service-account.json", ".vscode/settings.json", "Makefile",
                        "scripts/deploy.sh", "tests/test_app.py", "docs/guide.md", "terraform.tfstate"]
        let homeRelative = [".ssh/id_rsa", ".ssh/id_ed25519.pub", ".ssh/config", ".aws/credentials",
                            ".aws/config", ".config/rv/config.json", ".config/rv/audit.jsonl",
                            ".local/bin/rv", ".zshrc", ".bashrc", ".gitconfig", ".claude/settings.json",
                            ".claude.json", ".docker/config.json", ".kube/config", ".npmrc",
                            "Library/LaunchAgents/dev.rv.rvd.plist", "Documents/notes.txt"]
        return relative.map { "\(workspace)/\($0)" }
            + relative.prefix(6)
            + homeRelative.map { "\(home)/\($0)" }
            + ["/etc/hosts", "/etc/passwd", "/tmp/scratch.txt", "/usr/local/bin/node", "", "~/.ssh/id_rsa"]
    }
}
