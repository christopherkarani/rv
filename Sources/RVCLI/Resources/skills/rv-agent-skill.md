---
name: rv
description: How to behave when rv blocks you. Use when a tool call or shell command is denied with "✕ Stopped" or "RV · Blocked", asks for human approval, mentions an unlock code (rv unlock, or its old name rv allow-once), or when a network request returns an rv.egress.denied.v1 body or a Proxy-Status header naming rv-egress. Also use when a command needs an API key or other secret: run it with rv run --secret.
---

# Working under rv

rv is a policy gate the human installed on this machine. It checks your shell
commands, file edits, and network requests before they run, and blocks the
ones its policy does not allow. A block is a decision by the human's policy,
not an error to work around.

## Reading a denial

- **Hook deny.** Every stop has the same lines:

  ```
  ✕ Stopped   git reset --hard (core.git/reset-hard)
  why     destroys uncommitted changes
  safer   git status
  who     ask Chris to run  rv unlock a1b2c3
  ```

  The first line names the command and the rule that stopped it. `why` is
  the reason. `safer`, when present, is a command rv allows here; you
  may run it instead. `who` is the one step a person takes: the human named
  there runs it, never you. A code in it is for the human, not for you.
- **Needs approval.** A `who` line that says to approve it in RV, or that
  carries an unlock code, means rv staged the action for review. After
  the human says it is approved, retry the exact same command once.
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
   `next_step` or the `who` line verbatim). Ask for the narrowest grant
   that unblocks this one step: a single unlock, or one egress approval.
3. Continue with other work that does not need the blocked action, or wait.
4. Retry only after the human says they granted it, and retry the exact
   command that was blocked, not a variant.

## Using keys

The human keeps API keys in rv, not in files or your environment. To call an
API that needs one, run the command through rv:

    rv run --secret OPENAI_API_KEY -- npm test

The command gets a stand-in that only works from its own processes, toward
that key's API. The real value never reaches you or the transcript.

- `rv secrets describe --json` lists the keys you can use and where each one
  sends; it never shows a value.
- Do not read `.env` files or other secret files to find a key; rv stops it.
- A key rv does not have yet: ask the human to keep it in rv (the command is
  under "Commands only the human runs").
- The commit check stops a key in a commit: take the key out of the file and
  ask the human to keep it in rv. Never switch the check off or mark the line
  as allowed.

## Commands you may run

These only read. If rv does not run where you are (for example inside a
sandbox), quote them for the human instead.

- `rv why <command>` shows why rv allows or blocks a command (`rv explain` is the same command).
- `rv egress pending` lists egress proposals waiting for review.
- `rv egress denials` lists recent egress refusals.
- `rv run --secret NAME -- <command>` runs a command with a key's stand-in.

## Commands only the human runs

Quote these for the human to run in their own Terminal. Never run them
yourself; rv blocks agents from running them.

- `rv unlock <code>` redeems the code from a hook deny, once (`rv allow-once <code>` is the same command).
- `rv egress approve <id>` approves the egress proposal named in `next_step`.
- `rv secrets add NAME` keeps a new key in rv.

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
  `rv allowlist add <rule> --reason <reason>`, `rv safety normal`, or
  `rv policy apply <policy.toml>`;
- switch off or silence the commit check: `git config rv.secretsScan false`,
  an `rv-secrets:allow` comment, or a `.rv-secrets-ignore` entry;
- disable hooks in your host's settings, or ask the human to do it for you.

If you think a rule is wrong, say so to the human and let them decide.

This file is installed and owned by rv, and rv refuses edits to it from agents.
