#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVEngine
import RVIPC
import RVPolicy
@testable import RVService

struct LinuxResidualCoverageTests {
    @Test func unixSocketPath_injectedEnvironmentAndPathTooLong() throws {
        let socket = try UnixSocketPath.production(environment: ["XDG_RUNTIME_DIR": "/run/user/1"])
        #expect(socket.path == "/run/user/1/rv/evaluate.sock")
        #expect(throws: UnixSocketPathError.pathTooLong) {
            _ = try UnixSocketPath.resolve(xdgRuntimeDir: "/" + String(repeating: "x", count: 120))
        }
    }

    @Test func unixSocketPath_prepareRuntimeRemovesStaleSocket() throws {
        // Darwin TMPDIR plus a UUID overflows sockaddr_un (108 bytes) in resolve.
        let token = String(UInt32.random(in: .min ... .max), radix: 16)
        let xdg = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvx-\(token)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        try UnixSocketPath.prepareRuntime(for: socket)
        try Data("stale".utf8).write(to: socket)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        try UnixSocketPath.prepareRuntime(for: socket)
        #expect(FileManager.default.fileExists(atPath: socket.path) == false)
    }

    @Test func gitRebaseProbe_missingCwdIsFalse() {
        #expect(GitRebaseProbe.rebaseInProgress(cwd: nil) == false)
    }

    @Test func serviceIdentityAndIncomingReply() {
        #expect(RVService.machServiceName == "dev.rv.evaluate")
        let reply = IncomingReply(frame: Data([1, 2]), handshakeAccepted: true)
        #expect(reply.handshakeAccepted)
        #expect(reply.frame == Data([1, 2]))
    }

    @Test func evaluationWorld_matchingViewNormalizes() {
        let view = EvaluationWorld.matchingView(of: ShellCommand(rawValue: "  git   status  "))
        #expect(view.rawValue.contains("git"))
    }

    @Test func coreWarmup_brokenSnapshotsAreNotReady() {
        let snapshots = BrokenCoreSnapshots.uncompilableResetHard()
        let warmed = CoreWarmup.prepare(
            snapshots: snapshots,
            enabledPacks: [.coreFilesystem, .coreGit],
            engine: ICUPatternEngine()
        )
        #expect(warmed.ready == false)
        #expect(warmed.compiled.packs.isEmpty)
    }

#if os(Linux)
    @Test func unixFrameIO_sockaddrRejectsPathTooLong() {
        let long = "/" + String(repeating: "x", count: 200)
        #expect(throws: UnixFrameError.pathTooLong) {
            _ = try UnixFrameIO.sockaddr(path: long)
        }
    }
