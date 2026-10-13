import Testing
@testable import RVDomain

@Test func containedRuntimeRefusal_namesHookGuardOnLinuxAndReading() {
    let message = ContainedRuntimeRefusal.message
    #expect(message.contains("hook guard"))
    #expect(message.contains("works on Linux"))
    #expect(message.contains("macOS-only"))
    #expect(message.contains("docs/security/runtime-boundary.md"))
    #expect(message != "contained workspace host is unavailable")
    #expect(message.contains("contained workspace host is unavailable") == false)
}
