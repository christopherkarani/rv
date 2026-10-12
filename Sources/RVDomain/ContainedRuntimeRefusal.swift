/// Shared user-facing refusal for the contained runtime on unsupported
/// platforms. One source so CLI, workspace host, and docs cannot drift:
/// hook guard works everywhere, the contained host does not.
public enum ContainedRuntimeRefusal {
    public static let message =
        "contained runtime is macOS-only today — hook guard (rv hook) works on Linux and macOS; the workspace host (rv opencode / rv workspace) refuses on Linux instead of using a weaker sandbox. See docs/security/runtime-boundary.md for why."
}