#endif

    @Test func filesystemLiveProbe_unwrapCompleteAndLimited() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-probe-unwrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "x".write(to: repo.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let complete = FilesystemLiveProbe.context(
            unwrapped: .complete(
                UnwrappedCommand(
                    command: ShellCommand(rawValue: "rm file"),
                    workingDirectory: cwd
                )
            ),
            command: ShellCommand(rawValue: "bash -c 'rm file'"),
            cwd: WorkingDirectory(validating: "/tmp"),
            homeDirectory: nil
        )
        guard case .probed(let extracted) = complete else {
            Issue.record("complete unwrap must probe the inner command")
            return
        }
        #expect(extracted.repositoryRoot?.rawValue == resolveExistingDirectory(repo.path))

        let limited = FilesystemLiveProbe.context(
            unwrapped: .limited(layers: []),
            command: ShellCommand(rawValue: "echo hi > file"),
            cwd: cwd,
            homeDirectory: nil
        )
        guard case .probed = limited else {
            Issue.record("limited unwrap must still probe the original command")
            return
        }
    }

    @Test func filesystemLiveProbe_symlinkLoopHopLimitDanglingAndWalkUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-probe-sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let nested = root.appendingPathComponent("src/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(FilesystemLiveProbe.discoverRepositoryRoot(from: nested.path)?.rawValue == resolveExistingDirectory(root.path))

        let target = root.appendingPathComponent("target")
        try "dest".write(to: target, atomically: true, encoding: .utf8)
        let relative = root.appendingPathComponent("rel-link")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "target")
        let relativeFact = FilesystemLiveProbe.resolve(
            apparent: "rel-link",
            workingDirectory: root.path,
            homeDirectory: nil
        )
        #expect(relativeFact.followedSymlink)

        let a = root.appendingPathComponent("loop-a")
        let b = root.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
        let loop = FilesystemLiveProbe.resolve(
            apparent: "loop-a",
            workingDirectory: root.path,
            homeDirectory: nil
        )
        #expect(loop.resolution == .uncertain)

        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: "missing-\(UUID().uuidString)"
        )
        let danglingFact = FilesystemLiveProbe.resolve(
            apparent: "dangling",
            workingDirectory: root.path,
            homeDirectory: nil
        )
        #expect(danglingFact.followedSymlink)

        var current = target
        for index in 0..<10 {
            let hop = root.appendingPathComponent("hop-\(index)")
            try FileManager.default.createSymbolicLink(atPath: hop.path, withDestinationPath: current.path)
            current = hop
        }
        let hops = FilesystemLiveProbe.resolve(
            apparent: current.lastPathComponent,
            workingDirectory: root.path,
            homeDirectory: nil
        )
        #expect(hops.resolution == .uncertain)

        let fileCwd = root.appendingPathComponent("not-a-dir")
        try "file".write(to: fileCwd, atomically: true, encoding: .utf8)
        let world = FilesystemLiveProbe.context(
            command: ShellCommand(rawValue: "echo hi > x"),
            cwd: WorkingDirectory(validating: fileCwd.path),
            homeDirectory: nil
        )
        guard case .probed(let probed) = world else {
            Issue.record("file cwd must still be probed")
            return
        }
        #expect(probed.facts.allSatisfy { $0.resolution == .lexical || $0.resolution == .uncertain })
    }

    @Test func serviceRuntime_dispatchResiduals() async throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let log = RecordingLog()
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            log: log,
            pendingApprovals: .missing
        )

        let skew = await runtime.dispatch(
            IPCRequest(protocolName: "rv.ipc.wrong", method: .listPacks)
        )
        guard case .error(.protocolSkew(.protocolSkew)) = skew.result else {
            Issue.record("wrong protocol must skew")
            return
        }

        let major = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "ls"),
                            enabledPacks: dayOnePackIDs
                        ),
                        clientSemver: "99.0.0"
                    )
                )
            )
        )
        guard case .error(.protocolSkew(.majorVersion)) = major.result else {
            Issue.record("major client semver must skew")
            return
        }

        let unknown = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(SetPackEnabledParams(id: PackID(rawValue: "core.unknown"), enabled: false)))
        )
        guard case .error(.packNotFound(_)) = unknown.result else {
            Issue.record("unknown pack must be packNotFound, got \(unknown.result)")
            return
        }

        let listed = await runtime.dispatch(IPCRequest(method: .listPacks))
        guard case .listPacks(let packs) = listed.result else {
            Issue.record("listPacks must reply")
            return
        }
        #expect(packs.totalCount > 0)

        let doctor = await runtime.dispatch(IPCRequest(method: .doctorSnapshot))
        guard case .doctorSnapshot = doctor.result else {
            Issue.record("doctorSnapshot must reply")
            return
        }

        let pending = await runtime.dispatch(IPCRequest(method: .pendingList))
        guard case .error(.pendingCoordinatorUnavailable) = pending.result else {
            Issue.record("missing coordinator must fail pendingList")
            return
        }
        let watch = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: 0)))
        )
        guard case .error(.pendingCoordinatorUnavailable) = watch.result else {
            Issue.record("missing coordinator must fail pendingWatch")
            return
        }

        let huge = String(repeating: "x", count: 70_000)
        let classified = await runtime.dispatch(
            IPCRequest(
                method: .classify(
                    ClassifyParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: huge),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .classify(let classifyReply) = classified.result else {
            Issue.record("classify huge command must reply")
            return
        }
        #expect(classifyReply.suggestions == ["Run it in Terminal."])

        let explained = await runtime.dispatch(
            IPCRequest(
                method: .explain(
                    ExplainParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: huge),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .explain(let explainReply) = explained.result else {
            Issue.record("explain huge command must reply")
            return
        }
        #expect(explainReply.suggestion == "Run it in Terminal.")

        let denyExplain = await runtime.dispatch(
            IPCRequest(
                method: .explain(
                    ExplainParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .explain(let denyReply) = denyExplain.result else {
            Issue.record("explain deny must reply")
            return
        }
        #expect(denyReply.suggestion == "Run it in Terminal, or rv allow-once.")

        let decode = await runtime.handleIncoming(Data("not-json".utf8), handshakeOK: true)
        #expect(decode.handshakeAccepted)
        let decodeResponse = try IPCJSON.decode(IPCResponse.self, from: decode.frame)
        guard case .error(.decodeFailed) = decodeResponse.result else {
            Issue.record("garbage body must decode-fail")
            return
        }

        let emptyHello = await runtime.handleIncoming(
            try IPCJSON.encode(Hello(protocolName: ProtocolVersion.name, clientSemver: "")),
            handshakeOK: false
        )
        #expect(emptyHello.handshakeAccepted == false)
        #expect(log.snapshot.isEmpty == false)
    }

    @Test func serviceRuntime_missingHomeCannotEnablePack() async throws {
        let previous = getenv("HOME").map { String(cString: $0) }
        unsetenv("HOME")
        defer {
            if let previous {
                setenv("HOME", previous, 1)
            } else {
                unsetenv("HOME")
            }
        }
        let runtime = ServiceRuntime(allowOnceDirectory: try isolatedAllowOnceDirectory())
        let reply = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(SetPackEnabledParams(id: .coreGit, enabled: false)))
        )
        guard case .error(.packEnableFailed) = reply.result else {
            Issue.record("nil HOME must fail pack enable, got \(reply.result)")
            return
        }
    }
}
