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
        #expect(text.contains("Restart=always") == false)
        #expect(text.contains("Restart=no"))
        #expect(text.contains("ExecStart=@RVD_PATH@ --socket"))
        #expect(text.contains("WantedBy=default.target"))
        #expect(text.contains("WatchdogSec") == false)
        #expect(text.contains("[Service]"))
    }
}

private func packageRootForServiceTests() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
