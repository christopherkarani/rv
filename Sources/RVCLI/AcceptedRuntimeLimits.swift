/// Accepted runtime limits (R1/R2/R3), in plain words. One source so the
/// launch banner and the help `limits` line cannot drift: Seatbelt cannot
/// scope a loopback listener to loopback, host loopback is shared, and the
/// per-user temp directory is same-user readable (see
/// docs/security/runtime-boundary.md).
enum AcceptedRuntimeLimits {
    static let line =
        "A caged loopback server is reachable from the LAN and from other local processes — treat caged ports as LAN-visible. Same-user temp files are readable by other processes running as you."
}
