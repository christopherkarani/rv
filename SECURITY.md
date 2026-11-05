# Security Policy

rv is a fail-closed policy gate. A command that should be denied but is
allowed, a secret that reaches an agent, or a sandbox escape is a security
bug. Please report those privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the
[Security tab](https://github.com/christopherkarani/rv/security) and choose
**Report a vulnerability**. Do not open a public issue or post details in
Discord.

Please include:

- the rv version (`rv --version`) and platform (macOS version or Linux distro)
- the host agent and hook involved, if any
- the smallest command, file path, or config that shows the problem
- what rv did and what it should have done

## Supported versions

Only the latest release gets security fixes. Upgrade by re-running the
installer.

| Version | Supported |
| ------- | --------- |
| 0.2.x (latest) | Yes |
| < 0.2 | No |

## Scope

In scope:

- gate bypasses: a destructive command or secret-file access that rv allows
- fail-open behavior: errors, malformed input, or corrupt config that
  produce `allow` instead of `deny` or `indeterminate`
- secret exposure: real secret bytes reaching an agent, a log, or the audit
  trail
- isolation escapes: Seatbelt, Landlock, egress proxy, or microVM boundaries
- forged or replayable allow-once codes, approvals, or audit entries

Out of scope:

- commands rv is not designed to gate (see the rule packs)
- attacks that require already running arbitrary code as your user outside
  any agent session
- denial of service against your own machine by your own user

## Design notes

The threat model, boundary decisions, and audit evidence live in
[`docs/security`](docs/security).
