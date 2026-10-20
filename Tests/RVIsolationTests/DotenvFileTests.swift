#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

@Suite("DotenvFile")
struct DotenvFileTests {
    private func parse(_ text: String) throws -> DotenvParse {
        try DotenvFile.parse(Data(text.utf8)).get()
    }

    @Test func parsesBareQuotedExportAndComments() throws {
        let parsed = try parse("""
            # heading
            STRIPE_SECRET_KEY = sk-live-123
            export OPENAI_API_KEY="sk open # not comment"
            SINGLE='literal $HOME \\n'
            DEBUG=true # trailing comment
            HASHY=abc#def

            """)
        #expect(parsed.malformedLine == nil)
        #expect(parsed.value(for: "STRIPE_SECRET_KEY") == "sk-live-123")
        #expect(parsed.value(for: "OPENAI_API_KEY") == "sk open # not comment")
        #expect(parsed.value(for: "SINGLE") == "literal $HOME \\n")
        #expect(parsed.value(for: "DEBUG") == "true")
        #expect(parsed.value(for: "HASHY") == "abc#def")
        #expect(parsed.entries.map(\.name) == ["STRIPE_SECRET_KEY", "OPENAI_API_KEY", "SINGLE", "DEBUG", "HASHY"])
    }

    @Test func stripsBOMAndAcceptsCRLF() throws {
        let parsed = try parse("\u{FEFF}FIRST=one\r\nSECOND=two\r\n")
        #expect(parsed.value(for: "FIRST") == "one")
        #expect(parsed.value(for: "SECOND") == "two")
    }

    @Test func commentedOutValueParsesAsEmpty() throws {
        let parsed = try parse("KEY= # placeholder\nOTHER=  # also empty\nKEPT=abc#def\n")
        #expect(parsed.value(for: "KEY") == "")
        #expect(parsed.value(for: "OTHER") == "")
        #expect(parsed.value(for: "KEPT") == "abc#def")
    }

    @Test func controlAndSeparatorScalarsCannotFoldAssignments() throws {
        // LF is the only line split: CR-only files, Unicode separators, and
        // other controls must not weld the next variable into this value.
        for text in ["A=1\rB=secretB\r", "A=1\u{2028}B=secretB\n", "A=1\u{0085}B=secretB\n", "K=ab\u{1B}[31mcd\n"] {
            let parsed = try parse(text)
            #expect(parsed.malformedLine == 1)
            #expect(parsed.entries.isEmpty)
        }
        let tabbed = try parse("A=x\ty\n")
        #expect(tabbed.malformedLine == nil)
        #expect(tabbed.value(for: "A") == "x\ty")
    }

    @Test func commentsHonorTabAndLiteralApostrophes() throws {
        let parsed = try parse("A=v\t# note\nB=it's # note\nC=\"a # b\" # note\nD=abc#def\n")
        #expect(parsed.malformedLine == nil)
        #expect(parsed.value(for: "A") == "v")
        #expect(parsed.value(for: "B") == "it's")
        #expect(parsed.value(for: "C") == "a # b")
        #expect(parsed.value(for: "D") == "abc#def")
    }

    @Test func secretBearingTypesRedactDescriptions() throws {
        let parsed = try parse("KEY=hunter2secret\n")
        #expect(String(describing: parsed).contains("hunter2secret") == false)
        #expect(String(reflecting: parsed).contains("hunter2secret") == false)
        let entry = try #require(parsed.entries.first)
        #expect(String(describing: entry).contains("hunter2secret") == false)
        let snapshot = DotenvFileSnapshot(
            canonicalPath: "/p/.env", data: Data("KEY=hunter2secret\n".utf8), identity: "1")
        #expect(String(describing: snapshot).contains("hunter2secret") == false)
        #expect(String(reflecting: snapshot).contains("hunter2secret") == false)
    }

    @Test func emptyValueParsesAsEmpty() throws {
        let parsed = try parse("EMPTY=\nALSO_EMPTY=  \n")
        #expect(parsed.value(for: "EMPTY") == "")
        #expect(parsed.value(for: "ALSO_EMPTY") == "")
    }

