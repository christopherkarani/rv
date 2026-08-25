import Testing
@testable import RVCLI

struct RVVersionTests {
    @Test func rvVersion() {
        #expect(RV.configuration.version == "0.1.0")
    }
}
