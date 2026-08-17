import Testing
@testable import RVService

@Test func emptyModule_compiles() {
    let _: RVService.Type = RVService.self
}
