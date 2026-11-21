import Testing
@testable import RVService

struct RVDLaunchVersionTests {
    @Test func RVDLaunch_versionLine() {
        #if RV_TEST_OWNER_PRESENCE
        #expect(RVDLaunch.versionLine == "0.2.2 (rv-test-owner-presence build)")
        #else
        #expect(RVDLaunch.versionLine == "0.2.2")
        #endif
    }
}
