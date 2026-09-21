#!/usr/bin/env python3
"""Probe the real rv opencode boundary using only test-owned resources.

JSONL PASS means the named bounded assertion passed. GAP reproduces a missing
security guarantee and is never a release pass. NOT-TESTED records missing
coverage. Exit 0: no gaps; 1: harness/assertion failure; 2: gaps or missing tests.
No Internet traffic, real credentials, or unrelated process targets are used.
"""

import argparse
import errno
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


PREFIX = "RV_PROBE_RESULT="


def require(condition: bool, message: object) -> None:
    """Keep security assertions active when Python optimization is enabled."""
    if not condition:
        raise RuntimeError(str(message))


class Proof:
    def __init__(self, cli: Path, root: Path):
        self.cli = cli
        self.root = root
        self.workspace = root / "workspace"
        self.outside = root / "outside"
        self.workspace.mkdir(mode=0o700)
        self.outside.mkdir(mode=0o700)
        self.results = []

    def emit(self, check, status, **evidence):
        record = {"check": check, "status": status, **evidence}
        self.results.append(record)
        print(json.dumps(record, sort_keys=True), flush=True)

    def launch(self, executable, arguments, *, workspace=None, extra_env=None, pass_fds=(), through_path=False):
        environment = {
            key: os.environ[key]
            for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME")
            if key in os.environ
        }
        environment.update(extra_env or {})
        if through_path:
            environment["PATH"] = str(self.cli.parent) + ":/usr/bin:/bin"
        return subprocess.run(
            [self.cli.name if through_path else str(self.cli), "opencode", "--workspace", str(workspace or self.workspace),
             "--executable", str(executable), "--", *arguments],
            cwd=self.root,
            env=environment,
            pass_fds=pass_fds,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            check=False,
        )

    def python(self, source, arguments=(), **options):
        # The extra shell/exec proves the child interpreter inherits enforcement.
        command = shlex.join([sys.executable, "-c", source, *map(str, arguments)])
        result = self.launch("/bin/sh", ["-c", "exec " + command], **options)
        records = [line[len(PREFIX):] for line in result.stdout.splitlines() if line.startswith(PREFIX)]
        if result.returncode != 0 or len(records) != 1:
            raise RuntimeError(
                f"probe did not complete: exit={result.returncode}, records={len(records)}, "
                f"stderr={result.stderr[-500:]!r}"
            )
        return json.loads(records[0])

    def control_write_fence(self, through_path=False):
        prefix = "path-control" if through_path else "control"
        own = self.workspace / (prefix + "-inside")
        escaped = self.outside / (prefix + "-outside")
        result = self.launch("/bin/sh", ["-c", f"printf ran > {shlex.quote(str(own))}; printf escaped > {shlex.quote(str(escaped))}"], through_path=through_path)
        require(own.read_text() == "ran", "inner process never ran")
        require(result.returncode != 0, "denied write returned success")
        require(not escaped.exists(), "outside write escaped")
        self.emit("cli-path-write-fence-control" if through_path else "cli-write-fence-control",
                  "PASS", inside_written=True, outside_written=False, through_path=through_path)

    def network(self, name, family, kind, dns=False):
        try:
            server = socket.socket(family, kind)
        except OSError as error:
            if error.errno in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT):
                self.emit(name, "NOT-TESTED", reason="fixture-unavailable", errno=error.errno)
                return
            raise
        try:
            try:
                if family == socket.AF_UNIX:
                    address = str(self.outside / (name + ".sock"))
                elif family == socket.AF_INET6:
                    address = ("::1", 0)
                else:
                    address = ("127.0.0.1", 0)
                server.bind(address)
            except OSError as error:
                if error.errno in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.EADDRNOTAVAIL):
                    self.emit(name, "NOT-TESTED", reason="fixture-unavailable", errno=error.errno)
                    return
                raise
            if kind == socket.SOCK_STREAM:
                server.listen(1)
            address = server.getsockname()
            payload = (
                bytes.fromhex("7276010000010000000000000872762d617564697407696e76616c69640000010001")
                if dns else ("rv-test-owned-" + uuid.uuid4().hex).encode()
            )
            observed = self.python(NETWORK_PROBE, [int(family), int(kind), json.dumps(address), payload.hex()])
            server.settimeout(0.5)
            received = None
            try:
                if kind == socket.SOCK_STREAM:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(1)
                        received = connection.recv(4096)
                else:
                    received, _ = server.recvfrom(4096)
            except TimeoutError:
                pass
            if observed["sent"]:
                require(received == payload, "child claimed send without fixture receiving exact payload")
                self.emit(name, "GAP", child_shell=True, interpreter=True, fixture_received=True,
                          reason="network-authority-exists-without-network-grant")
            else:
                require(observed.get("errno") in (errno.EPERM, errno.EACCES), observed)
                require(received is None, "denied client still delivered payload")
                self.emit(name, "PASS", fixture_received=False, denial_errno=observed["errno"])
        finally:
            server.close()

    def credentials(self):
        names = [".ssh/id_ed25519", ".aws/credentials", ".env", ".git-credentials", ".zsh_history",
                 "Library/Application Support/Browser/Cookies", "Library/Keychains/login.keychain-db"]
        paths = []
        for relative in names:
            path = self.outside / "fake-home" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("RV-SYNTHETIC-NOT-A-SECRET")
            paths.append(str(path))
        observed = self.python(CREDENTIAL_PROBE, paths)
        require(observed["attempted"] == len(paths), "credential probe skipped a fixture")
        self.emit("synthetic-outside-credentials", "GAP" if observed["read"] else "PASS",
                  attempted=observed["attempted"], readable=observed["read"],
                  reason="synthetic-fixtures-only-no-real-credentials")

    def inherited_descriptor(self):
        target = self.outside / "inherited-descriptor"
        descriptor = os.open(target, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            os.write(descriptor, b"original")
            identity = os.fstat(descriptor)
            observed = self.python(DESCRIPTOR_PROBE, [descriptor, identity.st_dev, identity.st_ino],
                                   pass_fds=(descriptor,))
            changed = target.read_bytes() != b"original"
            require(changed == observed["wrote"], "descriptor observation and resource effect disagree")
            self.emit("inherited-descriptor-above-stdio", "GAP" if changed else "PASS",
                      original_descriptor=descriptor, outside_modified=changed,
                      reason="test-owned-file-descriptor")
        finally:
            os.close(descriptor)

    def recursive_cli(self):
        own = self.workspace / "recursive-ran"
        escaped = self.outside / "recursive-escaped"
        script = f"printf ran > {shlex.quote(str(own))}; printf escaped > {shlex.quote(str(escaped))}"
        result = self.launch(self.cli, ["opencode", "--workspace", str(self.workspace),
                                      "--executable", "/bin/sh", "--", "-c", script])
        require(own.read_text() == "ran", "recursive CLI did not enter controlled payload")
        require(result.returncode != 0, "recursive outside write returned success")
        require(not escaped.exists(), "recursive outside write escaped")
        self.emit("recursive-rv-write-fence", "PASS", recursive_payload_ran=True, outside_written=False)

    def startup_failures(self):
        marker = self.workspace / "must-not-execute"
        script = "printf executed > " + shlex.quote(str(marker))
        for name, workspace, executable in [
            ("missing-workspace", self.root / "absent-workspace", "/bin/sh"),
            ("root-workspace", Path("/"), "/bin/sh"),
            ("relative-executable", self.workspace, "sh"),
            ("missing-executable", self.workspace, self.root / "absent-executable"),
        ]:
            result = self.launch(executable, ["-c", script], workspace=workspace)
            require(result.returncode != 0, name)
            require(not marker.exists(), name)
            self.emit("startup-" + name, "PASS", exit=result.returncode, marker_present=False)
        self.emit("runtime-policy-parser-failure", "NOT-TESTED",
                  reason="current-launcher-has-no-runtime-policy-configuration-parser")

    def synthetic_signal(self):
        victim = subprocess.Popen(["/bin/sleep", "10"], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            observed = self.python(SIGNAL_PROBE, [victim.pid])
            if observed["sent"]:
                require(victim.wait(timeout=2) == -signal.SIGTERM, "fixture did not die from SIGTERM")
                self.emit("signal-test-owned-unrelated-process", "GAP", signal_delivered=True,
                          reason="victim-is-harness-owned-sleep-only")
            else:
                require(observed.get("errno") in (errno.EPERM, errno.EACCES), observed)
                require(victim.poll() is None, "signal-denied fixture unexpectedly terminated")
                self.emit("signal-test-owned-unrelated-process", "PASS", signal_delivered=False)
        finally:
            if victim.poll() is None:
                victim.terminate()
            try:
                victim.wait(timeout=2)
            except subprocess.TimeoutExpired:
                victim.kill()
                victim.wait(timeout=2)

    def environment(self):
        variables = {
            "RV_AUDIT_SYNTHETIC_SECRET": "synthetic-not-a-secret",
            # Empty insertion lists exercise inheritance without loading any
            # code or aborting the trusted CLI before it reaches its launcher.
            "LD_PRELOAD": "",
            "LD_LIBRARY_PATH": str(self.outside / "not-a-library-directory"),
            "DYLD_INSERT_LIBRARIES": "",
            "DYLD_LIBRARY_PATH": str(self.outside / "not-a-library-directory"),
            "PYTHONPATH": str(self.outside / "not-a-python-directory"),
            "BASH_ENV": str(self.outside / "not-a-shell-script"),
            "ENV": str(self.outside / "not-a-shell-script"),
        }
        observed = self.python(ENVIRONMENT_PROBE, variables, extra_env=variables)
        self.emit("synthetic-secret-and-loader-environment", "GAP" if observed["present"] else "PASS",
                  inherited_names=observed["present"], values_logged=False)

    def supervisor_sigkill(self):
        ready = self.workspace / "supervisor-kill-ready"
        release = self.workspace / "supervisor-kill-released"
        survived = self.workspace / "supervisor-kill-survived"
        environment = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        command = [str(self.cli), "opencode", "--workspace", str(self.workspace),
                   "--executable", sys.executable, "--", "-c", SUPERVISOR_PROBE,
                   str(ready), str(release), str(survived)]
        # The child has its own alarm and deadline. Only this Popen supervisor
        # receives SIGKILL; the harness never signals the reported child PID.
        with subprocess.Popen(command, cwd=self.root, env=environment,
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) as supervisor:
            try:
                deadline = time.monotonic() + 8
                while not ready.exists() and supervisor.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                require(ready.exists(), "contained self-expiring child never became ready")
                child_pid = int(ready.read_text())
                require(supervisor.poll() is None, "supervisor exited before SIGKILL probe")
                supervisor.kill()
                require(supervisor.wait(timeout=2) == -signal.SIGKILL, "supervisor was not killed by SIGKILL")
                pending_release = release.with_suffix(".pending")
                pending_release.write_text("supervisor-reaped")
                pending_release.replace(release)
                deadline = time.monotonic() + 2
                while not survived.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if survived.exists():
                    require(survived.read_text() == "survived", "invalid child survival evidence")
                    self.emit("supervisor-SIGKILL-cleanup", "GAP", supervisor_exit=-signal.SIGKILL,
                              child_wrote_after_supervisor_death=True,
                              reason="contained-child-retains-workspace-authority-after-supervisor-death")
                else:
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        self.emit("supervisor-SIGKILL-cleanup", "PASS", supervisor_exit=-signal.SIGKILL,
                                  child_wrote_after_supervisor_death=False, child_exited=True)
                    else:
                        self.emit("supervisor-SIGKILL-cleanup", "NOT-TESTED",
                                  reason="child-still-visible-without-marker-cannot-prove-revocation")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                supervisor.wait(timeout=2)
                # Release any self-expiring fixture that reached readiness late.
                pending_release = release.with_suffix(".pending")
                pending_release.write_text("fixture-cleanup")
                pending_release.replace(release)

    def launchctl_service(self):
        if sys.platform != "darwin":
            self.emit("launchctl-service-write-escape", "NOT-APPLICABLE",
                      reason="Darwin-launchd-fixture")
            return
        label = "dev.rv.audit." + uuid.uuid4().hex
        marker = self.outside / "launchctl-service-escaped"
        script = "printf rv-test-owned > " + shlex.quote(str(marker))
        try:
            result = self.launch("/bin/launchctl", ["submit", "-l", label, "--", "/bin/sh", "-c", script])
            deadline = time.monotonic() + 2
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            if marker.exists():
                require(marker.read_text() == "rv-test-owned", "invalid service write evidence")
                self.emit("launchctl-service-write-escape", "GAP", submission_exit=result.returncode,
                          outside_written=True, reason="service-mediated-write-outside-workspace")
            elif result.returncode != 0 and any(
                phrase in result.stderr.lower() for phrase in ("operation not permitted", "permission denied")
            ):
                self.emit("launchctl-service-write-escape", "PASS", submission_exit=result.returncode,
                          outside_written=False, permission_denial_reported=True)
            else:
                self.emit("launchctl-service-write-escape", "NOT-TESTED", submission_exit=result.returncode,
                          outside_written=False, reason="submission-outcome-inconclusive-no-kernel-denial-proof")
        finally:
            # Only this freshly generated label can be removed; never target an
            # existing service or interpolate a caller-supplied service name.
            cleanup = subprocess.run(["/bin/launchctl", "remove", label],
                                     stdin=subprocess.DEVNULL, capture_output=True,
                                     text=True, timeout=3, check=False)
            require(cleanup.returncode in (0, 3), "test-owned launchctl service cleanup failed")

    def check(self, name, operation):
        try:
            operation()
        except (OSError, subprocess.SubprocessError, AssertionError, RuntimeError, ValueError) as error:
            self.emit(name, "FAIL", error=str(error))


NETWORK_PROBE = r'''
import json, socket, sys
family, kind = int(sys.argv[1]), int(sys.argv[2])
address = json.loads(sys.argv[3])
if isinstance(address, list): address = tuple(address)
payload = bytes.fromhex(sys.argv[4])
result = {"sent": False}
try:
    with socket.socket(family, kind) as client:
        client.settimeout(2)
        if kind == socket.SOCK_STREAM:
            client.connect(address)
            client.sendall(payload)
        else:
            client.sendto(payload, address)
        result["sent"] = True
except OSError as error:
    result["errno"] = error.errno
print("RV_PROBE_RESULT=" + json.dumps(result))
'''

CREDENTIAL_PROBE = r'''
import json, pathlib, sys
read = 0
for path in sys.argv[1:]:
    try:
        if pathlib.Path(path).read_text() == "RV-SYNTHETIC-NOT-A-SECRET": read += 1
    except PermissionError: pass
print("RV_PROBE_RESULT=" + json.dumps({"attempted": len(sys.argv) - 1, "read": read}))
'''

DESCRIPTOR_PROBE = r'''
import json, os, sys
fd, device, inode = map(int, sys.argv[1:])
result = {"wrote": False}
try:
    identity = os.fstat(fd)
    if (identity.st_dev, identity.st_ino) == (device, inode):
        os.write(fd, b"inherited-authority")
        result["wrote"] = True
except OSError as error:
    result["errno"] = error.errno
print("RV_PROBE_RESULT=" + json.dumps(result))
'''

SIGNAL_PROBE = r'''
import json, os, signal, sys
result = {"sent": False}
try:
    os.kill(int(sys.argv[1]), signal.SIGTERM)
    result["sent"] = True
except OSError as error:
    result["errno"] = error.errno
print("RV_PROBE_RESULT=" + json.dumps(result))
'''

ENVIRONMENT_PROBE = r'''
import json, os, sys
print("RV_PROBE_RESULT=" + json.dumps({"present": [key for key in sys.argv[1:] if key in os.environ]}))
'''

SUPERVISOR_PROBE = r'''
import os, pathlib, signal, sys, time
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(12)
ready, release, survived = map(pathlib.Path, sys.argv[1:])
deadline = time.monotonic() + 10
pending_ready = ready.with_suffix(".pending")
pending_ready.write_text(str(os.getpid()))
pending_ready.replace(ready)
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
if release.exists() and release.read_text() == "supervisor-reaped":
    pending_survived = survived.with_suffix(".pending")
    pending_survived.write_text("survived")
    pending_survived.replace(survived)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="built rv CLI executable")
    arguments = parser.parse_args()
    cli = arguments.cli.resolve(strict=True)
    if not cli.is_file() or not os.access(cli, os.X_OK):
        parser.error("--cli must identify an executable file")
    with tempfile.TemporaryDirectory(prefix="rv-cli-audit-", dir="/tmp") as directory:
        proof = Proof(cli, Path(directory))
        proof.emit("scope", "INFO", cli=str(cli), platform=sys.platform,
                   meaning="PASS is bounded evidence; GAP and NOT-TESTED block release claims")
        proof.check("cli-write-fence-control", proof.control_write_fence)
        proof.check("cli-path-write-fence-control", lambda: proof.control_write_fence(through_path=True))
        for name, family, kind, dns in [
            ("network-ipv4-tcp", socket.AF_INET, socket.SOCK_STREAM, False),
            ("network-ipv4-udp", socket.AF_INET, socket.SOCK_DGRAM, False),
            ("network-ipv6-tcp", socket.AF_INET6, socket.SOCK_STREAM, False),
            ("network-ipv6-udp", socket.AF_INET6, socket.SOCK_DGRAM, False),
            ("network-unix-stream", socket.AF_UNIX, socket.SOCK_STREAM, False),
            ("network-unix-datagram", socket.AF_UNIX, socket.SOCK_DGRAM, False),
            ("network-local-dns-packet", socket.AF_INET, socket.SOCK_DGRAM, True),
        ]:
            proof.check(name, lambda n=name, f=family, k=kind, d=dns: proof.network(n, f, k, d))
        for name, operation in [
            ("synthetic-outside-credentials", proof.credentials),
            ("inherited-descriptor-above-stdio", proof.inherited_descriptor),
            ("recursive-rv-write-fence", proof.recursive_cli),
            ("startup-failures", proof.startup_failures),
            ("signal-test-owned-unrelated-process", proof.synthetic_signal),
            ("synthetic-secret-and-loader-environment", proof.environment),
            ("supervisor-SIGKILL-cleanup", proof.supervisor_sigkill),
            ("launchctl-service-write-escape", proof.launchctl_service),
        ]:
            proof.check(name, operation)
        for name in ("network-public-ip", "network-lan", "system-dns-resolver"):
            proof.emit(name, "NOT-TESTED", reason="outside-this-bounded-local-fixture-harness")
        counts = {status: sum(row["status"] == status for row in proof.results)
                  for status in ("PASS", "GAP", "NOT-TESTED", "FAIL")}
        print(json.dumps({"summary": counts, "release_gate": "NOT-SATISFIED"}, sort_keys=True))
        return 1 if counts["FAIL"] else 2 if counts["GAP"] or counts["NOT-TESTED"] else 0


if __name__ == "__main__":
    sys.exit(main())
