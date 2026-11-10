import Foundation
import Testing

@testable import RVIsolation

/// The pre-commit block finds rv at run time. A missing rv must not block
/// a commit, and a tracked hooks directory never gets a personal path.
@Suite struct SecretGitHookBlockTests {
    private struct Fixture {
        let root: URL
        let work: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-hook-block-\(UUID().uuidString)", isDirectory: true)
            work = root.appendingPathComponent("repo", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try git(["init", "-q"])
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", work.path] + args
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        /// A stand-in rv that exits `status`, in its own directory.
        func fakeRV(status: Int32, named name: String = "rv") throws -> URL {
            let bin = root.appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let rv = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\necho fake-rv \"$@\"\nexit \(status)\n".utf8).write(to: rv)
            chmod(rv.path, 0o755)
            return rv
        }

        /// Runs `hook` the way husky does (`sh -e`) with a controlled PATH.
        func run(_ hook: URL, path: String) throws -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-e", hook.path]
            process.currentDirectoryURL = work
            process.environment = ["PATH": path, "HOME": root.path]
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        var defaultHook: URL { work.appendingPathComponent(".git/hooks/pre-commit") }
    }

    private static let systemPath = "/usr/bin:/bin"

    @Test func missingRVLetsTheCommitThroughWithOneClearLine() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: fixture.root.appendingPathComponent("gone/rv").path).get()
        let result = try fixture.run(fixture.defaultHook, path: Self.systemPath)
        #expect(result.status == 0)
        let lines = result.stderr.split(separator: "\n")
        #expect(lines.count == 1, "\(result.stderr)")
        #expect(result.stderr.contains("rv secrets"))
        #expect(result.stderr.contains("not found"))
        #expect(result.stderr.contains("reinstall rv"))
        #expect(result.stderr.contains("rv secrets markers"))
        // The notice must not be mistaken for the block's own marker line.
        #expect(SecretGitHook.missingNotice.contains(SecretGitHook.beginMarker) == false)
    }

    @Test func rvOnPathOrAtTheRecordedPathStillBlocksOnFailure() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let onPath = try fixture.fakeRV(status: 3)
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: fixture.root.appendingPathComponent("gone/rv").path).get()
        let viaPath = try fixture.run(
            fixture.defaultHook, path: onPath.deletingLastPathComponent().path + ":" + Self.systemPath)
        #expect(viaPath.status == 3)

        let recorded = try fixture.fakeRV(status: 4, named: "rv-recorded")
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: recorded.path).get()
        let viaRecorded = try fixture.run(fixture.defaultHook, path: Self.systemPath)
        #expect(viaRecorded.status == 4)
    }

    @Test func trackedHooksDirectoryGetsNoPersonalPath() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let husky = fixture.work.appendingPathComponent(".husky", isDirectory: true)
        try FileManager.default.createDirectory(at: husky, withIntermediateDirectories: true)
        try fixture.git(["config", "core.hooksPath", ".husky"])
        let personal = "/Users/someone-else/.local/bin/rv"
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: personal).get()
        let hook = husky.appendingPathComponent("pre-commit")
        let text = try String(contentsOf: hook, encoding: .utf8)
        #expect(text.contains("command -v rv"))
        #expect(text.contains(personal) == false)
        #expect(try fixture.run(hook, path: Self.systemPath).status == 0)

        try fixture.git(["config", "core.hooksPath", husky.path])
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: personal).get()
        #expect(try String(contentsOf: hook, encoding: .utf8).contains(personal) == false)
    }

    @Test func installUpgradesAnOldBlockInPlaceAndUninstallRemovesIt() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let old = """
            #!/bin/sh
            echo before
            # >>> rv secrets >>>
            # Managed by rv; `rv secrets hook uninstall` removes only this block.
            # Scans staged content and prints path:line:rule, never a value.
            if [ "$(git config --bool rv.secretsScan)" = "false" ]; then
              echo "rv secrets: staged-content scan skipped (git config rv.secretsScan is false)" >&2
            else
              '/old/rv' secrets hook run || exit $?
            fi
            # <<< rv secrets <<<
            echo after

            """
        try Data(old.utf8).write(to: fixture.defaultHook)
        _ = try SecretGitHook.install(workTree: fixture.work, rvPath: "/new/rv").get()
        let text = try String(contentsOf: fixture.defaultHook, encoding: .utf8)
        #expect(text.components(separatedBy: SecretGitHook.beginMarker).count == 2)
        #expect(text.contains("'/old/rv'") == false)
        #expect(text.contains("command -v rv"))
        #expect(text.hasPrefix("#!/bin/sh\necho before\n# >>> rv secrets >>>\n"))
        #expect(text.hasSuffix("# <<< rv secrets <<<\necho after\n"))

        _ = try SecretGitHook.uninstall(workTree: fixture.work).get()
        #expect(try String(contentsOf: fixture.defaultHook, encoding: .utf8) == "#!/bin/sh\necho before\necho after\n")
    }
}
