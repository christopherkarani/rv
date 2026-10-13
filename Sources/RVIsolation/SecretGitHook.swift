import Foundation

/// The git pre-commit hook `rv secrets hook install` writes. It scans the
/// index, not the worktree, and chains any hook that was already there.
public struct SecretGitHookError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum SecretGitHook {
    public static let marker = "# rv-secrets-hook"
    public static let savedName = "pre-commit.rv-saved"

    public static func install(workTree: URL, rvPath: String) -> Result<String, SecretGitHookError> {
        guard let hooks = hooksDirectory(workTree) else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        let hook = hooks.appendingPathComponent("pre-commit")
        let saved = hooks.appendingPathComponent(savedName)
        let existing = (try? String(contentsOf: hook, encoding: .utf8)) ?? ""
        if existing.contains(marker) == false, existing.isEmpty == false {
            guard FileManager.default.fileExists(atPath: saved.path) == false else {
                return .failure(SecretGitHookError("pre-commit is not rv's hook, and \(savedName) already exists"))
            }
            do {
                try FileManager.default.moveItem(at: hook, to: saved)
            } catch {
                return .failure(SecretGitHookError("could not keep the existing pre-commit hook"))
            }
            chmod(saved.path, 0o755)
        }
        let script = """
            #!/bin/sh
            \(marker)
            # Scans the staged contents. Prints file:line:name and never a value.
            rv=\(shellQuote(rvPath))
            "$rv" secrets hook run
            status=$?
            if [ "$status" -ne 0 ]; then
              exit "$status"
            fi
            saved="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/\(savedName)"
            if [ -x "$saved" ]; then
              exec "$saved" "$@"
            fi
            exit 0

            """
        guard OwnerOnlyFile.write(Data(script.utf8), to: hook) else {
            return .failure(SecretGitHookError("could not write \(hook.path)"))
        }
        chmod(hook.path, 0o755)
        let kept = FileManager.default.fileExists(atPath: saved.path) ? " Kept the previous hook as \(savedName)." : ""
        return .success("installed \(hook.path).\(kept) `rv secrets hook uninstall` removes it.\n")
    }

    public static func uninstall(workTree: URL) -> Result<String, SecretGitHookError> {
        guard let hooks = hooksDirectory(workTree) else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        let hook = hooks.appendingPathComponent("pre-commit")
        let saved = hooks.appendingPathComponent(savedName)
        let existing = (try? String(contentsOf: hook, encoding: .utf8)) ?? ""
        guard existing.contains(marker) else {
            return .failure(SecretGitHookError("pre-commit is not an rv secrets hook"))
        }
        guard unlink(hook.path) == 0 else { return .failure(SecretGitHookError("could not remove \(hook.path)")) }
        if FileManager.default.fileExists(atPath: saved.path) {
            do { try FileManager.default.moveItem(at: saved, to: hook) } catch {
                return .failure(SecretGitHookError("removed rv's hook but could not restore \(savedName)"))
            }
            return .success("removed rv's pre-commit hook and restored the previous one.\n")
        }
        return .success("removed rv's pre-commit hook.\n")
    }

    /// Bytes of each staged path, read from the index.
    public static func staged(workTree: URL) -> Result<[(path: String, bytes: [UInt8])], SecretGitHookError> {
        guard let git = SecretCommandProviders.executable("git", environment: ProcessInfo.processInfo.environment) else {
            return .failure(SecretGitHookError("git is not installed"))
        }
        let environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/tmp",
        ]
        guard let listed = BoundedProcess.run(
            git, ["-C", workTree.path, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"],
            environment: environment)
        else { return .failure(SecretGitHookError("git diff did not finish")) }
        guard listed.status == 0 else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        let names = splitNull(listed.stdout).filter { $0.isEmpty == false }
        var files: [(path: String, bytes: [UInt8])] = []
        for name in names {
            guard let shown = BoundedProcess.run(git, ["-C", workTree.path, "show", ":\(name)"], environment: environment),
                shown.status == 0
            else { continue }
            files.append((name, shown.stdout))
        }
        return .success(files)
    }

    public static func scan(workTree: URL, secrets: [(name: String, value: SecretValue)]) -> Result<[SecretLeakFinding], SecretGitHookError> {
        switch staged(workTree: workTree) {
        case .failure(let error): return .failure(error)
        case .success(let files):
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-secrets-hook-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                for file in files {
                    let url = root.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard file.bytes.count <= SecretLeakScanner.maximumFileBytes else { continue }
                    try Data(file.bytes).write(to: url)
                }
            } catch {
                return .failure(SecretGitHookError("could not read the staged files"))
            }
            return .success(SecretLeakScanner.scan(root: root, secrets: secrets))
        }
    }

    static func hooksDirectory(_ workTree: URL) -> URL? {
        guard let git = SecretCommandProviders.executable("git", environment: ProcessInfo.processInfo.environment),
            let run = BoundedProcess.run(
                git, ["-C", workTree.path, "rev-parse", "--absolute-git-dir"],
                environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"]),
            run.status == 0
        else { return nil }
        let text = String(decoding: run.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), text.contains("\n") == false else { return nil }
        let url = URL(fileURLWithPath: text).appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func splitNull(_ bytes: [UInt8]) -> [String] {
        var parts: [String] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 0 {
                parts.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(byte)
            }
        }
        if current.isEmpty == false { parts.append(String(decoding: current, as: UTF8.self)) }
        return parts
    }
}
