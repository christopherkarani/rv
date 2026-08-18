import Foundation
import Testing
@testable import RVService

struct LaunchdPlistTests {
    @Test func templateIsOnDemandNotKeepAlive() throws {
        let url = packageRoot()
            .appendingPathComponent("Resources")
            .appendingPathComponent("launchd")
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

    @Test func productionRejectsSocketFlag() {
        #expect(throws: RVDLaunchError.socketUnsupported) {
            try RVDLaunch.parse(arguments: ["rvd", "--socket", "/tmp/rv.sock"])
        }
        #expect(throws: RVDLaunchError.socketUnsupported) {
            try RVDLaunch.parse(arguments: ["rvd", "--socket=/tmp/rv.sock"])
        }
    }

    @Test func productionSourcesDoNotListenOnUnixSocket() throws {
        let root = packageRoot().appendingPathComponent("Sources")
        let files = try swiftFiles(under: root.appendingPathComponent("RVService"))
            + swiftFiles(under: root.appendingPathComponent("rvd"))
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("AF_UNIX") == false)
            #expect(text.contains("NWListener") == false)
            let mayMentionSocket =
                url.lastPathComponent == "RVDLaunch.swift" || url.lastPathComponent == "main.swift"
            #expect(text.contains("--socket") == false || mayMentionSocket)
        }
        let _: XPCEvaluateListener.Type = XPCEvaluateListener.self
    }
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
