import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVIsolation
@testable import RVCLI

struct WorkspaceTransferCommandTests {
    @Test func transfersAreRefusedWithoutOwnerAuthenticationBeforeTouchingAnyPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-transfer-cli-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/host", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("secret".utf8).write(to: URL(fileURLWithPath: root + "/host/f"))
        #if os(macOS)
        await #expect(throws: ExitCode(EX_NOPERM)) {
            try await withCLIProcess(home: try isolatedHome()) {
                try await WorkspaceTransferRun.upload(root + "/ws", source: root + "/host/f", destination: nil, gitignore: true)
            }
        }
        await #expect(throws: ExitCode(EX_NOPERM)) {
            try await withCLIProcess(home: try isolatedHome()) {
                try await WorkspaceTransferRun.download(root + "/ws", source: "f", destination: root + "/out", gitignore: true)
            }
        }
        #else
        await #expect(throws: ValidationError.self) {
            try await WorkspaceTransferRun.upload(root + "/ws", source: root + "/host/f", destination: nil, gitignore: true)
        }
        #endif
        #expect(FileManager.default.fileExists(atPath: root + "/ws") == false)
        #expect(FileManager.default.fileExists(atPath: root + "/out") == false)
    }

    @Test func relativePathsKeepTheirParentReferencesForTheTransferToRefuse() throws {
        try withCLIProcess(workspacePath: "/work/proj") {
            #expect(WorkspaceTransferRun.absolute("data/x") == "/work/proj/data/x")
            #expect(WorkspaceTransferRun.absolute("../secret") == "/work/proj/../secret")
            #expect(WorkspaceTransferRun.absolute("/abs") == "/abs")
        }
    }

    @Test func downloadsAlsoProtectRvInstallDirectories() throws {
        let home = try isolatedHome()
        try withCLIProcess(home: home) {
            let upload = try WorkspaceTransferRun.protectedRoots(includingInstall: false)
            let download = try WorkspaceTransferRun.protectedRoots(includingInstall: true)
            #expect(upload == ["\(home.rawValue)/.config/rv"])
            #expect(download.contains("\(home.rawValue)/.local/bin"))
            #expect(download.contains("\(home.rawValue)/Library/LaunchAgents"))
            #expect(download.contains("\(home.rawValue)/Library/Caches/rvd"))
            #expect(download.contains("\(home.rawValue)/Library/Caches/rv-judge"))
        }
    }

    @Test func theOwnerApprovesTheResolvedParent() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("rv-transfer-cli-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: created + "/real", withIntermediateDirectories: true)
        let root = try #require(realpath(created, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(symlink(root + "/real", root + "/link") == 0)
        let resolved = try WorkspaceTransferRun.resolvedParent(of: root + "/link/out")
        #expect(resolved.parent == root + "/real")
        #expect(resolved.display == root + "/real/out")
        #expect(throws: ValidationError.self) { try WorkspaceTransferRun.resolvedParent(of: root + "/missing/out") }
    }

    @Test func anUnresolvableParentIsRefusedBeforeTheOwnerPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-transfer-cli-\(UUID().uuidString)").path
        #if os(macOS)
        // No owner authentication is given: reaching the prompt would exit
        // EX_NOPERM, so a ValidationError means the refusal came first.
        await #expect(throws: ValidationError.self) {
            try await withCLIProcess(home: try isolatedHome()) {
                try await WorkspaceTransferRun.upload(root + "/ws", source: root + "/missing/f", destination: nil, gitignore: true)
            }
        }
        await #expect(throws: ValidationError.self) {
            try await withCLIProcess(home: try isolatedHome()) {
                try await WorkspaceTransferRun.download(root + "/ws", source: "f", destination: root + "/missing/out", gitignore: true)
            }
        }
        #endif
        #expect(FileManager.default.fileExists(atPath: root) == false)
    }

    @Test func summaryLine() {
        let summary = WorkspaceTransferSummary(files: 2, directories: 1, bytes: 10, ignored: 3)
        #expect(WorkspaceTransferRun.lines(summary) == "2 files (10 bytes, 3 ignored)")
    }

    @Test func helpTopicCoversTransferCommands() {
        #expect(HelpDispatch.topic(arguments: ["workspace", "upload", "--help"]) == .workspace)
        #expect(HelpDispatch.topic(arguments: ["workspace", "download", "--help"]) == .workspace)
    }
}
