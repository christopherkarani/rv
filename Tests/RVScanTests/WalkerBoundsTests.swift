import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func walker_stopsAtMaxFilesWithCapWarning() throws {
    try withTempTree { root in
        for i in 0..<5 {
            try writeFile(root.appendingPathComponent("f\(i).txt"), contents: "x")
        }
        let result = try DirectoryWalker(
            bounds: ScanBounds(maxDepth: 8, maxFiles: 3, maxTotalBytes: 1_000_000, maxFileBytes: 1_000)
        ).walk(root: root)

        #expect(result.filesVisited == 3)
        #expect(result.fileURLs.count == 3)
        #expect(result.warnings.contains { $0.code == "cap.files" })
    }
}

@Test func walker_stopsAtMaxTotalBytesWithCapWarning() throws {
    try withTempTree { root in
        try writeFile(root.appendingPathComponent("a.bin"), contents: Data(repeating: 0x61, count: 40))
        try writeFile(root.appendingPathComponent("b.bin"), contents: Data(repeating: 0x62, count: 40))
        try writeFile(root.appendingPathComponent("c.bin"), contents: Data(repeating: 0x63, count: 40))

        let result = try DirectoryWalker(
            bounds: ScanBounds(maxDepth: 8, maxFiles: 100, maxTotalBytes: 50, maxFileBytes: 100)
        ).walk(root: root)

        #expect(result.filesVisited == 1)
        #expect(result.bytesAccounted == 40)
        #expect(result.warnings.contains { $0.code == "cap.bytes" })
    }
}

@Test func walker_stopsDescendingPastMaxDepth() throws {
    try withTempTree { root in
        let deep = root.appendingPathComponent("a").appendingPathComponent("b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("top.txt"), contents: "top")
        try writeFile(deep.appendingPathComponent("deep.txt"), contents: "deep")

        let result = try DirectoryWalker(
            bounds: ScanBounds(maxDepth: 1, maxFiles: 100, maxTotalBytes: 1_000_000, maxFileBytes: 1_000)
        ).walk(root: root)

        #expect(result.fileURLs.map(\.lastPathComponent) == ["top.txt"])
        #expect(result.warnings.contains { $0.code == "cap.depth" })
    }
}

@Test func walker_skipsOversizedFileWithFileSizeWarning() throws {
    try withTempTree { root in
        try writeFile(root.appendingPathComponent("ok.txt"), contents: "ok")
        try writeFile(
            root.appendingPathComponent("big.bin"),
            contents: Data(repeating: 0x7a, count: 200)
        )

        let result = try DirectoryWalker(
            bounds: ScanBounds(maxDepth: 8, maxFiles: 100, maxTotalBytes: 1_000_000, maxFileBytes: 50)
        ).walk(root: root)

        #expect(result.fileURLs.map(\.lastPathComponent) == ["ok.txt"])
        #expect(result.filesVisited == 2)
        #expect(result.skippedOversize == 1)
        #expect(result.warnings.filter { $0.code == "cap.file-size" }.count == 1)
    }
}

@Test func walker_oversizedFilesConsumeMaxFiles() throws {
    try withTempTree { root in
        for i in 0..<4 {
            try writeFile(
                root.appendingPathComponent("big-\(i).bin"),
                contents: Data(repeating: 0x7a, count: 80)
            )
        }

        let result = try DirectoryWalker(
            bounds: ScanBounds(maxDepth: 8, maxFiles: 2, maxTotalBytes: 1_000_000, maxFileBytes: 20)
        ).walk(root: root)

        #expect(result.fileURLs.isEmpty)
        #expect(result.filesVisited == 2)
        #expect(result.skippedOversize == 2)
        #expect(result.warnings.contains { $0.code == "cap.file-size" })
        #expect(result.warnings.contains { $0.code == "cap.files" })
    }
}

@Test func walker_rootListingFailureThrows() throws {
    try withTempTree { root in
        let file = root.appendingPathComponent("not-a-dir.txt").standardizedFileURL
        try writeFile(file, contents: "x")
        #expect(throws: DirectoryWalkError.listingFailed(file.path)) {
            try DirectoryWalker().walk(root: file)
        }
    }
}

@Test func walker_nestedListingFailureEmitsIOWarning() throws {
    try withTempTree { root in
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("top.txt"), contents: "top")
        try writeFile(nested.appendingPathComponent("deep.txt"), contents: "deep")

        let fm = ListFailingFileManager()
        fm.shouldFail = { url in
            url.standardizedFileURL.path == nested.standardizedFileURL.path
        }

        let result = try DirectoryWalker(bounds: .default).walk(root: root, fileManager: fm)
        #expect(result.fileURLs.map(\.lastPathComponent) == ["top.txt"])
        #expect(result.warnings.contains { $0.code == "io.list" })
    }
}

@Test func walker_unreadableMetadataEmitsStatWarning() throws {
    try withTempTree { root in
        let fm = GhostChildFileManager()
        let result = try DirectoryWalker(bounds: .default).walk(root: root, fileManager: fm)
        #expect(result.fileURLs.isEmpty)
        #expect(result.warnings.contains { $0.code == "io.stat" })
    }
}

@Test func walker_usesTempTreesOnly_notLiveHome() throws {
    try withTempTree { root in
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let liveHome = ProcessInfo.processInfo.environment["HOME"]
        if let liveHome, liveHome.isEmpty == false {
            #expect(root.path.hasPrefix(liveHome) == false)
        }
        try writeFile(root.appendingPathComponent("one.txt"), contents: "1")
        let result = try DirectoryWalker(bounds: .default).walk(root: root)
        #expect(result.filesVisited == 1)
        #expect(result.warnings.isEmpty)
    }
}

@Test func sessionStoreAdapter_protocolSurfaceExists() throws {
    struct StubAdapter: SessionStoreAdapter {
        var host: ScanHostID { .pi }
        func roots(home: ScanHome) -> [URL] { [home.url] }
        func recognizes(fileURL: URL) -> Bool { fileURL.pathExtension == "jsonl" }
        func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] { [] }
    }

    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    let adapter: any SessionStoreAdapter = StubAdapter()
    #expect(adapter.host == .pi)
    #expect(adapter.roots(home: home).count == 1)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/tmp/a.jsonl")))
    #expect(ScanHome(validating: "") == nil)
}

private func withTempTree(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-walker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func writeFile(_ url: URL, contents: String) throws {
    try writeFile(url, contents: Data(contents.utf8))
}

private func writeFile(_ url: URL, contents: Data) throws {
    try contents.write(to: url, options: .atomic)
}

private final class ListFailingFileManager: FileManager, @unchecked Sendable {
    var shouldFail: @Sendable (URL) -> Bool = { _ in true }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if shouldFail(url) {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

private final class GhostChildFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        [url.appendingPathComponent("ghost-missing.txt")]
    }
}
