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

    /// Every command-line form a credential travels in, through the one
    /// redactor rvd's live events also use (`CommandLineRedaction`).
    static let forms: [(command: String, shown: String, secret: String)] = [
        ("curl -u bob:hunter2 https://api.example.com", "curl -u bob:[redacted] https://api.example.com", "hunter2"),
        ("curl -ubob:hunter2 https://api.example.com", "curl -ubob:[redacted] https://api.example.com", "hunter2"),
        ("mysql -phunter2 -u root shop", "mysql -p[redacted] -u root shop", "hunter2"),
        ("sshpass -p hunter2 ssh host.example", "sshpass -p [redacted] ssh host.example", "hunter2"),
        ("docker login -u bob -p hunter2 registry.example", "docker login -u bob -p [redacted] registry.example", "hunter2"),
        ("redis-cli -h cache -a hunter2 get k", "redis-cli -h cache -a [redacted] get k", "hunter2"),
        ("pg_dump --password hunter2 shop", "pg_dump --password [redacted] shop", "hunter2"),
        ("gh auth login --token hunter2", "gh auth login --token [redacted]", "hunter2"),
        ("deploy --api-key abc123 --env prod", "deploy --api-key [redacted] --env prod", "abc123"),
        ("git clone https://bob:hunter2@git.example.com/r.git", "git clone https://bob:[redacted]@git.example.com/r.git", "hunter2"),
        (#"curl -H "Authorization: Basic Ym9iOmh1bnRlcjI=" https://x.example"#,
         #"curl -H "Authorization: [redacted] [redacted]" https://x.example"#, "Ym9iOmh1bnRlcjI="),
        ("curl -H 'X-Api-Key: abc123' https://x.example", "curl -H 'X-Api-Key: [redacted]' https://x.example", "abc123"),
        ("curl -H 'Cookie: session=abc123' https://x.example", "curl -H 'Cookie: [redacted]' https://x.example", "abc123"),
    ]

    @Test(arguments: forms.indices)
    func everyCredentialFormIsHidden(_ index: Int) {
        let form = Self.forms[index]
        let shown = DecisionRedaction.command(form.command, home: home)
        #expect(shown == form.shown)
        #expect(shown.contains(form.secret) == false)
        // `rv log` redacts again on read; a redacted row stays as it is.
        #expect(DecisionRedaction.command(shown, home: home) == shown)
    }

    @Test func liveEventsAndTheLogHideTheSame() {
        for form in Self.forms {
            #expect(DecisionRedaction.command(form.command, home: nil) == CommandLineRedaction.redact(form.command))
        }
    }

    /// rv-hook-local redacts inside its 750 ms write budget: an 8 KB
    /// command (cut to `maxScannedBytes` first) must take a sliver of it.
    @Test func anEightKilobyteCommandIsCheap() {
        let chunk = "curl -u bob:hunter2 -H 'X-Api-Key: abc' https://x.example/a?b=c && mysql -phunter2 shop; "
        let command = String(repeating: chunk, count: 8 * 1024 / chunk.utf8.count + 1)
        #expect(command.utf8.count >= 8 * 1024)
        let clock = ContinuousClock()
        var shown = ""
        let elapsed = clock.measure {
            for _ in 0..<10 { shown = DecisionRedaction.command(command, home: home) }
        }
        #expect(shown.contains("hunter2") == false)
        #expect(shown.hasSuffix("…"))
        #expect(shown.utf8.count <= DecisionRedaction.maxCommandBytes + "…".utf8.count)
        // Ten runs; one must stay far inside the budget even in a debug build.
        #expect(elapsed < .milliseconds(500), "\(elapsed) for 10 runs")
    }
}

@Suite("Decision log stops")
struct DecisionLogStopsTests {
    private func write(_ lines: [String], day: String, in log: DecisionLog) throws {
        try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
        let url = log.fileURL(day: day)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        chmod(url.path, 0o600)
    }

