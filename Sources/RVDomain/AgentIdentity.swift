#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Human/account principal under whose authority RV operates.
///
/// v1 anchors ownership in the kernel-derived local UID read at mint time.
/// Only `current()` establishes ownership. `init(uid:)` exists so tests can
/// construct fixed values; production code must never build an owner from
/// environment variables or request payloads.
public struct OwnerPrincipal: Hashable, Sendable, Equatable, Codable {
    public let uid: UInt32

    /// Kernel-derived owner of this process. The only production path.
    public static func current() -> OwnerPrincipal {
        OwnerPrincipal(uid: getuid())
    }

    /// Fixed value for tests. Does not establish ownership.
    public init(uid: UInt32) {
        self.uid = uid
    }
}

/// Stable operator-controlled name of one Agent Definition.
///
/// A name, not authentication. The definition originates from trusted
/// RV/operator configuration, never from the contained workload.
public struct AgentDefinitionID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(validating rawValue: String) {
        guard AgentTagValidator.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = AgentDefinitionID(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid AgentDefinitionID"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identifier RV mints for one concrete execution of an Agent Definition.
///
/// This is not `RuntimeSessionID`, not `WorkspaceSessionID`, and not hook
/// `SessionID`. A new process group always mints a fresh value; `init()`
/// always mints. `init(rawValue:)` only names an identifier RV already
/// minted. Naming one does not create an instance and grants nothing.
public struct AgentInstanceID: Hashable, Sendable, Equatable, Codable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
