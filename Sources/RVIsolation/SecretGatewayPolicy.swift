import Foundation

/// Where in a request the gateway may swap a placeholder for its value.
/// The body is not a surface; it always passes through untouched.
public enum GatewaySurface: String, Sendable, Hashable, CaseIterable {
    case header
    case query
    case path

    /// Most APIs take credentials in `Authorization` or a custom header.
    /// Query strings and paths land in upstream access logs, so they are opt-in.
    public static let defaults: Set<GatewaySurface> = [.header]

    /// `surfaces` in `allCases` order, for stable config and CLI output.
    public static func ordered(_ surfaces: Set<GatewaySurface>) -> [GatewaySurface] {
        allCases.filter(surfaces.contains)
    }
}
