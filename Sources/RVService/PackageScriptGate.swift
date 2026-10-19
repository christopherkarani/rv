import Foundation
import RVDomain

/// `npm test` judge-blindness fix: the words "npm test" hide whatever
/// `scripts.test` contains. When the packs allowed a runner command, the
/// script bodies it would execute are themselves pack-evaluated. A hit
/// takes that rule's floor; an unresolvable script graph stays allowed
/// here and is left to the judge/human (v1 scope, see plan Phase 5).
enum PackageScriptGate {
    static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    static let verbs: Set<String> = ["test", "build", "lint"]

    /// Returns a deny result when a script body the command would run is
    /// itself denied by the packs; otherwise nil.
    static func check(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        session: EvaluateSession,
        enabledPacks: [PackID]
    ) -> EvaluationResult? {
        guard let cwd, let names = scriptNames(in: command.rawValue) else { return nil }
        guard let packageDir = nearestPackageJSON(from: cwd.rawValue) else { return nil }
        guard let scripts = loadScripts(packageDir) else { return nil }
        for name in names {
            if let hit = checkScript(name, scripts: scripts, session: session, enabledPacks: enabledPacks, depth: 0) {
                return hit
            }
        }
        return nil
    }

    static func scriptNames(in raw: String) -> [String]? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, runners.contains(tokens[0]) else { return nil }
        if tokens[1] == "run" {
            guard tokens.count >= 3 else { return nil }
            return [tokens[2]]
        }
        return verbs.contains(tokens[1]) ? [tokens[1]] : nil
    }

    private static func checkScript(
        _ name: String,
        scripts: [String: String],
        session: EvaluateSession,
        enabledPacks: [PackID],
        depth: Int
    ) -> EvaluationResult? {
        guard depth <= 3 else { return nil }
        for key in ["pre\(name)", name, "post\(name)"] {
            guard let body = scripts[key] else { continue }
            let request = EvaluationRequest(command: ShellCommand(rawValue: body), enabledPacks: enabledPacks)
            let result = session.evaluate(request)
            if case .deny = result.decision {
                return result
            }
            // Follow one nested `npm run <other>` in the body.
            let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for i in tokens.indices.dropLast(2)
            where runners.contains(tokens[i]) && tokens[i + 1] == "run" {
                if let hit = checkScript(tokens[i + 2], scripts: scripts, session: session, enabledPacks: enabledPacks, depth: depth + 1) {
                    return hit
                }
            }
        }
        return nil
    }

    private static func nearestPackageJSON(from cwd: String) -> URL? {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func loadScripts(_ packageDir: URL) -> [String: String]? {
        let file = packageDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = root["scripts"] as? [String: String]
        else { return nil }
        return scripts
    }
}
