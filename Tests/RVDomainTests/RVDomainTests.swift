import Testing
@testable import RVDomain

@Test func emptyModule_compiles() {
    let _: RVDomain.Type = RVDomain.self
}
