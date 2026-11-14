# Gate change audit

rv records changes to the gate itself in the hash-chained `audit.jsonl`:

- `policy.changed`: a machine or repo `policy.toml` save, rollback or
  reinitialize. It carries the revision, content hash, rule count and the
  prior revision. The repo workspace is shown with the home directory as `~`.
- `config.changed`: the safety level, `guard.hosts.<host>`, `guard.mode`,
  packs, the allowlist, `secrets.json` definitions, and `rv egress
  approve|deny`. It carries the prior and new values.
- `policy.managed`: an accepted organization serial, or a bundle that stops
  verifying, is removed, or changes.

Every event carries `authorized_by` (the owner check that passed, the
organization signature, or `none`) and `direction`. Events name rule ids,
secret names and hosts only. They never include command text, secret values
or policy bodies.

## Write-ahead and direction

The event is appended before the change is written. Waits on the log's locks
are bounded (one second by default). When the log cannot take the event,
because it is unwritable or its lock is not free in time, enforcement comes
before audit completeness:

- A change known to tighten the gate is made anyway. rv warns on stderr and
  tries once more to record it afterwards, with the reason `recorded after
  the change; the audit log was unavailable` and the change's own time in
  `changed_at`. The warning names the event kind, subject and that time.
  (Events have no id.)
- Any other change is refused, and nothing is written. This covers a change
  that loosens the gate, a mixed change, and one that cannot be classified.
  The CLI exits 74 (`EX_IOERR`) with "the audit log could not record the …
  change, so it was not made".

How each change is classified:

| Change | Tightening when |
| --- | --- |
| Policy revision | every new or changed rule is a deny and `PolicyDiffRisk` finds nothing in the replacement. Any removed or relaxed deny or ask, new allow or ask (an ask can relax an action a pack denies), safety downgrade or new exemption loosens it. So does an unreadable live file. |
| Reinitialize | never |
| Safety level | the new level is `strict` |
| Host mode | the new mode is `block`, or the stored prior mode is looser than the new one |
| `guard.mode` observe | never |
| Packs | the new set enables a superset and disables a subset of the old one |
| Allowlist | entries are only removed |
| Secrets | definitions are only removed. An unreadable prior file counts as loosening. |
| Egress review | the decision is `deny` |
| Organization serial accepted | never |

If the write fails after its event was appended, rv appends a copy with
decision `failed` and the reason `write failed; may be partially applied`.
Some writes, such as a file followed by a log line or a chmod, can fail part
way, so the copy does not claim that nothing changed.

Ordering:

- `rv host mode <host> off` records the change before it removes the hooks.
- `rv secrets set` for a new secret and `rv secrets remove` write
  `secrets.json` (and record the change) before they touch the keychain.
- `rv secrets set` on an existing secret stores the value first and writes
  the definition (a new expiry or refresh) second. If the store fails, the
  old value keeps its old expiry. If the definition is then refused, the new
  value keeps the old expiry, which is never later.

So a change that is refused leaves the hooks and keychain as they were.
`rv safety`, `rv host mode`, `rv packs`, `rv policy apply`, `rv egress`,
`rv secrets set|remove|import` and `rv setup --observe` all exit 74 for a
refused change.

## Residuals

- Only changes made through rv are recorded. An edit to `config.json`,
  `policy.toml` or `secrets.json` made with any other tool goes unrecorded.
  rv sees the result on its next load.
- A crash between the append and the write leaves an event that records
  intent only: the change it names may never have happened.
- `rvd` records organization bundle transitions it observes while it is
  running. The first bundle state a process loads is its baseline and is not
  recorded, so a bundle removed or swapped while `rvd` is down goes
  unrecorded. A newly accepted serial is still recorded where it is accepted.
- A tightening change made while the log is unavailable can stay unrecorded
  if the late record also fails. The stderr warning says so.
