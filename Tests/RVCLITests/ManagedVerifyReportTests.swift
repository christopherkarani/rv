import Foundation
import RVPolicy
import Testing
@testable import RVCLI

/// `rv managed verify` prints only what it checked, and names the rest
/// "not checked".
struct ManagedVerifyReportTests {
    final class Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-verify-\(UUID().uuidString)")
        var directory: URL { root.appendingPathComponent("bundle") }
        var keys: URL { root.appendingPathComponent("keys") }

        func write(_ name: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }

        func sign() throws {
            _ = try ManagedRun.keygen(directory: keys).get()
            try FileManager.default.copyItem(
                at: keys.appendingPathComponent("org-key.pub"), to: directory.appendingPathComponent("org-key.pub"))
            _ = try ManagedRun.sign(
                policy: directory.appendingPathComponent("policy.json"), key: keys.appendingPathComponent("org-key.private"),
                output: nil
            ).get()
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func signedBundle_claimsOnlyWhatItChecked() throws {
        let bundle = Bundle()
        try bundle.write("policy.json", #"{"version": 1, "organization": "Acme", "serial": 7, "mcp": {"blocked": ["shell-*"]}}"#)
        try bundle.sign()
        let report = try ManagedRun.verifyReport(directory: bundle.directory).get()
        #expect(report.signingKey == 1)
        let text = ManagedRun.verifyText(report)
        // Never the installed-policy words: nothing here is installed.
        #expect(text.contains("active") == false)
        #expect(text.contains("anti-rollback: highest serial") == false)
        #expect(text.hasPrefix("policy bundle "))
        #expect(text.contains(": Acme serial 7 sha256 "))
        #expect(text.contains("  ✓ policy.json parses as an organization policy this rv reads\n"))
        #expect(text.contains("  ✓ policy.json.sig verifies against key 1 in this bundle's org-key.pub\n"))
        #expect(text.contains("    mcp blocked servers: shell-*\n"))
        #expect(text.contains("  ◐ not checked: that this org-key.pub is your organization's key"))
        #expect(text.contains("  ◐ not checked: anti-rollback"))
        #expect(text.contains("  ◐ not checked: owner and permissions once installed"))
        // No line about this host's sandbox: the bundle does not say it.
        #expect(text.contains("on this host") == false)
    }

    @Test func signatureWithoutKey_isNotChecked() throws {
        let bundle = Bundle()
        try bundle.write("policy.json", #"{"version": 1}"#)
        try bundle.write("policy.json.sig", "AAAA\n")
        let report = try ManagedRun.verifyReport(directory: bundle.directory).get()
        #expect(report.signingKey == nil)
        #expect(report.signatureUnchecked)
        let text = ManagedRun.verifyText(report)
        #expect(text.contains("✓ policy.json.sig") == false)
        #expect(text.contains("not checked: policy.json.sig: this bundle has no org-key.pub to check it against"))
    }

    @Test func unsignedBundle_saysItInstallsUnsigned() throws {
        let bundle = Bundle()
        try bundle.write("policy.json", #"{"version": 1, "mcp": {"requireSandbox": true}}"#)
        let report = try ManagedRun.verifyReport(directory: bundle.directory).get()
        let text = ManagedRun.verifyText(report)
        #expect(text.contains("not checked: a signature: this bundle has no policy.json.sig, so it installs unsigned"))
        #expect(text.contains("    mcp: every local server must be sandboxed (remote servers are exempt)\n"))
    }

    @Test func robotJSON_saysVerifiedAndListsChecks() throws {
        let bundle = Bundle()
        try bundle.write("policy.json", #"{"version": 1}"#)
        let report = try ManagedRun.verifyReport(directory: bundle.directory).get()
        let json = try RobotJSON.encode(report, options: .pretty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["state"] as? String == "verified")
        #expect(object["signed"] as? Bool == false)
        #expect((object["checked"] as? [String])?.isEmpty == false)
        #expect((object["notChecked"] as? [String])?.count == 3)
        #expect(object["signatureUnchecked"] as? Bool == false)
    }

    /// Review of #669: not-checked lines use the artifact's caution glyph,
    /// and the output ends with the one next step.
    @Test func text_endsWithTheNextStep() throws {
        let unsigned = Bundle()
        try unsigned.write("policy.json", #"{"version": 1}"#)
        let unsignedText = ManagedRun.verifyText(try ManagedRun.verifyReport(directory: unsigned.directory).get())
        #expect(unsignedText.contains("· not checked") == false)
        let last = try #require(unsignedText.split(separator: "\n").last)
        #expect(last.hasPrefix("  → rv managed sign "), "\(unsignedText)")
        #expect(last.hasSuffix("policy.json --key org-key.private"))

        let unchecked = Bundle()
        try unchecked.write("policy.json", #"{"version": 1}"#)
        try unchecked.write("policy.json.sig", "AAAA\n")
        let uncheckedReport = try ManagedRun.verifyReport(directory: unchecked.directory).get()
        let json = try RobotJSON.encode(uncheckedReport, options: .pretty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["signatureUnchecked"] as? Bool == true)
        #expect(ManagedRun.verifyText(uncheckedReport).hasSuffix("  → add org-key.pub to the bundle, then: rv managed verify "
            + uncheckedReport.directory + "\n"))

        let signed = Bundle()
        try signed.write("policy.json", #"{"version": 1}"#)
        try signed.sign()
        let signedText = ManagedRun.verifyText(try ManagedRun.verifyReport(directory: signed.directory).get())
        #expect(signedText.hasSuffix(": rv managed status\n"), "\(signedText)")
    }

    @Test func invalidBundle_stillFails() throws {
        let bundle = Bundle()
        try bundle.write("policy.json", #"{"version": 1, "gates": {}}"#)
        guard case .failure = ManagedRun.verifyReport(directory: bundle.directory) else {
            Issue.record("expected failure")
            return
        }
    }
}
