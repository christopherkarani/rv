#!/usr/bin/env python3
"""Disposable Linux kernel probes. PASS is narrow; GAP never means acceptance.

Run on the host with --output .build/security-audit/linux/baseline (or postfix).
The source tree is mounted read-only. All attack targets are synthetic fixtures
inside a network-disconnected Docker container; host credentials are never read.
"""

import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import time


IMAGE = "rv-security-audit:swift-6.4-python"
ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
FD_PROBE = r'''
import json, os, sys
result = {"executed": True, "wrote": False}
try:
    os.write(int(sys.argv[1]), b'changed!')
    result["wrote"] = True
except OSError as error:
    result["errno"] = error.errno
print(json.dumps(result, sort_keys=True))
'''
PRELOAD_SOURCE = r'''
#define _GNU_SOURCE
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor)) static void probe(void) {
    char executable[4096];
    ssize_t size=readlink("/proc/self/exe", executable, sizeof(executable)-1);
    if(size<0) return;
    executable[size]=0;
    char *base=strrchr(executable,'/');
    if(!base || strcmp(base+1,"rv-isolation-exec")) return;
    int fd=open(MARKER,O_WRONLY|O_CREAT|O_APPEND,0600);
    if(fd>=0){ssize_t ignored=write(fd,"constructor-ran\n",16);(void)ignored;close(fd);}
}
'''


def host_run(args):
    source = Path(__file__).resolve().parents[1]
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    dockerfile = (
        "FROM swift:6.4-noble\n"
        "RUN apt-get update && apt-get install -y --no-install-recommends python3 "
        "&& rm -rf /var/lib/apt/lists/*\n"
    )
    subprocess.run(
        ["docker", "build", "-t", IMAGE, "-"], input=dockerfile, text=True, check=True
    )
    with tempfile.TemporaryDirectory(prefix="rv-linux-container-") as directory:
        cidfile = Path(directory) / "container-id"
        command = [
            "docker", "run", "--rm", "--cidfile", str(cidfile),
            "--network", "none", "--pids-limit", "128",
            "--mount", f"type=bind,src={source},dst=/source,readonly",
            "--mount", f"type=bind,src={output},dst=/evidence",
            IMAGE, "python3", "/source/Scripts/isolation-linux-adversarial.py",
            "--inside", "--output", "/evidence",
        ]
        (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        try:
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=240)
                stdout, stderr, exit_code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout = error.stdout or b""
                stderr = error.stderr or b""
                if isinstance(stdout, bytes):
                    stdout = stdout.decode(errors="replace")
                if isinstance(stderr, bytes):
                    stderr = stderr.decode(errors="replace")
                stderr += "\nFAIL: Linux adversarial container exceeded 240 seconds\n"
                exit_code = 1
            (output / "probe.log").write_text(stdout + stderr)
            print(stdout, end="")
            print(stderr, end="", file=sys.stderr)
            return exit_code
        finally:
            if cidfile.exists():
                container_id = cidfile.read_text().strip()
                if len(container_id) != 64 or any(character not in "0123456789abcdef" for character in container_id):
                    raise RuntimeError("Docker returned an invalid container ID; refusing ambiguous cleanup")
                # Killing the Docker client on timeout does not kill its container.
                # --rm may already have removed a normally completed container.
                cleanup = subprocess.run(["docker", "rm", "--force", container_id],
                                         capture_output=True, text=True, timeout=15, check=False)
                if cleanup.returncode != 0 and "No such container" not in cleanup.stderr:
                    raise RuntimeError("Failed to remove test container: " + cleanup.stderr.strip())


