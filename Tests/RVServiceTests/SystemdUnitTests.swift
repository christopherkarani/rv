import Foundation
import Testing
@testable import RVService

struct SystemdUnitTests {
    /// systemd cannot relaunch rvd on connect without owning the socket
    /// (which would make systemd the SO_PEERCRED peer the clients verify),
    /// so the Linux unit keeps rvd resident and restarts it whenever it
    /// exits: after a crash, or after an upgrade replaced the binary.
    @Test func userUnitKeepsRvdResidentAndRestartsIt() throws {
        let url = packageRootForServiceTests()
            .appendingPathComponent("Sources/RVCLI/Resources/systemd")
            .appendingPathComponent("dev.rv.evaluate.service")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(restartValue(in: text) == "always")
        #expect(text.contains("ExecStart=@RVD_PATH@ --socket --idle-exit-seconds=31536000"))
        let idle = try RVDLaunch.parse(arguments: ["rvd", "--socket", "--idle-exit-seconds=31536000"])
        #expect(idle.idleExitSeconds == 31_536_000)
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
