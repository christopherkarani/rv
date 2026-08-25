import Testing
import RVDomain

struct ProductVersionTests {
    @Test func ProductVersion_semver() {
        #expect(ProductVersion.semver == "0.1.0")
    }
}
