# Phase 2A development trust provisioning

`Scripts/phase2a-development-trust.sh` is an explicit administrator operation. It
does not invoke `sudo`, install production trust, or trust user-writable build
paths. First build `rvd`, `rv-workspace-host`, and optionally `rv`. Then an
administrator runs, using absolute paths to those build artifacts:

```sh
sudo Scripts/phase2a-development-trust.sh install \
  --host /absolute/build/rv-workspace-host \
  --service /absolute/build/rvd \
  --cli /absolute/build/rv
```

The script copies binaries into the fixed root-owned directory
`/Library/Application Support/RV/phase2a-development`, removes inherited ACLs
from copies, and signs the copies with ad-hoc hardened runtime, distinct signing
identifiers, and no entitlements. Build originals remain untouched. The manifest
at `/Library/Application Support/RV/peer-trust.json` pins each role to both the
installed executable's exact CDHash requirement and its exact protected path.
There is no wildcard, path/basename inference, environment override, or UID
fallback. Existing installation/configuration causes refusal rather than an
overwrite. All ancestors must be root-owned, without group/other write bits or
ACL allow entries, matching the runtime trust loader's conservative restrictions.

Run integration journeys with these installed copies. A user-writable original,
copied executable at a different path, CLI acting as a host, changed signed bytes,
or an unhardened process must receive no host role. Successful script execution
establishes provisioning only; a real multi-process journey must independently
prove that the runtime loader and received-message code verifier assign roles.

Cleanup is explicit:

```sh
sudo Scripts/phase2a-development-trust.sh uninstall
```

Cleanup verifies the SHA-256 receipt for the installed copies and fixed manifest
before removing exactly those artifacts. Changed bytes cause refusal. It uses no
recursive deletion and preserves unrelated files in the shared RV directory.
Restart surviving processes after install or cleanup; deleting files is not a
substitute for revoking already-open process connections. Installation failure
rolls back artifacts created by this invocation through its exit trap. Abrupt
process termination, such as `SIGKILL`, can leave a partial installation; a later
install refuses it, and an administrator must inspect it before cleanup. No
installation has been executed merely by adding this script.

## Transport forwarding proof remains distinct

The existing Unix peer verifier explicitly authenticates the connector, not each
later writer of a forwarded descriptor. `FD_CLOEXEC` is insufficient evidence
against deliberate descriptor transfer. Runtime launch does close unlisted
descriptors with `POSIX_SPAWN_CLOEXEC_DEFAULT`, preserving only explicitly installed
admission/terminal descriptors. Those facts support inheritance containment but
do not establish a generic Unix forwarding defense.

The XPC peer verifier instead derives `SecCode` from each received message with
`SecCodeCreateWithXPCMessage`, before asynchronous dispatch. A bridge must check
that per-message evidence against the registered host role and connection binding;
authenticating only Hello would be insufficient. Forwarding an anonymous endpoint
is discovery of a destination, not evidence that the later sender is a host.
Whether forwarding an actual send right or connection preserves meaningful
authority must still be exercised by a real hostile separate process. Existing
same-process XPC tests and signature metadata are not that proof. Until the
distinct-process forwarding test runs and demonstrates rejection, this gate is
**BLOCKED**.
