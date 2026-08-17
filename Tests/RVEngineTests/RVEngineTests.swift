import Testing
@testable import RVEngine

@Test func emptyModule_compiles() {
    let _: RVEngine.Type = RVEngine.self
}
