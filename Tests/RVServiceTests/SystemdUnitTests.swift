import Foundation
import Testing
@testable import RVService

struct SystemdUnitTests {
    @Test func userUnitIsOnDemandNotRestartAlways() throws {
        let url = packageRootForServiceTests()
            .appendingPathComponent("Resources")
            .appendingPathComponent("systemd")
            .appendingPathComponent("dev.rv.evaluate.service")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Restart=no"))
        #expect(restartValue(in: text) != "always")
        #expect(text.contains("ExecStart=@RVD_PATH@ --socket"))
        #expect(text.contains("WantedBy=default.target"))
        #expect(text.contains("WatchdogSec") == false)
        #expect(text.contains("[Service]"))
    }
}

private func restartValue(in unit: String) -> String? {
    for line in unit.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Restart=") {
            return String(trimmed.dropFirst("Restart=".count))
        }
    }
    return nil
}

private func packageRootForServiceTests() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
