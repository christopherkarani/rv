/// What rv's MCP gateway does not provide when its approvals key sits
/// where other processes running as the user can read it, or when this
/// host cannot cage a local server. Both follow from capability values
/// (`MCPApprovalSigning.custodyIsSameUser`, `MCPSandbox.enforced`), not
/// from the OS name. Check, trust, approve and serve share this wording.
public enum MCPPlatformSupport {
    /// The problem `MCPIntegrityStatus.unsupportedPlatform` reports.
    public static let trustUnavailable =
        "MCP gateway trust is unavailable without a key custodian this agent cannot read (macOS today): rv's "
        + "signing key here is a file any process running as you can read, so rv cannot tell its own mcp.json "
        + "from another program's edit; mcp.json stays untrusted and `rv mcp serve` will not launch servers from it"

    /// What `rv mcp approve` says where grants would prove nothing.
    public static let approvalsUnavailable =
        "MCP approvals are unavailable without a key custodian this agent cannot read (macOS today): rv's "
        + "approvals key here is a file any process running as you can read, so a grant could not prove that you "
        + "approved. No approval requests are recorded, and in-client approval prompts need `rv mcp serve`, "
        + "which launches no servers without that custodian"

    /// A server that asks for a sandbox where rv cannot build one.
    public static func sandboxUnenforced(server: String) -> String {
        "\(server) asks for a sandbox, but the MCP server sandbox is unavailable on this host (macOS today); "
            + "`rv mcp serve` will not run it uncaged"
    }

    /// Any local server, when organization policy sets `requireSandbox`
    /// and rv cannot build a sandbox.
    public static func organizationSandboxUnenforced(server: String) -> String {
        "organization policy requires a sandbox for \(server), but the MCP server sandbox is unavailable on this "
            + "host (macOS today); `rv mcp serve` will not run it uncaged"
    }

    /// A server with no sandbox entry where rv cannot build one.
    public static func runsUncaged(server: String) -> String {
        "\(server) has no sandbox, so `rv mcp serve` runs it uncaged: the MCP server sandbox is unavailable on "
            + "this host (macOS today)"
    }
}
