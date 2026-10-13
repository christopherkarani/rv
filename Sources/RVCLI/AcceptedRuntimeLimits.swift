/// Accepted runtime limits (R1/R2/R3), in plain words. One source so the
/// launch banner and the help `limits` line cannot drift. Seatbelt cannot
/// scope bind/listen to loopback, so a caged process can serve 0.0.0.0, ::,
/// and LAN addresses; outbound LAN connect stays denied, and a real
/// loopback bind is not reachable from the LAN. Host loopback is shared.
/// The cage is granted read-write on the host per-user temp directory (see
/// docs/security/runtime-boundary.md).
enum AcceptedRuntimeLimits {
    static let line =
        "Seatbelt cannot scope bind and listen to loopback, so a caged process can bind, listen, and accept on 0.0.0.0, ::, and LAN addresses, and RV cannot prevent that. Outbound connect to the LAN stays denied. A server that actually binds 127.0.0.1 or ::1 is not reachable from the LAN. Host loopback is shared, so another workspace or the unsandboxed host can connect to a caged server's port. The cage is granted read-write on the host per-user temp directory (confstr _CS_DARWIN_USER_TEMP_DIR, outside the workspace), and other processes running as the same user can read and write that directory."
}