def inside_run(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    with tempfile.TemporaryDirectory(prefix="rv-linux-adversarial-") as temporary:
        root = Path(temporary)
        root.chmod(0o755)
        workspace = root / "workspace"
        outside = root / "outside"
        workspace.mkdir(mode=0o777)
        workspace.chmod(0o777)
        outside.mkdir(mode=0o777)
        outside.chmod(0o777)
        helper = root / "rv-isolation-exec"

        def compile_c(name, source, flags=()):
            code = root / f"{name}.c"
            executable = root / name
            code.write_text(source)
            subprocess.run(
                ["clang", "-O2", "-Wall", "-Wextra", "-Werror", *flags,
                 str(code), "-o", str(executable)], check=True, capture_output=True
            )
            return executable

        subprocess.run(
            ["clang", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I/source/Sources/RVIsolation/include",
             "/source/Sources/rv-isolation-exec/main.c", "-o", str(helper)],
            check=True, capture_output=True,
        )

        def record(name, passed, evidence, gap=False):
            status = "GAP" if gap and not passed else "PASS" if passed else "FAIL"
            row = {"name": name, "status": status, "evidence": evidence}
            rows.append(row)
            print(json.dumps(row), flush=True)

        def finish():
            summary = {status: sum(row["status"] == status for row in rows) for status in ("PASS", "FAIL", "GAP")}
            (output / "results.json").write_text(json.dumps({"summary": summary, "probes": rows}, indent=2) + "\n")
            print(json.dumps({"summary": summary, "release_acceptance": "NOT SATISFIED; GAP rows are release gaps, not passing guarantees"}), flush=True)
            return 1 if summary["FAIL"] else 2 if summary["GAP"] else 0

        def run(command, ws=workspace, env=None, **kwargs):
            return subprocess.run(
                [str(helper), "--workspace", str(ws), "--", *command],
                cwd=workspace, env=env or ENV, capture_output=True, text=True,
                timeout=8, **kwargs,
            )

        def py(code, *arguments, **kwargs):
            return run(["/usr/bin/python3", "-c", code, *map(str, arguments)], **kwargs)

        libc = ctypes.CDLL(None, use_errno=True)
        abi = libc.syscall(444, 0, 0, 1)
        kernel = {
            "kernel": platform.release(), "machine": platform.machine(),
            "landlock_abi": abi, "landlock_errno": ctypes.get_errno(),
            "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
            "environment_boundary": "Docker default seccomp/namespaces; network none; RV adds Landlock only",
        }
        config = Path("/proc/config.gz")
        if config.exists():
            import gzip
            kernel["landlock_kernel_config"] = [line for line in gzip.decompress(config.read_bytes()).decode().splitlines() if "LANDLOCK" in line]
        print(json.dumps(kernel), flush=True)
        (output / "environment.json").write_text(json.dumps(kernel, indent=2) + "\n")
        record("landlock-abi-at-least-3", abi >= 3, kernel, gap=True)

        # Compile the real trampoline with ONLY Landlock syscalls replaced at link
        # time. These are C regression units, explicitly not kernel containment.
        unit = compile_c("unit-rv-isolation-exec", r'''
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
extern long __real_syscall(long number, ...);
long __wrap_syscall(long number, ...) {
    va_list args;
    va_start(args, number);
    long result;
    if (number == 444) {
        (void)va_arg(args, void *);
        (void)va_arg(args, size_t);
        unsigned int flags=va_arg(args, unsigned int);
        result=flags == 1 ? 3 : open("/dev/null", O_RDONLY|O_CLOEXEC);
    } else if (number == 445 || number == 446) {
        result=0;
    } else if (number == 436) {
        if(getenv("RV_TEST_CLOSE_RANGE_FAIL")){errno=EPERM;result=-1;}
        else result=__real_syscall(436, 3u, ~0u, 0u);
    } else if (number == 437) {
        int dirfd=va_arg(args, int);
        const char *path=va_arg(args, const char *);
        const void *how=va_arg(args, const void *);
        size_t size=va_arg(args, size_t);
        if(getenv("RV_TEST_OPENAT2_FAIL")){errno=EPERM;result=-1;}
        else result=__real_syscall(437, dirfd, path, how, size);
    } else {
        errno=ENOSYS;
        result=-1;
    }
    va_end(args);
    return result;
}
''', ["-Wl,--wrap=syscall", "-I/source/Sources/RVIsolation/include", "/source/Sources/rv-isolation-exec/main.c"])
        unit_control = workspace / "unit-launch-control"
        result = subprocess.run([str(unit), "--workspace", str(workspace), "--", "/usr/bin/touch", str(unit_control)], env=ENV, capture_output=True, text=True, timeout=8)
        record("C-unit-launch-control", result.returncode == 0 and unit_control.exists(), {"exit": result.returncode, "marker": unit_control.exists(), "layer": "Landlock syscalls stubbed; proves untrusted command actually executes"})
        fd_target = outside / "unit-fd-target"
        fd_target.write_text("original")
        fd = os.open(fd_target, os.O_WRONLY)
        try:
            result = subprocess.run([str(unit), "--workspace", str(workspace), "--", "/usr/bin/python3", "-c", FD_PROBE, str(fd)], pass_fds=(fd,), env=ENV, capture_output=True, text=True, timeout=8)
        finally:
            os.close(fd)
        try:
            fd_evidence = json.loads(result.stdout)
        except json.JSONDecodeError:
            fd_evidence = None
        record("C-unit-inherited-fd-closed", result.returncode == 0 and fd_evidence == {"executed": True, "wrote": False, "errno": errno.EBADF} and fd_target.read_text() == "original", {"exit": result.returncode, "contents": fd_target.read_text(), "child": fd_evidence, "layer": "Landlock syscalls stubbed; descriptor cleanup is real"})
        retarget = root / "unit-canonical-workspace"
        retarget.mkdir()
        retarget.rename(root / "unit-original-workspace")
        retarget.symlink_to(outside, target_is_directory=True)
        marker = outside / "unit-retarget-marker"
        result = subprocess.run([str(unit), "--workspace", str(retarget), "--", "/usr/bin/touch", str(marker)], env=ENV, capture_output=True, timeout=8)
        record("C-unit-canonical-retarget-rejected", result.returncode == 125 and not marker.exists(), {"exit": result.returncode, "marker": marker.exists(), "layer": "Landlock syscalls stubbed; path resolution is real"})
        for name, variable in [("descriptor-cleanup-error", "RV_TEST_CLOSE_RANGE_FAIL"), ("path-open-error", "RV_TEST_OPENAT2_FAIL")]:
            marker = workspace / f"unit-{name}"
            result = subprocess.run([str(unit), "--workspace", str(workspace), "--", "/usr/bin/touch", str(marker)], env={**ENV, variable: "1"}, capture_output=True, timeout=8)
            record(f"C-unit-{name}-fails-closed", result.returncode == 125 and not marker.exists(), {"exit": result.returncode, "marker": marker.exists(), "layer": "Injected setup failure; no real Landlock enforcement"})

        marker = outside / "pre-main-loader-marker"
        preload = compile_c("preload.so", PRELOAD_SOURCE, ["-shared", "-fPIC", f'-DMARKER="{marker}"'])
        result = run(["/bin/true"], env={**ENV, "LD_PRELOAD": str(preload)})
        record("direct-helper-loader-environment", not marker.exists(), {"exit": result.returncode, "constructor_executed_before_landlock": marker.exists(), "scope": "Direct helper witness; Swift spawn sanitization requires separate integration test"}, gap=True)
        (output / "loader-constructor.c").write_text(PRELOAD_SOURCE)
        if abi < 3:
            marker = workspace / "unsupported-must-not-execute"
            result = run(["/usr/bin/touch", str(marker)])
            record("actual-unsupported-kernel-fails-closed", result.returncode == 125 and not marker.exists(), {"exit": result.returncode, "marker": marker.exists()})
            record("linux-kernel-adversarial-coverage", False, "Actual Landlock enforcement probes unavailable; no substituted sandbox claims. Run this suite on a Landlock ABI >= 3 host.", gap=True)
            return finish()

        inside = workspace / "allowed"
        result = run(["/usr/bin/touch", str(inside)])
        record("workspace-write-allowed", result.returncode == 0 and inside.exists(), result.returncode)
        denied = outside / "denied"
        result = run(["/usr/bin/touch", str(denied)])
        record("outside-write-denied", result.returncode not in (0, 125, 126) and not denied.exists(), result.returncode)
        for name, command in [
            ("nested-shell-exec", ["/bin/sh", "-c", 'exec /bin/sh -c \'/bin/bash -c "touch \\\"$1\\\"" _ "$1"\' _ "$1"', "_", str(denied)]),
            ("env-xargs", ["/usr/bin/env", "/bin/sh", "-c", 'printf "%s\\0" "$1" | /usr/bin/xargs -0 /usr/bin/touch', "_", str(denied)]),
            ("python-subprocess", ["/usr/bin/python3", "-c", "import subprocess,sys;sys.exit(subprocess.run(['/bin/sh','-c','touch '+sys.argv[1]]).returncode)", str(denied)]),
        ]:
            result = run(command)
            record(name, result.returncode not in (0, 125, 126) and not denied.exists(), result.returncode)
        script = workspace / "script"
        script.write_text('#!/usr/bin/env bash\nexec /usr/bin/touch "$1"\n')
        script.chmod(0o755)
        result = run([str(script), str(denied)])
        record("shebang-env", result.returncode not in (0, 125, 126) and not denied.exists(), result.returncode)
        link = workspace / "link"
        link.symlink_to(outside, target_is_directory=True)
        result = run(["/usr/bin/touch", str(link / "denied")])
        record("symlink-write-denied", result.returncode not in (0, 125, 126) and not denied.exists(), result.returncode)
        result = run(["/usr/bin/touch", "../outside/denied"])
        record("parent-traversal-write-denied", result.returncode not in (0, 125, 126) and not denied.exists(), result.returncode)
        moved = outside / "moved"
        result = py("import os,sys;os.rename(sys.argv[1],sys.argv[2])", inside, moved)
        record("rename-outside-denied", result.returncode not in (0, 125, 126) and inside.exists() and not moved.exists(), result.returncode)

        fd_target = outside / "fd-target"
        fd_target.write_text("original")
        fd = os.open(fd_target, os.O_WRONLY)
        try:
            result = py(FD_PROBE, fd, pass_fds=(fd,))
        finally:
            os.close(fd)
        try:
            fd_evidence = json.loads(result.stdout)
        except json.JSONDecodeError:
            fd_evidence = None
        record("inherited-fd-closed", result.returncode == 0 and fd_evidence == {"executed": True, "wrote": False, "errno": errno.EBADF} and fd_target.read_text() == "original", {"exit": result.returncode, "contents": fd_target.read_text(), "child": fd_evidence})

        retarget = root / "canonical-workspace"
        retarget.mkdir()
        retarget.rename(root / "original-workspace")
        retarget.symlink_to(outside, target_is_directory=True)
        marker = outside / "retarget-marker"
        result = run(["/usr/bin/touch", str(marker)], ws=retarget)
        record("canonical-workspace-retarget-rejected", result.returncode == 125 and not marker.exists(), {"exit": result.returncode, "marker": marker.exists()})

        # Deny one setup syscall with seccomp to prove setup errors do not exec.
        fault = compile_c("fault-inject", r'''
#define _GNU_SOURCE
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    unsigned int nr = (unsigned int)strtoul(argv[1], 0, 10);
    struct sock_filter ins[] = {
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, nr, 0, 1),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|38),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW)
    };
    struct sock_fprog program = {4, ins};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) return 3;
    execv(argv[2], &argv[2]);
    return 4;
}
''')
        for name, syscall_number in [("unsupported-landlock-fails-closed", 444), ("descriptor-cleanup-failure-fails-closed", 436)]:
            marker = workspace / name
            result = subprocess.run(
                [str(fault), str(syscall_number), str(helper), "--workspace", str(workspace), "--", "/usr/bin/touch", str(marker)],
                env=ENV, capture_output=True, text=True, timeout=8,
            )
            record(name, result.returncode == 125 and not marker.exists(), {"exit": result.returncode, "marker": marker.exists()})
        for name, arguments in [("malformed-argv", ["--unknown"]), ("missing-workspace", ["--workspace", str(root / "missing"), "--", "/bin/true"]), ("root-workspace", ["--workspace", "/", "--", "/bin/true"])]:
            result = subprocess.run([str(helper), *arguments], env=ENV, capture_output=True, timeout=8)
            record(name, result.returncode == 125, result.returncode)

        # Existing authority gaps are observations, never passing release assertions.
        secret = outside / "synthetic-ssh-id_ed25519"
        secret.write_text("synthetic-secret-only")
        result = py("import pathlib,sys;print(pathlib.Path(sys.argv[1]).read_text())", secret)
        record("outside-synthetic-credential-read", result.returncode != 0, {"exit": result.returncode, "synthetic_value_read": "synthetic-secret-only" in result.stdout}, gap=True)
        hard = workspace / "preexisting-hardlink"
        os.link(secret, hard)
        result = py("import pathlib,sys;pathlib.Path(sys.argv[1]).write_text('mutated')", hard)
        record("preexisting-hardlink-outside-mutation", secret.read_text() == "synthetic-secret-only", {"exit": result.returncode, "outside_mutated": secret.read_text() == "mutated"}, gap=True)
        secret.chmod(0o600)
        result = py("import os,sys;os.chmod(sys.argv[1],0o644)", secret)
        record("outside-chmod", secret.stat().st_mode & 0o777 == 0o600, {"exit": result.returncode, "mode": oct(secret.stat().st_mode & 0o777)}, gap=True)
        old_time = secret.stat().st_mtime_ns
        result = py("import os,sys;os.utime(sys.argv[1],ns=(1000000000,1000000000))", secret)
        record("outside-utime", secret.stat().st_mtime_ns == old_time, {"exit": result.returncode, "mtime_changed": secret.stat().st_mtime_ns != old_time}, gap=True)

        # Real effects against disposable sibling processes, never host processes.
        sleeper = subprocess.Popen(["/bin/sleep", "30"])
        try:
            result = py("import os,signal,sys;os.kill(int(sys.argv[1]),signal.SIGTERM)", sleeper.pid)
            try:
                sleeper.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
            record("signal-unrelated-process", sleeper.poll() is None, {"exit": result.returncode, "victim_exit": sleeper.poll()}, gap=True)
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
            sleeper.wait()
        result = py("import pathlib,sys;print(pathlib.Path('/proc/'+sys.argv[1]+'/status').read_text())", os.getpid())
        record("inspect-supervisor-proc", result.returncode != 0, {"exit": result.returncode, "status_read": "Uid:" in result.stdout}, gap=True)
        result = py("import ctypes,sys;libc=ctypes.CDLL(None,use_errno=True);r=libc.ptrace(16,int(sys.argv[1]),0,0);print(r,ctypes.get_errno());sys.exit(0 if r == -1 else 1)", os.getpid())
        record("ptrace-supervisor-denied", result.returncode == 0 and result.stdout.strip() == "-1 1", {"exit": result.returncode, "result_errno": result.stdout.strip(), "attribution": "Landlock and Docker/Yama may independently deny"})

        for name, family, address in [("tcp-ipv4-localhost", socket.AF_INET, ("127.0.0.1", 0)), ("tcp-ipv6-localhost", socket.AF_INET6, ("::1", 0)), ("unix-path-socket", socket.AF_UNIX, str(outside / "server.sock")), ("unix-abstract-socket", socket.AF_UNIX, "\0rv-adversarial-" + str(os.getpid()))]:
            with socket.socket(family, socket.SOCK_STREAM) as listener:
                listener.bind(address)
                listener.listen(1)
                listener.settimeout(0.3)
                actual = listener.getsockname()
                if isinstance(actual, bytes):
                    actual = os.fsdecode(actual)
                code = "import socket,sys,json;s=socket.socket(int(sys.argv[1]),socket.SOCK_STREAM);a=json.loads(sys.argv[2]);s.connect(tuple(a) if isinstance(a,list) else a);s.sendall(b'probe')"
                result = py(code, family, json.dumps(actual))
                connected = False
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(0.3)
                        connected = connection.recv(5) == b"probe"
                except socket.timeout:
                    pass
                record(name, not connected and result.returncode != 0, {"exit": result.returncode, "server_received_probe": connected}, gap=True)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.settimeout(0.3)
            result = py("import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.sendto(b'\\x12\\x34DNS-PROBE',('127.0.0.1',int(sys.argv[1])))", listener.getsockname()[1])
            received = False
            try:
                received = listener.recv(100) == b"\x12\x34DNS-PROBE"
            except socket.timeout:
                pass
            record("udp-dns-transport", not received and result.returncode != 0, {"exit": result.returncode, "datagram_received": received, "note": "Synthetic DNS-shaped datagram; no external resolver"}, gap=True)

        identity = compile_c("print-identity", "#include <stdio.h>\n#include <unistd.h>\nint main(void){printf(\"%u %u\\n\",getuid(),geteuid());return 0;}\n")
        identity.chmod(0o4755)
        control = subprocess.run([str(identity)], user=65534, group=65534, capture_output=True, text=True, timeout=8)
        result = run([str(identity)], user=65534, group=65534)
        record("setuid-no-new-privs", control.stdout.strip() == "65534 0" and result.stdout.strip() == "65534 65534", {"control": control.stdout.strip(), "contained": result.stdout.strip(), "exit": result.returncode})

        daemon_marker = workspace / "background-after-parent"
        result = py("import os,time,pathlib,sys;p=os.fork();\nif p==0:\n os.setsid();os.close(0);os.close(1);os.close(2);time.sleep(0.2);pathlib.Path(sys.argv[1]).write_text('survived');os._exit(0)", daemon_marker)
        time.sleep(0.4)
        record("background-outlives-supervisor", not daemon_marker.exists(), {"exit": result.returncode, "descendant_wrote_after_parent_exit": daemon_marker.exists()}, gap=True)
        result = run([str(helper), "--workspace", str(outside), "--", "/usr/bin/touch", str(denied)])
        record("recursive-helper-cannot-broaden-landlock", result.returncode != 0 and not denied.exists(), result.returncode)

    return finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--output", default=".build/security-audit/linux/postfix")
    args = parser.parse_args()
    return inside_run(args) if args.inside else host_run(args)


if __name__ == "__main__":
    sys.exit(main())
