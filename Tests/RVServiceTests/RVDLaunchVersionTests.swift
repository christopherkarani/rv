import Testing
@testable import RVService

struct RVDLaunchVersionTests {
    @Test func RVDLaunch_versionLine() {
        #expect(RVDLaunch.versionLine == "0.1.1")
    }
}
