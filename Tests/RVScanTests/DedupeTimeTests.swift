import Foundation
import Testing
import RVDomain
@testable import RVScan

private func resetHardFindings(
    classify: ScanClassify,
    events: [ExtractedEvent]
) -> [ScanFinding] {
    classify.classify(events)
}

@Test func dedupe_threeIdenticalDenies_collapsesToCountThree() throws {
    let classify = try ScanClassify()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = (0 ..< 3).map { offset in
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            occurredAt: base.addingTimeInterval(Double(offset)),
            command: ShellCommand(rawValue: "git reset --hard")
        )
    }

    let raw = resetHardFindings(classify: classify, events: events)
    let deduped = ScanDedupe.apply(raw)

    #expect(deduped.count == 1)
    let finding = try #require(deduped.first)
    #expect(finding.count == 3)
    #expect(finding.ruleID.rawValue == "core.git:reset-hard")
    #expect(ScanDedupeKey(finding: finding).ruleID == "core.git:reset-hard")
}

@Test func dedupe_allEvents_emitsOneRowPerDeny() throws {
    let classify = try ScanClassify()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = (0 ..< 3).map { offset in
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            occurredAt: base.addingTimeInterval(Double(offset)),
            command: ShellCommand(rawValue: "git reset --hard")
        )
    }

    let raw = resetHardFindings(classify: classify, events: events)
    let rows = ScanDedupe.apply(raw, allEvents: true)

    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.count == 1 })
}

@Test func timeWindow_defaultSevenDays_keepsOnlyRecentDeny() throws {
    let classify = try ScanClassify()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-8 * 86_400)
    let recent = now.addingTimeInterval(-1 * 86_400)
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/old.jsonl",
            occurredAt: old,
            command: ShellCommand(rawValue: "git reset --hard")
        ),
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/recent.jsonl",
            occurredAt: recent,
            command: ShellCommand(rawValue: "git reset --hard")
        ),
    ]

    let raw = resetHardFindings(classify: classify, events: events)
    let inWindow = ScanTimeWindow.default.filter(raw, now: now)
    let deduped = ScanDedupe.apply(inWindow)

    #expect(deduped.count == 1)
    #expect(deduped.first?.count == 1)
    #expect(deduped.first?.sourcePath == "/tmp/recent.jsonl")
}

@Test func timeWindow_all_includesOlderAndRecentDenies() throws {
    let classify = try ScanClassify()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-8 * 86_400)
    let recent = now.addingTimeInterval(-1 * 86_400)
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/old.jsonl",
            occurredAt: old,
            command: ShellCommand(rawValue: "git reset --hard")
        ),
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/recent.jsonl",
            occurredAt: recent,
            command: ShellCommand(rawValue: "git reset --hard")
        ),
    ]

    let raw = resetHardFindings(classify: classify, events: events)
    let eligible = ScanTimeWindow.all.filter(raw, now: now)
    let deduped = ScanDedupe.apply(eligible)

    #expect(deduped.count == 1)
    #expect(deduped.first?.count == 2)
}

@Test func timeWindow_nilOccurredAt_usesInjectableFileMtime() throws {
    let classify = try ScanClassify()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let mtime = now.addingTimeInterval(-2 * 86_400)
    let events = [
        ExtractedEvent(
            host: .grok,
            sourcePath: "/tmp/grok/session.jsonl",
            occurredAt: nil,
            command: ShellCommand(rawValue: "git reset --hard")
        ),
    ]

    let raw = resetHardFindings(classify: classify, events: events)
    let resolver = ScanFindingInstantResolver { path in
        path == "/tmp/grok/session.jsonl" ? mtime : nil
    }
    let inWindow = ScanTimeWindow.default.filter(raw, now: now, resolver: resolver)

    #expect(inWindow.count == 1)
    #expect(inWindow.first?.occurredAt == nil)
}

@Test func dedupe_keyUsesMatchingViewAndColonRuleID() throws {
    let classify = try ScanClassify()
    let events = [
        ExtractedEvent(
            host: .pi,
            sourcePath: "/tmp/a",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            command: ShellCommand(rawValue: "git reset --hard")
        ),
        ExtractedEvent(
            host: .pi,
            sourcePath: "/tmp/b",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_100),
            command: ShellCommand(rawValue: "rm -rf /")
        ),
    ]

    let raw = classify.classify(events)
    let keys = Set(raw.map(ScanDedupeKey.init(finding:)))
    #expect(keys.count == 2)
    #expect(keys.contains(ScanDedupeKey(matchingView: raw[0].matchingView, ruleID: raw[0].ruleID)))
    #expect(keys.contains(ScanDedupeKey(matchingView: raw[1].matchingView, ruleID: raw[1].ruleID)))
}
