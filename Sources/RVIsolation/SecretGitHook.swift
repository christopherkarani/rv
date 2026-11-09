#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// The block `rv secrets hook install` adds to the git pre-commit hook. It
/// scans the index, not the worktree, and leaves the rest of the hook alone.
public struct SecretGitHookError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum SecretGitHook {
    public static let beginMarker = "# >>> rv secrets >>>"
    public static let endMarker = "# <<< rv secrets <<<"
    /// `git config rv.secretsScan false` skips the scan with a notice.
    public static let killSwitch = "rv.secretsScan"
    /// The previous installer replaced the whole hook and moved the old one aside.
    static let legacyMarker = "# rv-secrets-hook"
    static let legacySavedName = "pre-commit.rv-saved"
    /// Staged bytes read per `git cat-file --batch` call, bounding memory.
    static let batchBytes = 64 * 1024 * 1024
    /// Output cap for the staged-file listing; reaching it fails the scan.
    static let listingBytes = 64 * 1024 * 1024
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// Printed, once, when the hook runs where rv is not installed. The
    /// commit goes on: a teammate without rv must not be blocked by a
    /// scanner they never installed.
    static let missingNotice =
        "rv secrets: rv not found, so staged files were not scanned; reinstall rv, "
        + "or run `rv secrets hook uninstall` (or delete the \(beginMarker) block from this hook)"

    /// rv is found on PATH when the hook runs, then at `rvPath` (where
    /// install ran from). `rvPath` nil writes the PATH lookup only, for a
    /// hooks directory other people check out. `|| true` keeps a missing
    /// rv from tripping `sh -e` (husky) before the notice.
    static func block(rvPath: String?) -> String {
        let fallback = rvPath.map {
            "\n  if [ -z \"$rv_secrets_bin\" ] && [ -x \(shellQuote($0)) ]; then rv_secrets_bin=\(shellQuote($0)); fi"
        } ?? ""
        return """
            \(beginMarker)
            # Managed by rv; `rv secrets hook uninstall` removes only this block.
            # Scans staged content and prints path:line:rule, never a value.
            if [ "$(git config --bool \(killSwitch))" = "false" ]; then
              echo "rv secrets: staged-content scan skipped (git config \(killSwitch) is false)" >&2
            else
              rv_secrets_bin="$(command -v rv 2>/dev/null || true)"\(fallback)
              if [ -n "$rv_secrets_bin" ]; then
                "$rv_secrets_bin" secrets hook run || exit $?
              else
                echo \(shellQuote(missingNotice)) >&2
              fi
            fi
            \(endMarker)

            """
    }

