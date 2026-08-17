import Testing
@testable import RVHooks

@Test func emptyModule_compiles() {
    let _: RVHooks.Type = RVHooks.self
}
