import Testing
@testable import RVPacks

@Test func emptyModule_compiles() {
    let _: RVPacks.Type = RVPacks.self
}