    /// True when git would run hooks from a directory inside the work
    /// tree (husky's `.husky/`), which is committed and shared.
    static func hooksAreShared(_ hooks: URL, workTree: URL) -> Bool {
        guard let configured = gitOutput(workTree, ["config", "--get", "core.hooksPath"]), configured.isEmpty == false,
            let top = gitOutput(workTree, ["rev-parse", "--show-toplevel"])
        else { return false }
        func real(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        let directory = real(hooks.path)
        guard inside(directory, real(top)) else { return false }
        if let gitDirectory = gitOutput(workTree, ["rev-parse", "--absolute-git-dir"]),
            inside(directory, real(gitDirectory))
        {
            return false
        }
        return true
    }

    public static func install(workTree: URL, rvPath: String) -> Result<String, SecretGitHookError> {
        guard let hooks = hooksDirectory(workTree) else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        let hook = hooks.appendingPathComponent("pre-commit")
        let saved = hooks.appendingPathComponent(legacySavedName)
        if isSymlink(hook) {
            return .failure(SecretGitHookError("\(hook.path) is a symlink; add `rv secrets hook run` to its target yourself"))
        }
        var existing: String
        switch readText(hook) {
        case .failure(let error): return .failure(error)
        case .success(let text): existing = text
        }
        let legacy = isLegacy(existing)
        if legacy {
            switch readText(saved) {
            case .failure(let error): return .failure(error)
            case .success(let text): existing = text
            }
        }
        let shared = hooksAreShared(hooks, workTree: workTree)
        let updated: String
        switch insert(block(rvPath: shared ? nil : rvPath), into: existing) {
        case .failure(let error): return .failure(error)
        case .success(let text): updated = text
        }
        guard OwnerOnlyFile.write(Data(updated.utf8), to: hook) else {
            return .failure(SecretGitHookError("could not write \(hook.path)"))
        }
        chmod(hook.path, 0o755)
        if legacy { unlink(saved.path) }
        let configured = (gitOutput(workTree, ["config", "--get", "core.hooksPath"]) ?? "").isEmpty == false
        let location = shared
            ? " (core.hooksPath, inside the repository: the block finds rv on PATH and writes no local path)"
            : configured ? " (core.hooksPath)" : ""
        return .success("installed rv's block in \(hook.path)\(location). `rv secrets hook uninstall` removes only that block.\n")
    }

    /// File text, or "" when the file does not exist. A file that exists but
    /// cannot be read as UTF-8 is an error, so install never overwrites it.
    private static func readText(_ url: URL) -> Result<String, SecretGitHookError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success("") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return .failure(SecretGitHookError("\(url.path) is not readable UTF-8 text; add `rv secrets hook run` to it yourself"))
        }
        return .success(text)
    }

    public static func uninstall(workTree: URL) -> Result<String, SecretGitHookError> {
        guard let hooks = hooksDirectory(workTree) else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        let hook = hooks.appendingPathComponent("pre-commit")
        let saved = hooks.appendingPathComponent(legacySavedName)
        let existing = (try? String(contentsOf: hook, encoding: .utf8)) ?? ""
        if isLegacy(existing) {
            guard unlink(hook.path) == 0 else { return .failure(SecretGitHookError("could not remove \(hook.path)")) }
            guard FileManager.default.fileExists(atPath: saved.path) else { return .success("removed rv's pre-commit hook.\n") }
            do { try FileManager.default.moveItem(at: saved, to: hook) } catch {
                return .failure(SecretGitHookError("removed rv's hook but could not restore \(legacySavedName)"))
            }
            return .success("removed rv's pre-commit hook and restored the previous one.\n")
        }
        guard let remainder = removingBlock(from: existing) else {
            return .failure(SecretGitHookError("pre-commit has no rv secrets block"))
        }
        let onlyShebang = remainder.split(whereSeparator: \.isNewline).allSatisfy {
            $0.hasPrefix("#!") || $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if onlyShebang {
            guard unlink(hook.path) == 0 else { return .failure(SecretGitHookError("could not remove \(hook.path)")) }
            return .success("removed rv's pre-commit hook.\n")
        }
        guard OwnerOnlyFile.write(Data(remainder.utf8), to: hook) else {
            return .failure(SecretGitHookError("could not write \(hook.path)"))
        }
        chmod(hook.path, 0o755)
        return .success("removed rv's block from \(hook.path); the rest of the hook is unchanged.\n")
    }

    /// Replaces rv's block in place, or adds it right after the shebang so
    /// it runs before anything that could `exit 0` early.
    static func insert(_ block: String, into existing: String) -> Result<String, SecretGitHookError> {
        if let marker = existing.range(of: beginMarker) {
            guard let remainder = removingBlock(from: existing) else {
                return .failure(SecretGitHookError("pre-commit has an rv secrets block with no end marker"))
            }
            let lineStart = existing[..<marker.lowerBound].lastIndex(of: "\n").map { existing.index(after: $0) }
                ?? existing.startIndex
            let at = remainder.index(remainder.startIndex, offsetBy: existing.distance(from: existing.startIndex, to: lineStart))
            return .success(String(remainder[..<at]) + block + String(remainder[at...]))
        }
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .success("#!/bin/sh\n" + block)
        }
        let firstLine = existing.prefix { $0 != "\n" }
        guard isShellShebang(String(firstLine)) else {
            return .failure(SecretGitHookError(
                "pre-commit is not a shell script; add `rv secrets hook run` to it yourself"))
        }
        let rest = existing.dropFirst(firstLine.count + 1)
        return .success(String(firstLine) + "\n" + block + String(rest))
    }

    /// The hook without rv's block, or nil when there is no complete block.
    static func removingBlock(from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }),
            let end = lines[begin...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker })
        else { return nil }
        lines.removeSubrange(begin...end)
        return lines.joined(separator: "\n")
    }

    static func isShellShebang(_ line: String) -> Bool {
        guard line.hasPrefix("#!") else { return false }
        let words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = words.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        if interpreter == "env" { return words.dropFirst().first.map(shells.contains) ?? false }
        return shells.contains(interpreter)
    }

    /// True only for the whole-file hook the previous installer generated.
    static func isLegacy(_ existing: String) -> Bool {
        existing.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == legacyMarker
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// One staged file: its index blob, not the worktree copy.
    struct StagedBlob: Equatable {
        var path: String
        var object: String
        var size: Int
    }

    /// Scans every staged blob in memory, a bounded batch at a time. Files
    /// over `SecretLeakScanner.maximumFileBytes` are reported, not read.
    public static func scan(
        workTree: URL, secrets: [(name: String, value: SecretValue)],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<SecretLeakReport, SecretGitHookError> {
        let gitEnv = gitEnvironment(inheriting: environment)
        guard let git = SecretCommandProviders.executable("git", environment: ProcessInfo.processInfo.environment) else {
            return .failure(SecretGitHookError("git is not installed"))
        }
        let blobs: [StagedBlob]
        switch staged(git: git, workTree: workTree, environment: gitEnv) {
        case .failure(let error): return .failure(error)
        case .success(let found): blobs = found
        }
        let top = gitOutput(workTree, ["rev-parse", "--show-toplevel"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let ignore = top.map(SecretLeakIgnore.load(from:)) ?? SecretLeakIgnore(text: "")
        let limit = SecretLeakScanner.maximumFileBytes
        var findings: [SecretLeakFinding] = []
        for batch in batches(blobs.filter { $0.size <= limit }) {
            switch read(batch, git: git, workTree: workTree, environment: gitEnv) {
            case .failure(let error): return .failure(error)
            case .success(let files): findings += SecretLeakScanner.scan(files: files, secrets: secrets, ignore: ignore)
            }
        }
        let tooLarge = blobs.filter { $0.size > limit }.map(\.path).sorted()
        return .success(SecretLeakReport(findings: SecretLeakScanner.sorted(findings), tooLarge: tooLarge))
    }

    /// Added, copied, modified, or type-changed paths in the index, with blob
    /// ids and sizes. Submodule entries are commits, not content, and are left out.
    static func staged(
        git: String, workTree: URL, environment: [String: String], listingLimit: Int = listingBytes
    ) -> Result<[StagedBlob], SecretGitHookError> {
        // The collector drops output past its cap and the child still exits 0,
        // so a full buffer means entries may be missing: fail closed.
        let tooMany = SecretGitHookError("too many staged files to list")
        guard let listed = BoundedProcess.run(
            git, ["-C", workTree.path, "diff", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev", "--diff-filter=ACMT"],
            environment: environment, maximumOutputBytes: listingLimit)
        else { return .failure(SecretGitHookError("git diff did not finish")) }
        guard listed.status == 0 else { return .failure(SecretGitHookError("\(workTree.path) is not a git repository")) }
        guard listed.stdout.count < listingLimit else { return .failure(tooMany) }
        var entries: [(path: String, object: String)] = []
        let fields = splitNull(listed.stdout)
        var index = 0
        while index + 1 < fields.count {
            // ":<old mode> <new mode> <old id> <new id> <status>", then the path.
            let meta = fields[index].split(separator: " ")
            let path = fields[index + 1]
            index += 2
            guard meta.count >= 5, meta[1] != "160000" else { continue }
            entries.append((path, String(meta[3])))
        }
        guard entries.isEmpty == false else { return .success([]) }
        let failed = SecretGitHookError("could not list the staged files")
        guard let checked = BoundedProcess.run(
            git, ["-C", workTree.path, "cat-file", "--batch-check"], environment: environment,
            maximumOutputBytes: listingLimit, input: Array(entries.map { $0.object + "\n" }.joined().utf8)),
            checked.status == 0
        else { return .failure(failed) }
        guard checked.stdout.count < listingLimit else { return .failure(tooMany) }
        let rows = String(decoding: checked.stdout, as: UTF8.self).split(separator: "\n")
        guard rows.count == entries.count else { return .failure(failed) }
        var blobs: [StagedBlob] = []
        for (entry, row) in zip(entries, rows) {
            let parts = row.split(separator: " ")
            guard parts.count == 3, parts[1] == "blob", let size = Int(parts[2]) else {
                return .failure(SecretGitHookError("could not read the staged copy of \(DisplayedText.field(entry.path))"))
            }
            blobs.append(StagedBlob(path: entry.path, object: entry.object, size: size))
        }
        return .success(blobs)
    }

    static func batches(_ blobs: [StagedBlob]) -> [[StagedBlob]] {
        var batches: [[StagedBlob]] = []
        var current: [StagedBlob] = []
        var bytes = 0
        for blob in blobs {
            if current.isEmpty == false, bytes + blob.size > batchBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(blob)
            bytes += blob.size
        }
        if current.isEmpty == false { batches.append(current) }
        return batches
    }

    /// Blob contents straight from `git cat-file --batch` into memory.
    static func read(
        _ batch: [StagedBlob], git: String, workTree: URL, environment: [String: String]
    ) -> Result<[(path: String, bytes: [UInt8])], SecretGitHookError> {
        let failed = SecretGitHookError("could not read the staged files")
        let expected = batch.reduce(0) { $0 + $1.size + $1.object.count + 32 }
        guard let run = BoundedProcess.run(
            git, ["-C", workTree.path, "cat-file", "--batch"], environment: environment, timeout: 120,
            maximumOutputBytes: expected, input: Array(batch.map { $0.object + "\n" }.joined().utf8)),
            run.status == 0
        else { return .failure(failed) }
        let output = run.stdout
        var files: [(path: String, bytes: [UInt8])] = []
        var cursor = 0
        for blob in batch {
            // "<id> blob <size>\n<content>\n"
            guard cursor < output.count, let newline = output[cursor...].firstIndex(of: 10) else { return .failure(failed) }
            let header = String(decoding: output[cursor..<newline], as: UTF8.self)
            let start = newline + 1
            guard header == "\(blob.object) blob \(blob.size)", start + blob.size < output.count else {
                return .failure(failed)
            }
            files.append((blob.path, Array(output[start..<(start + blob.size)])))
            cursor = start + blob.size + 1
        }
        return .success(files)
    }

    private static var gitEnvironment: [String: String] { gitEnvironment(inheriting: ProcessInfo.processInfo.environment) }

    /// PATH and HOME, plus the variables git sets for a hook that tell it
    /// which index and object store the commit uses. `git commit -a` and
    /// `git commit <paths>` stage into a temporary index and leave
    /// `.git/index` stale, so reading the default index would miss them.
    /// Relative paths are made absolute against the current directory, the
    /// one the hook started in.
    static func gitEnvironment(inheriting inherited: [String: String]) -> [String: String] {
        var environment = [
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin",
            "HOME": inherited["HOME"] ?? "/tmp",
        ]
        let current = FileManager.default.currentDirectoryPath
        for key in ["GIT_INDEX_FILE", "GIT_DIR", "GIT_OBJECT_DIRECTORY"] {
            guard let value = inherited[key], value.isEmpty == false else { continue }
            environment[key] = value.hasPrefix("/") ? value : current + "/" + value
        }
        if let alternates = inherited["GIT_ALTERNATE_OBJECT_DIRECTORIES"], alternates.isEmpty == false {
            environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = alternates
        }
        return environment
    }

    /// The hooks directory git will actually run from: core.hooksPath when
    /// configured (relative resolves against the work tree), else the
    /// common git dir's hooks — which is also where linked worktrees look.
    static func hooksDirectory(_ workTree: URL) -> URL? {
        if let configured = gitOutput(workTree, ["config", "--get", "core.hooksPath"]),
            configured.isEmpty == false
        {
            let url = configured.hasPrefix("/")
                ? URL(fileURLWithPath: configured, isDirectory: true)
                : workTree.appendingPathComponent(configured, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        guard let common = gitOutput(workTree, ["rev-parse", "--git-common-dir"]), common.isEmpty == false else {
            return nil
        }
        let base = common.hasPrefix("/")
            ? URL(fileURLWithPath: common, isDirectory: true)
            : workTree.appendingPathComponent(common, isDirectory: true)
        let url = base.appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func gitOutput(_ workTree: URL, _ arguments: [String]) -> String? {
        guard let git = SecretCommandProviders.executable("git", environment: ProcessInfo.processInfo.environment),
            let run = BoundedProcess.run(git, ["-C", workTree.path] + arguments, environment: gitEnvironment),
            run.status == 0
        else { return nil }
        let text = String(decoding: run.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("\n") == false else { return nil }
        return text
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