    @Test func duplicateIsRecordedAndFirstKeptForDisplay() throws {
        let parsed = try parse("KEY=one\nKEY=two\nOTHER=x\n")
        #expect(parsed.duplicates == ["KEY"])
        #expect(parsed.value(for: "KEY") == "one")
        #expect(parsed.entries.map(\.name) == ["KEY", "OTHER"])
    }

    @Test func malformedLineIsPerFileError() throws {
        let parsed = try parse("GOOD=1\nthis is not an assignment\nALSO=2\n")
        #expect(parsed.malformedLine == 2)
        #expect(parsed.value(for: "GOOD") == "1")
    }

    @Test func invalidVariableNameIsMalformed() throws {
        let parsed = try parse("9BAD=x\n")
        #expect(parsed.malformedLine == 1)
    }

    @Test func unterminatedQuoteIsMalformed() throws {
        let parsed = try parse("KEY=\"open\n")
        #expect(parsed.malformedLine == 1)
    }

    @Test func rejectsNULNonUTF8AndOversize() {
        #expect(throws: DotenvFileError.self) { try DotenvFile.parse(Data([0x4B, 0x00])).get() }
        #expect(throws: DotenvFileError.self) { try DotenvFile.parse(Data([0xFF, 0xFE, 0x3D])).get() }
        let big = Data(repeating: UInt8(ascii: "a"), count: DotenvFile.maximumBytes + 1)
        guard case .failure(.oversized) = DotenvFile.parse(big) else {
            Issue.record("expected oversized")
            return
        }
        let exact = Data(("K=" + String(repeating: "v", count: DotenvFile.maximumBytes - 2)).utf8)
        #expect(exact.count == DotenvFile.maximumBytes)
        guard case .success = DotenvFile.parse(exact) else {
            Issue.record("exact cap must parse")
            return
        }
    }

    @Test func strictnessLintNotesLiteralDifferentials() throws {
        let parsed = try parse("A=$HOME/x\nB=plain\nC=`whoami`\nD=a\\b\n")
        #expect(parsed.lintNotes.contains { $0.contains("A") && $0.contains("literally") })
        #expect(parsed.lintNotes.contains { $0.contains("C") })
        #expect(parsed.lintNotes.contains { $0.contains("D") })
        #expect(parsed.lintNotes.contains { $0.contains("B") } == false)
    }

    @Test func resolverReadsDotenvAndFailsClosed() {
        let reader: DotenvReaderFunction = { _ in
            .success(DotenvFileSnapshot(
                canonicalPath: "/proj/.env", data: Data("KEY=one\nKEY=two\nGOOD=ok\n".utf8), identity: "1"))
        }
        let resolver = SecretResolver.live(environment: [:], home: "/nonexistent", dotenvReader: reader)
        switch resolver.resolve(.dotenv(path: "/proj/.env", variable: "GOOD")) {
        case .success(let value): #expect(value.text == "ok")
        case .failure(let error): Issue.record("GOOD must resolve: \(error.message)")
        }
        switch resolver.resolve(.dotenv(path: "/proj/.env", variable: "KEY")) {
        case .success: Issue.record("duplicate must fail closed")
        case .failure(let error):
            #expect(error.message.contains("duplicate"))
            #expect(error.message.contains("one") == false)
            #expect(error.message.contains("two") == false)
        }
        switch resolver.resolve(.dotenv(path: "/proj/.env", variable: "MISSING")) {
        case .success: Issue.record("missing variable must fail")
        case .failure(let error): #expect(error.message.contains("MISSING"))
        }
    }

    @Test func resolverSnapshotRejectsIdentityChangeMidLease() {
        final class Box: @unchecked Sendable { var identity = "1" }
        let box = Box()
        let reader: DotenvReaderFunction = { _ in
            .success(DotenvFileSnapshot(
                canonicalPath: "/proj/.env", data: Data("A=1\nB=2\n".utf8), identity: box.identity))
        }
        let resolver = SecretResolver.live(environment: [:], home: "/nonexistent", dotenvReader: reader)
        guard case .success = resolver.resolve(.dotenv(path: "/proj/.env", variable: "A")) else {
            Issue.record("first resolve must succeed")
            return
        }
        box.identity = "2"
        switch resolver.resolve(.dotenv(path: "/proj/.env", variable: "B")) {
        case .success: Issue.record("identity change must fail")
        case .failure(let error): #expect(error.message.contains("changed"))
        }
    }

