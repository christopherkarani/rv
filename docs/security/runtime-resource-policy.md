# Runtime resource profiles

The workspace host reads `~/.config/rv/runtime-resources.json` from the
account's passwd home when it starts. This is an **operator-authored** file:
the containing directory must be owned by the account and not writable by
group or others, and the JSON file must be owned by the account with mode
`0600`. Missing policy grants no extra resources. An unreadable, malformed, or
newer policy prevents the host from starting.

Each profile has an arbitrary ID and an exact canonical original project path.
The client selects the ID explicitly when it launches a runtime. A command
name, executable path, discovered installation, preset, and hook never select
a profile. A launch with no profile ID gets the base workspace fence only. An
unknown ID or a profile not scoped to the project is refused before spawn.

Here is a template for **one** project. Replace every `/ABSOLUTE/...` path
with an inspected absolute path on this machine, remove unused entries, and
set the real canonical project path. Do not copy the template unchanged. The
first profile illustrates a CLI with a package tree and two home credentials;
the second illustrates a CLI with a gateway key and a private scratch root.
Neither profile is selected automatically.

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "coding-a",
      "projects": ["/ABSOLUTE/CANONICAL/PROJECT"],
      "executableLinks": [
        { "name": "tool-a", "target": "/ABSOLUTE/TOOL-A/BINARY" }
      ],
      "readFiles": [],
      "readTrees": ["/ABSOLUTE/TOOL-A/PACKAGE"],
      "writeTrees": [],
      "credentials": [
        { "source": "/ABSOLUTE/HOME/.tool-a/auth.json", "destination": ".tool-a/auth.json" },
        { "source": "/ABSOLUTE/HOME/.tool-a/config.toml", "destination": ".tool-a/config.toml" }
      ],
      "environment": []
    },
    {
      "id": "coding-b",
      "projects": ["/ABSOLUTE/CANONICAL/PROJECT"],
      "executableLinks": [
        { "name": "tool-b", "target": "/ABSOLUTE/TOOL-B/BINARY" }
      ],
      "readFiles": ["/ABSOLUTE/TOOL-B/version.json"],
      "readTrees": [],
      "writeTrees": ["/ABSOLUTE/PRIVATE/TOOL-B/SCRATCH"],
      "credentials": [],
      "environment": [
        { "name": "TOOL_B_API_KEY", "hostVariable": "TOOL_B_API_KEY" },
        { "name": "TOOL_B_NO_UPDATE", "literalValue": "1" }
      ]
    }
  ]
}
```

## Migrating existing agent resources

Inventory the actual installed binary, its symlink target, and the support
files it reads. Record those paths in an explicit profile. For Codex, include
its package tree and the `~/.codex/auth.json` and `~/.codex/config.toml`
destinations. For OpenCode, include its binary and
`~/.local/share/opencode/auth.json`. For Claude, include its binary,
`~/.claude/.credentials.json`, `settings.json`, and `settings.local.json` when
present; list required gateway environment variables explicitly. A gateway
placeholder for `ANTHROPIC_API_KEY` can be an explicit `literalValue` when the
gateway ignores it. Claude may
also require its hardcoded `/tmp/claude-<uid>` scratch path. For Muse, include
the launcher, its version metadata and current versioned binary as exact
files, `~/.config/muse/auth.json` when used, and an explicit `META_API_KEY`
host environment mapping when key authentication is used.

Literal values are intended for non-secret flags and placeholders. Map actual
keys from the trusted host environment with `hostVariable`. The host refuses
profiles that override its `PATH`, `HOME`, `TMPDIR`, terminal, locale, or proxy
variables.

Installed locations vary, so the operator must inspect them. RV does not
infer support paths or copy credentials from these names. The host stages
only the selected profile's credentials into a fresh runtime-private home;
it does not place credential links in the shared workspace. If a profile is
absent, the agent can still start under the base fence but may report missing
authentication. The profile must be selected on each launch that needs it.

These grants do not prove complete isolation. The existing Seatbelt Mach
baseline and descendant lifetime limits remain separate security questions.
