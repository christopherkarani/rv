# rv user guides

Guides for the developer or platform engineer who installs rv and runs
agents behind it. They assume you know your agent and a shell, and nothing
about rv's internals. For design notes and audit evidence see
[`docs/security`](../security); those pages are written for contributors.

| Guide | Read it when |
| --- | --- |
| [Install and first run](install.md) | You are putting rv on a Mac or a Linux machine for the first time |
| [Secrets placeholders](secrets-placeholders.md) | An agent, a script or an MCP server needs an API key and should not see it |
| [The MCP gateway](mcp-gateway.md) | You want every MCP tool call to go through one policy and one log |
| [The audit log](audit-log.md) | You need to show what rv allowed, refused and changed |
| [Troubleshooting](troubleshooting.md) | A message from rv stopped your agent or your MCP client |
| [Known limits](known-limits.md) | You need to know what rv does not do before you rely on it |

Platform notes in these guides: anything marked **macOS** (Keychain,
RVApprovals.app, Touch ID, the Seatbelt cage) was taken from the source
code; the Linux behaviour was run. See each guide's "How this was checked"
line.
