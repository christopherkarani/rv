---
name: rv
description: How to behave when rv blocks you. Use when a tool call or shell command is denied with "RV · Blocked", asks for human approval, mentions an allow-once code, or when a network request returns an rv.egress.denied.v1 body or a Proxy-Status header naming rv-egress.
---

# Working under rv

rv is a policy gate the human installed on this machine. It checks your shell
commands, file edits, and network requests before they run, and blocks the
ones its policy does not allow. A block is a decision by the human's policy,
not an error to work around.

## Reading a denial

- **Hook deny.** The tool result starts with `RV · Blocked.` and gives one
  reason. It may end with a line like "Paste in Terminal to allow once" and a
  six-character code. That code is for the human, not for you.
- **Needs approval.** "This action requires human approval" means rv staged
  the action for review. The human approves it in the RV app (macOS) or with
  the code in Terminal. After they say it is approved, retry the exact same
  command once.
- **Egress refusal.** A network request gets HTTP 403 (or 407) with a JSON body
  whose `schema` is `rv.egress.denied.v1`. Read these fields:
  - `reason`: `denied-policy` (the policy does not allow this host),
    `dial-failed` (rv could not reach it), `denied-credential` (use the proxy
    URL rv gave you unchanged), `malformed` or `header-too-large`.
  - `host` and `port`: the destination that was refused.
  - `message`: one sentence you can quote to the human.
  - `next_step`: the exact command the human runs on the host. When a
    `proposal_id` is present, rv already filed a review proposal for it.

## What to do

1. Stop. Do not retry the blocked action and do not loop on it.
2. Tell the human, once, in one short message: what you were trying to do,
   the reason rv gave, and the exact command for them to run (copy
   `next_step` or the allow-once line verbatim). Ask for the narrowest grant
   that unblocks this one step: a single allow-once, or one egress approval.
3. Continue with other work that does not need the blocked action, or wait.
4. Retry only after the human says they granted it, and retry the exact
   command that was blocked, not a variant.

## Commands you may run

- `rv explain <command>` shows why rv allows or blocks a command.

## Commands only the human runs

Quote these for the human to run in their own Terminal. Never run them
yourself; rv blocks agents from running them.

- `rv allow-once <code>` redeems the code from a hook deny, once.
- `rv egress approve <id>` approves the egress proposal named in `next_step`.
- `rv egress pending` lists egress proposals waiting for review.
- `rv egress denials` lists recent egress refusals.

## Never

Do not try to get around rv. In particular, never:

- rewrite a blocked command to dodge the check: another binary or path for
  the same tool, an alias or wrapper script, base64 or other encoding,
  `eval`, splitting it into pieces, or moving it into a file you then run;
- edit, move, delete, chmod, or symlink rv's files: anything under
  `~/.config/rv`, the rv hook entries in your host's settings and hooks
  files, rv's binaries, or this skill file;
- run rv administration commands such as `rv uninstall`, `rv setup --observe`,
  `rv host mode <host> off`, `rv packs disable <pack>`,
  `rv allowlist add <rule>`, `rv safety normal`, or `rv policy apply`;
- disable hooks in your host's settings, or ask the human to do it for you.

If you think a rule is wrong, say so to the human and let them decide.

This file is installed and owned by rv. The human's rv setup keeps it current;
rv refuses edits to it from agents.
