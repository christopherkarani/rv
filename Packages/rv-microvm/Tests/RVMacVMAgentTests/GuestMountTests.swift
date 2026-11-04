import Testing
@testable import RVMacVMAgent

@Suite("macOS guest workspace mount")
struct GuestMountTests {
    @Test("a directory on the boot volume is not a workspace mount")
    func notAMount() throws {
        let problem = try #require(GuestMount.mountProblem("/usr/bin"))
        #expect(problem.contains("not its own virtiofs mount"), "\(problem)")
    }
}
