import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import RVPresentation

struct WorkspaceUpload: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Copy a host file or directory into the live workspace (asks for owner authentication)."
    )

    static let usage = [
        HelpRow(name: "rv workspace upload [--workspace <absolute-path>] [--no-gitignore] <host-path> [<workspace-path>]", description: "Copy host files into the live workspace; .gitignore-aware, never follows symlinks (asks for owner authentication)"),
    ]

    @OptionGroup var path: WorkspacePath

    @Flag(name: .long, help: "Ignore .gitignore files in the copied tree; .git directories are always skipped.")
    var noGitignore = false

    @Argument(help: "Host file or directory to copy. Never rv's config dir; symlinks are refused.")
    var source: String

    @Argument(help: "Workspace-relative destination. Defaults to the source's name at the workspace root; '.' merges a directory into the root.")
    var destination: String?

    func run() async throws {
        try await WorkspaceTransferRun.upload(
            path.workspace, source: source, destination: destination, gitignore: noGitignore == false
        )
    }
}

struct WorkspaceDownload: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Copy a file or directory out of the live workspace to a new host path (asks for owner authentication)."
    )

    static let usage = [
        HelpRow(name: "rv workspace download [--workspace <absolute-path>] [--no-gitignore] <workspace-path> <new-host-path>", description: "Copy workspace files to a new host path; refuses symlinks, special files and rv's own dirs (asks for owner authentication)"),
    ]

    @OptionGroup var path: WorkspacePath

    @Flag(name: .long, help: "Ignore .gitignore files in the copied tree; .git directories are always skipped.")
    var noGitignore = false

    @Argument(help: "Workspace-relative file or directory; '.' is the whole workspace.")
    var source: String

    @Argument(help: "Host path to create. It must not exist yet.")
    var destination: String

    func run() async throws {
        try await WorkspaceTransferRun.download(
            path.workspace, source: source, destination: destination, gitignore: noGitignore == false
        )
    }
}

/// `rv workspace upload|download`. The owner gate runs first, before any
/// host or workspace path is read; the agent-issued form is also refused by
/// `SelfProtectionGuard`. Both need a live workspace: its volume is
/// mounted at the project path, so a transfer with no live workspace would
/// read or write the real project instead, and is refused.
enum WorkspaceTransferRun {
    static func upload(_ raw: String?, source: String, destination: String?, gitignore: Bool) async throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try WorkspaceCommandRun.requireProject(raw)
        let hostSource = absolute(source)
        let target = destination ?? URL(fileURLWithPath: hostSource).lastPathComponent
        let resolved = try resolvedParent(of: hostSource)
        try await OwnerConfirmation.require(
            "upload \(WorkspaceTransfer.escaped(resolved.display)) into the workspace at \(project) as \(WorkspaceTransfer.escaped(target))"
                + (gitignore ? "" : ", ignoring .gitignore")
        )
        let workspace = try liveWorkspaceVolume(project)
        var request = WorkspaceUploadRequest(
            source: hostSource, workspace: workspace, destination: destination,
            protectedRoots: try protectedRoots(includingInstall: false), gitignore: gitignore
        )
        request.approvedParent = resolved.parent
        switch WorkspaceTransfer.upload(request) {
        case .success(let summary):
            emit("uploaded \(lines(summary)) to \(WorkspaceTransfer.escaped(target))")
        case .failure(let refusal):
            throw ValidationError("upload refused: \(refusal)")
        }
        #endif
    }

    static func download(_ raw: String?, source: String, destination: String, gitignore: Bool) async throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try WorkspaceCommandRun.requireProject(raw)
        let hostDestination = absolute(destination)
        let resolved = try resolvedParent(of: hostDestination)
        try await OwnerConfirmation.require(
            "download \(WorkspaceTransfer.escaped(source)) from the workspace at \(project) to \(WorkspaceTransfer.escaped(resolved.display))"
                + (gitignore ? "" : ", ignoring .gitignore")
        )
        let workspace = try liveWorkspaceVolume(project)
        var request = WorkspaceDownloadRequest(
            workspace: workspace, source: source, destination: hostDestination,
            protectedRoots: try protectedRoots(includingInstall: true), gitignore: gitignore
        )
        request.approvedParent = resolved.parent
        switch WorkspaceTransfer.download(request) {
        case .success(let summary):
            emit("downloaded \(lines(summary)) to \(WorkspaceTransfer.escaped(hostDestination))")
        case .failure(let refusal):
            throw ValidationError("download refused: \(refusal)")
        }
        #endif
    }

    static func lines(_ summary: WorkspaceTransferSummary) -> String {
        let ignored = summary.ignored == 0 ? "" : ", \(summary.ignored) ignored"
        return "\(summary.files) file\(summary.files == 1 ? "" : "s") (\(summary.bytes) bytes\(ignored))"
    }

    /// The path the owner approves: its parent with every symlink resolved
    /// (as the transfer will open it), plus the final name. The transfer is
    /// refused if the parent later resolves anywhere else. A parent that
    /// does not resolve is refused here, before the prompt: the owner never
    /// approves a path blind.
    static func resolvedParent(of path: String) throws -> (parent: String, display: String) {
        let url = URL(fileURLWithPath: path)
        let parentPath = url.deletingLastPathComponent().path
        guard let real = realpath(parentPath, nil) else {
            throw ValidationError("\(WorkspaceTransfer.escaped(parentPath)) does not exist or cannot be resolved; nothing was copied")
        }
        let parent = String(cString: real)
        free(real)
        return (parent, (parent == "/" ? "" : parent) + "/" + url.lastPathComponent)
    }

    /// Relative to the shell's directory, not standardized: a `..` the
    /// owner typed reaches the transfer, which refuses it.
    static func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let base = CLIProcess.workspacePath()
        return (base.hasSuffix("/") ? base : base + "/") + path
    }

    /// rv's config dir always; for downloads also where rv is installed and
    /// started from (`RVInstallPathGuard`'s directories).
    static func protectedRoots(includingInstall: Bool) throws -> [String] {
        guard let home = CLIProcess.home()?.rawValue else {
            throw ValidationError("cannot find your home directory")
        }
        let config = ["\(home)/.config/rv"]
        guard includingInstall else { return config }
        return config + [
            "\(home)/.local/bin", "\(home)/Library/LaunchAgents", "\(home)/.config/systemd/user",
            "\(home)/Applications/RVApprovals.app",
        ] + RVWiringPaths.coreMLCacheOwners.map { "\(home)/Library/Caches/\($0)" }
    }

    #if os(macOS)
    /// The project path of a live workspace, after checking it is a mount
    /// point (the workspace volume), so a closed workspace is never the
    /// real project.
    static func liveWorkspaceVolume(_ project: String) throws -> String {
        let attachment = WorkspaceHosts.inspect(project: project)
        guard case .live = attachment else {
            throw ValidationError(WorkspaceCommandRun.text(attachment))
        }
        guard let real = realpath(project, nil) else {
            throw ValidationError("workspace path \(project) is unusable")
        }
        let resolved = String(cString: real)
        free(real)
        var volume = stat()
        var parent = stat()
        let parentPath = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        guard stat(resolved, &volume) == 0, stat(parentPath, &parent) == 0, volume.st_dev != parent.st_dev else {
            throw ValidationError("the workspace volume is not mounted at \(project); nothing was copied")
        }
        return resolved
    }
    #endif

    private static func emit(_ text: String) {
        CommandContext.writeStdout(text + "\n")
    }
}
