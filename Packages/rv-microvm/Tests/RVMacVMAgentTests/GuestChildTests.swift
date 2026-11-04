import RVMicroVMCore
import Testing
@testable import RVMacVMAgent

@Suite("macOS guest command spawn")
struct GuestChildTests {
    private let request = MacVMExecRequest(
        workspace: "/Users/me/app", arguments: ["/bin/sh"], environment: ["TOKEN=s3cret"],
        terminal: true, rows: 30, columns: 100, relayPorts: [], sandboxProfile: "(version 1)\n(allow default)\n"
    )

    @Test("in a guest the trampoline keeps root and runs ssh to the guest's sshd; the request is never in argv")
    func guestSpawn() {
        let argv = GuestChild.argv(request, trampoline: "/agent", user: "rv")
        #expect(Array(argv.prefix(4)) == ["/agent", ExecAs.verb, ExecAs.keepUser, "--"])
        #expect(Array(argv.dropFirst(4)) == MacVMSession.sshArguments(terminal: true))
        #expect(!argv.joined().contains("s3cret"))
        let env = GuestChild.environment(request, user: "rv")
        #expect(env.first == "\(MacVMSession.variable)=\(MacVMSession.encode(request))")
        #expect(!env.contains("TOKEN=s3cret"))
    }

    @Test("in host tests the trampoline runs the session verb directly")
    func hostSpawn() {
        #expect(GuestChild.argv(request, trampoline: "/agent", user: nil)
            == ["/agent", ExecAs.verb, ExecAs.keepUser, "--", "/agent", MacVMSession.verb])
        #expect(GuestChild.environment(request, user: nil) == ["\(MacVMSession.variable)=\(MacVMSession.encode(request))"])
    }
}
