import Testing
@testable import RVPolicy

@Test func emptyModule_compiles() {
    let _: RVPolicy.Type = RVPolicy.self
}