    @Test func resolverRefusesRetargetedCanonicalPath() {
        // The stored binding is /proj/.env; the reader now canonicalizes it
        // elsewhere (a symlink component was swapped after import).
        let reader: DotenvReaderFunction = { _ in
            .success(DotenvFileSnapshot(
                canonicalPath: "/other/.env", data: Data("GOOD=ok\n".utf8), identity: "1"))
        }
        let resolver = SecretResolver.live(environment: [:], home: "/nonexistent", dotenvReader: reader)
        switch resolver.resolve(.dotenv(path: "/proj/.env", variable: "GOOD")) {
        case .success: Issue.record("retargeted binding must fail closed")
        case .failure(let error):
            #expect(error.message.contains("now resolves to"))
            #expect(error.message.contains("ok") == false)
        }
    }

    @Test func liveReaderTrustChecks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-dotenv-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = directory.appendingPathComponent(".env")
        try Data("KEY=value\n".utf8).write(to: good)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: good.path)
        guard case .success(let snapshot) = DotenvLiveReader.read(path: good.path) else {
            Issue.record("0644 owner file must read")
            return
        }
        #expect(snapshot.canonicalPath == DotenvLiveReader.canonicalPath(good.path))

        let link = directory.appendingPathComponent("linked.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
        guard case .success = DotenvLiveReader.read(path: link.path) else {
            Issue.record("symlink to safe target must read")
            return
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: good.path)
        guard case .failure(let error) = DotenvLiveReader.read(path: good.path) else {
            Issue.record("group-writable must be refused")
            return
        }
        #expect(error.message.contains("writable"))

        guard case .failure = DotenvLiveReader.read(path: directory.appendingPathComponent("nope.env").path) else {
            Issue.record("missing file must fail")
            return
        }
    }

    @Test func liveReaderRefusesNonOwnerSymlinkToUnsafeAndOversize() throws {
        // Root-owned on macOS and Linux; not owned by the test user.
        guard case .failure(let ownerError) = DotenvLiveReader.read(path: "/etc/passwd") else {
            Issue.record("non-owner file must be refused")
            return
        }
        #expect(ownerError.message.contains("another user"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-dotenv-unsafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.env")
        try Data("KEY=value\n".utf8).write(to: target)
        chmod(target.path, 0o664)
        let link = directory.appendingPathComponent("link.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .failure(let linkError) = DotenvLiveReader.read(path: link.path) else {
            Issue.record("symlink to a group-writable target must be refused through the link")
            return
        }
        #expect(linkError.message.contains("writable"))

        let big = directory.appendingPathComponent("big.env")
        try Data(repeating: UInt8(ascii: "a"), count: DotenvFile.maximumBytes + 1).write(to: big)
        chmod(big.path, 0o600)
        guard case .failure(.oversized) = DotenvLiveReader.read(path: big.path) else {
            Issue.record("oversize file must be refused by size before read")
            return
        }
    }

    @Test func liveReaderRefusesFIFOWithoutHanging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-dotenv-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("fifo.env")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        // Watchdog: a blocking open would hang the suite; run on a thread.
        final class Done: @unchecked Sendable { var finished = false }
        let done = Done()
        let semaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = DotenvLiveReader.read(path: fifo.path)
            done.finished = true
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
        #expect(done.finished)
        guard case .failure = DotenvLiveReader.read(path: fifo.path) else {
            Issue.record("FIFO must be refused")
            return
        }
    }

    #if os(macOS)
    @Test func liveReaderRefusesAllowACL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-dotenv-acl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".env")
        try Data("KEY=value\n".utf8).write(to: file)
        chmod(file.path, 0o644)
        let canonical = try #require(DotenvLiveReader.canonicalPath(file.path))
        guard case .success = DotenvLiveReader.read(path: canonical) else {
            Issue.record("plain 0644 file must read before the ACL is added")
            return
        }
        let chmodACL = Process()
        chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "everyone allow write", canonical]
        try chmodACL.run()
        chmodACL.waitUntilExit()
        #expect(chmodACL.terminationStatus == 0)
        // Mode bits still show 0644; only the ACL grants write.
        guard case .failure(let error) = DotenvLiveReader.read(path: canonical) else {
            Issue.record("allow-write ACL must be refused")
            return
        }
        #expect(error.message.contains("ACL"))
    }
    #endif
}
