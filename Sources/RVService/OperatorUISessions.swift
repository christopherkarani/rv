import Foundation
import RVDomain
import RVIsolation

enum OperatorUISessionError: Error, Sendable, Equatable {
    case wrongComponentRole
}

/// Authenticated RVOperatorUI connections. Ephemeral and memory-only: a
/// service restart drops every session, and Step 3's fresh epoch rejects
/// everything from the prior lifetime regardless.
///
/// Each XPC connection mints exactly one `AuthenticatedOperatorUIConnectionID`
/// at registration. Multiple UI connections may coexist, but every Step 3
/// challenge stays bound to exactly one of them; a connection can never
/// complete a challenge it does not own.
actor LiveOperatorUISessionRegistry {
    struct Session: Sendable {
        let uiConnection: AuthenticatedOperatorUIConnectionID
        let peer: AuthenticatedPeer
    }

    private var sessions: [UUID: Session] = [:]

    /// Registers one authenticated UI connection. Idempotent per connection:
    /// re-registration returns the existing binding.
    func register(peer: AuthenticatedPeer) throws -> AuthenticatedOperatorUIConnectionID {
        guard peer.componentRole == .operatorUI else {
            throw OperatorUISessionError.wrongComponentRole
        }
        if let existing = sessions[peer.connectionID] {
            return existing.uiConnection
        }
        let uiConnection = AuthenticatedOperatorUIConnectionID()
        sessions[peer.connectionID] = Session(uiConnection: uiConnection, peer: peer)
        return uiConnection
    }

    func session(connectionID: UUID) -> Session? {
        sessions[connectionID]
    }

    /// Drops the session, returning its UI connection for ceremony
    /// invalidation (fail-closed: challenged/authorized ceremonies die).
    /// Unknown connections return nil and change nothing.
    func disconnect(connectionID: UUID) -> AuthenticatedOperatorUIConnectionID? {
        sessions.removeValue(forKey: connectionID)?.uiConnection
    }
}
