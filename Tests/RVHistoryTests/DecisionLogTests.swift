import Foundation
import RVDomain
@testable import RVHistory
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let home = HomePath(validating: "/Users/ann")

/// 2026-11-22 14:00:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_795_356_000)

private func temporaryLog() -> DecisionLog {
    DecisionLog(configDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-decisions-\(UUID().uuidString)", isDirectory: true))
}

private func row(_ verdict: DecisionVerdict = .allowed, at time: Date, command: String = "git status") -> DecisionRecord {
    DecisionRecord(time: time, verdict: verdict, host: .hook(.claude), tool: .bash, command: command)
}

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    _ = stat(url.path, &info)
    return info.st_mode & 0o777
}

@Suite("Decision log redaction")
struct DecisionRedactionTests {
    @Test func credentialsAreRedacted() {
        let shown = DecisionRedaction.command(
            "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 curl -H 'Authorization: Bearer abc123' x", home: home)
        #expect(shown.contains("ghp_") == false)
        #expect(shown.contains("abc123") == false)
        #expect(shown.contains("[redacted]"))
        #expect(shown.hasSuffix(" x"))
    }

    @Test func homeBecomesTildeOnlyAsAWholeName() {
        #expect(DecisionRedaction.command("cat /Users/ann/.zshrc /Users/anna/x /Users/ann", home: home)
            == "cat ~/.zshrc /Users/anna/x ~")
        #expect(DecisionRedaction.command("cd /Users/ann && ls", home: home) == "cd ~ && ls")
        #expect(DecisionRedaction.command("ls /Users/ann", home: nil) == "ls /Users/ann")
    }

    @Test func controlCharactersAndLengthAreBounded() {
        #expect(DecisionRedaction.command("echo a\nrm b\tc\r", home: nil) == "echo a rm b c")
        let long = DecisionRedaction.command(String(repeating: "é", count: 400), home: nil)
        #expect(long.hasSuffix("…"))
        #expect(long.utf8.count <= DecisionRedaction.maxCommandBytes + "…".utf8.count)
    }

    @Test func pathsUseTheBlocksRedaction() {
        #expect(DecisionRedaction.path("/Users/ann/.ssh/id_ed25519", home: home) == "~/.ssh/id_ed25519")
    }
}

@Suite("Decision log store")
struct DecisionLogStoreTests {
    @Test func appendsOwnerOnlyDayFilesAndReadsThemBack() throws {
        let log = temporaryLog()
        let record = DecisionRecord(
            time: noon.addingTimeInterval(0.25), verdict: .denied, host: .hook(.codex), tool: .bash,
            command: "git push --force", cwd: "~/src/rv", rule: "core.git:force-push", session: "s-1"
        )
        #expect(log.append(record, now: noon))
        let file = log.fileURL(day: "2026-11-22")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(mode(file) == 0o600)
        #expect(mode(log.directory) == 0o700)
        #expect(log.records(since: noon.addingTimeInterval(-60), now: noon) == [record])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#""time":"2026-11-22T14:00:00.250Z""#))
        #expect(text.contains(#""host":"codex""#))
    }

    @Test func rowsAreFiledByUTCDayAndReadOldestFirst() {
        let log = temporaryLog()
        log.append(row(at: noon), now: noon)
        log.append(row(.denied, at: noon.addingTimeInterval(-86_400), command: "rm -rf build"), now: noon)
        #expect(log.dayFiles() == ["2026-11-21", "2026-11-22"])
        #expect(log.records(since: .distantPast, now: noon).map(\.command) == ["rm -rf build", "git status"])
        #expect(log.records(since: noon, now: noon).count == 1)
    }

    @Test func cursorReadsOnlyNewWholeLines() throws {
        let log = temporaryLog()
        log.append(row(at: noon), now: noon)
        let first = log.read(after: nil, now: noon)
        #expect(first.records.count == 1)
        #expect(log.read(after: first.cursor, now: noon).records.isEmpty)

        // A row still being written is left for the next read.
        let file = log.fileURL(day: "2026-11-22")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"host":"claude","#.utf8))
        try handle.close()
        let partial = log.read(after: first.cursor, now: noon)
        #expect(partial.records.isEmpty)
        #expect(partial.cursor == first.cursor)

        // The next day's file is picked up after the cursor's day.
        let tomorrow = noon.addingTimeInterval(86_400)
        log.append(row(at: tomorrow, command: "make"), now: tomorrow)
        let next = log.read(after: partial.cursor, now: tomorrow)
        #expect(next.records.map(\.command) == ["make"])
        #expect(next.cursor.day == "2026-11-23")
    }

    @Test func pruneDropsDaysPastTheWeek() {
        let log = temporaryLog()
        let old = noon.addingTimeInterval(-8 * 86_400)
        log.append(row(at: old), now: old)
        log.append(row(at: noon), now: old)
        #expect(log.dayFiles().count == 2)
        log.prune(now: noon)
        #expect(log.dayFiles() == ["2026-11-22"])
        #expect(FileManager.default.fileExists(atPath: log.fileURL(day: "2026-11-14").appendingPathExtension("lock").path) == false)
        #expect(log.records(since: .distantPast, now: noon).count == 1)
    }

    @Test func unreadableLinesAreSkipped() throws {
        let log = temporaryLog()
        log.append(row(at: noon), now: noon)
        let file = log.fileURL(day: "2026-11-22")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        log.append(row(at: noon.addingTimeInterval(1), command: "ls"), now: noon)
        #expect(log.records(since: .distantPast, now: noon).map(\.command) == ["git status", "ls"])
    }

    @Test func enabledUnlessConfigTurnsItOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-decisions-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(DecisionLog.isEnabled(inConfigDirectory: directory))
        try Data(#"{"decisions":{"enabled":false}}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(DecisionLog.isEnabled(inConfigDirectory: directory) == false)
    }
}
