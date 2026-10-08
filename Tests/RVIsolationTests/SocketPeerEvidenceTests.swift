#if os(Linux)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

@Suite("Socket peer evidence (Linux SO_PEERCRED model)")
struct SocketPeerEvidenceTests {
    @Test func socketPeerCarriesPidAndUidWithoutRole() {
        let evidence = PlatformPeerEvidence.socketPeer(processID: 4242, effectiveUserID: 501)
        #expect(evidence.processID == 4242)
        #expect(evidence.effectiveUserID == 501)
        #expect(evidence.componentRole == nil)
        #expect(evidence.auditToken == nil)
        #expect(evidence.codeIdentity == .unattributedSocket)
    }

    @Test func unattributedIdentityIsMarkedNotVerified() {
        let identity = PeerCodeIdentity.unattributedSocket
        #expect(identity.identifier == "unattributed-socket-peer")
        #expect(identity.teamIdentifier == nil)
        // False means "not verified", never "verified absent".
        #expect(identity.isAdHoc == false)
        #expect(identity.hardenedRuntime == false)
    }

    @Test func socketPeerFactoryPreservesConnection() {
        let id = UUID()
        let peer = AuthenticatedPeer.socketPeer(processID: 7, effectiveUserID: 501, connectionID: id)
        #expect(peer.connectionID == id)
        #expect(peer.componentRole == nil)
        #expect(peer.evidence.processID == 7)
    }

    @Test func socketPeerIsNeverRoleBearing() {
        // Role-gating switches on componentRole; a socket peer must never
        // smuggle a role through any factory path.
        let peer = AuthenticatedPeer.socketPeer(processID: 1, effectiveUserID: 0, connectionID: UUID())
        switch peer.componentRole {
        case nil:
            break
        case .cli, .service, .workspaceHost, .operatorUI:
            Issue.record("socket peer must never carry a component role")
        }
    }

#if os(Linux)
    @Test func linuxCaptureAttestsSocketpairPeer() throws {
        // Linux-only: SO_PEERCRED over a real socketpair. Not runnable on
        // macOS; the Linux CI gate runs it.
        var fds = [Int32](repeating: -1, count: 2)
        let opened = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, buf.baseAddress)
        }
        #expect(opened == 0)
        defer {
            for fd in fds where fd >= 0 { _ = Glibc.close(fd) }
        }
        let creds = try LinuxSocketPeerCapture.capture(fd: fds[0])
        #expect(creds.processID == getpid())
        #expect(creds.effectiveUserID == getuid())
    }

    @Test func linuxCaptureRejectsNonSocket() {
        #expect(throws: PeerAuthenticationError.missingPeerEvidence) {
            try LinuxSocketPeerCapture.capture(fd: -1)
        }
    }
#endif
}