    @Test func idAndWouldBeRoundTrip() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.directory) }
        let watched = DecisionRecord(
            time: noon.addingTimeInterval(0.437), verdict: .allowed, host: .hook(.codex), tool: .bash,
            command: "git push --force", id: "b207de11aa01",
            wouldBe: DecisionWouldBe(verdict: .denied, rule: "core.git:push-force-long", ask: true)
        )
        #expect(log.append(watched, now: noon, prunes: false))
        let line = try String(contentsOf: log.fileURL(day: "2026-11-22"), encoding: .utf8)
        #expect(line.contains(#""id":"b207de11aa01""#))
        #expect(line.contains(#""would_be":{"ask":true,"rule":"core.git:push-force-long","verdict":"denied"}"#))
        #expect(log.records(since: noon.addingTimeInterval(-60), now: noon) == [watched])
        #expect(watched.code == "b20-7de")
    }

    @Test func onlyStopsAndWouldStopsAreRead() {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.directory) }
        let rows = [
            row(.allowed, at: noon),
            row(.denied, at: noon.addingTimeInterval(1), command: "git reset --hard"),
            row(.refused, at: noon.addingTimeInterval(2), command: "make"),
            DecisionRecord(time: noon.addingTimeInterval(3), verdict: .allowed, host: .hook(.claude), tool: .bash,
                           command: "rm -rf dist", wouldBe: DecisionWouldBe(verdict: .denied, rule: "core.filesystem:rm")),
            // A command that spells the skip pattern is still JSON-escaped.
            row(.denied, at: noon.addingTimeInterval(4), command: #"echo '"verdict":"allowed"'"#),
        ]
        for record in rows { log.append(record, now: noon, prunes: false) }
        let stops = log.stops(since: noon.addingTimeInterval(-60), now: noon.addingTimeInterval(60))
        #expect(stops.records.map(\.command) == ["git reset --hard", "make", "rm -rf dist", #"echo '"verdict":"allowed"'"#])
        #expect(stops.skippedDays.isEmpty)
        #expect(stops.startedAt == noon)
    }

    @Test func daysBeforeTheWindowAreNotRead() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.directory) }
        let old = noon.addingTimeInterval(-8 * 86_400)
        log.append(row(.denied, at: old), now: old, prunes: false)
        log.append(row(.denied, at: noon), now: noon, prunes: false)
        let stops = log.stops(since: noon.addingTimeInterval(-7 * 86_400), now: noon)
        #expect(stops.records.map(\.time) == [noon])
        // The log began before the window: nothing is older than it there.
        #expect(stops.startedAt == nil)
    }

    @Test func anOversizedDayIsSkippedAndNamed() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.directory) }
        log.append(row(.denied, at: noon), now: noon, prunes: false)
        let big = log.fileURL(day: "2026-11-21")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(DecisionLog.maxFileBytes + 1))
        try handle.close()
        let stops = log.stops(since: noon.addingTimeInterval(-7 * 86_400), now: noon)
        #expect(stops.skippedDays == ["2026-11-21"])
        #expect(stops.records.map(\.time) == [noon])
    }

    /// A busy day: 100 000 rows, almost all allows. The pass must stay fast.
    @Test func aHundredThousandLinesStayFast() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.directory) }
        let encoder = DecisionLog.encoder
        let allow = try #require(String(data: try encoder.encode(DecisionRecord(
            time: noon.addingTimeInterval(0.123), verdict: .allowed, host: .hook(.claude), tool: .bash,
            command: "git status --short && npm test -- --watch=false", cwd: "~/code/app", session: "cc8a1",
            id: "0123456789ab"
        )), encoding: .utf8))
        let deny = try #require(String(data: try encoder.encode(DecisionRecord(
            time: noon.addingTimeInterval(0.5), verdict: .denied, host: .hook(.claude), tool: .bash,
            command: "git reset --hard", rule: "core.git:reset-hard", id: "a7c835000001"
        )), encoding: .utf8))
        var lines = Array(repeating: allow, count: 100_000)
        for index in stride(from: 0, to: lines.count, by: 1000) { lines[index] = deny }
        try write(lines, day: "2026-11-22", in: log)
        let clock = ContinuousClock()
        var stops = DecisionLogStops(records: [])
        let elapsed = clock.measure {
            stops = log.stops(since: noon.addingTimeInterval(-7 * 86_400), now: noon.addingTimeInterval(60))
        }
        #expect(stops.records.count == 100)
        #expect(elapsed < .seconds(2), "\(elapsed)")
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
