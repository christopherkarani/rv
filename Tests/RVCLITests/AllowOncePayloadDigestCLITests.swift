import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

// M-07: the TTY redeem TOCTOU binds the masked payload digest alongside the
// fingerprint, so a file swap between pre-LA display and attest aborts.

struct AllowOncePayloadDigestCLITests {
    @Test func redemptionUnchangedCoversPayloadDigest() async throws {
        let store = try payloadDigestCLIStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "echo    ",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now,
            maskedSegments: ["aaa"]
        )
        let reviewed = try #require(await store.validatePending(code: code.rawValue, now: now))
        #expect(reviewed.payloadDigest == maskedPayloadContentDigest(["aaa"]))
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: reviewed))

        var swapped = reviewed
        swapped.payloadDigest = "swapped-digest"
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: swapped) == false)

        var dropped = reviewed
        dropped.payloadDigest = nil
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: dropped) == false)
    }
}

private func payloadDigestCLIStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-payload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
