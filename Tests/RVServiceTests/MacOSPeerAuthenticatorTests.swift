#if os(macOS)
import Foundation
import RVIsolation
import Testing
@preconcurrency import XPC
@testable import RVService

@Test func fabricatedXPCDictionaryCannotEstablishPeer() {
    let message = xpc_dictionary_create_empty()
    #expect(throws: PeerAuthenticationError.missingPeerEvidence) {
        try MacOSPeerAuthenticator.capture(message: message, connectionID: UUID())
    }
}
#endif
