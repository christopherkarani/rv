import Foundation
import Testing
@testable import RVService

struct LaunchdPlistTests {
    @Test func templateIsOnDemandNotKeepAlive() throws {
        let url = packageRoot()
            .appendingPathComponent("Sources/RVCLI/Resources/launchd")
            .appendingPathComponent("dev.rv.evaluate.plist")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(object as? [String: Any])
        #expect(plist["Label"] as? String == "dev.rv.evaluate")
        let mach = try #require(plist["MachServices"] as? [String: Any])
        #expect(mach["dev.rv.evaluate"] as? Bool == true)
        #expect((plist["KeepAlive"] as? Bool) != true)
        #expect((plist["RunAtLoad"] as? Bool) != true)
    }

    #if os(Linux)
    @Test func linuxAcceptsSocketFlag() throws {
        let flagged = try RVDLaunch.parse(arguments: ["rvd", "--socket"])
        #expect(flagged.idleExitSeconds == 300)
        let equals = try RVDLaunch.parse(arguments: ["rvd", "--socket=/ignored"])
        #expect(equals.idleExitSeconds == 300)
        #expect(equals.printVersion == false)
    }

    @Test func linuxSocketSourcesHaveNoBSDFlags() throws {
        let url = packageRoot()
            .appendingPathComponent("Sources/RVService/UnixFrameTransport.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("sun_len") == false)
        #expect(text.contains("SO_NOSIGPIPE") == false)
        #expect(text.contains("MSG_NOSIGNAL"))
        #expect(text.contains("AF_UNIX"))
    }
    #else
    @Test func productionRejectsSocketFlag() {
        #expect(throws: RVDLaunchError.socketUnsupported) {
            try RVDLaunch.parse(arguments: ["rvd", "--socket", "/tmp/rv.sock"])
        }
        #expect(throws: RVDLaunchError.socketUnsupported) {
            try RVDLaunch.parse(arguments: ["rvd", "--socket=/tmp/rv.sock"])
        }
    }

    /// macOS production surface: the XPC Mach service (hook path) plus exactly
    /// one AF_UNIX socket (SDK path) via `UnixSocketListener`. Nothing else
    /// may open sockets, and TCP listeners stay banned.
    @Test func productionSocketSurfaceIsExplicit() throws {
        let root = packageRoot().appendingPathComponent("Sources")
        let files = try swiftFiles(under: root.appendingPathComponent("RVService"))
            + swiftFiles(under: root.appendingPathComponent("rvd"))
        for url in files {
            if url.lastPathComponent == "UnixFrameTransport.swift" {
                // Linux-gated; covered by linuxSocketSourcesHaveNoBSDFlags.
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let mayListen = url.lastPathComponent == "UnixSocketListener.swift"
            #expect(text.contains("AF_UNIX") == false || mayListen)
            #expect(text.contains("NWListener") == false)
            let mayMentionSocket = url.lastPathComponent == "RVDLaunch.swift"
                || url.lastPathComponent == "main.swift"
                || url.lastPathComponent == "RVDProcess.swift"
            #expect(text.contains("--socket") == false || mayMentionSocket)
        }
        let _: XPCEvaluateListener.Type = XPCEvaluateListener.self
        let _: UnixSocketListener.Type = UnixSocketListener.self
    }
    #endif
}

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func swiftFiles(under root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return []
    }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
        return url
    }
}
