/*
 * PID 1 of the kernel e2e guest (Scripts/linux-kernel-e2e.sh). Drives the
 * real rv-isolation-exec trampoline on the booted kernel and prints one
 * result line on the serial console, then powers off.
 *
 * Built static, with no loader or libraries in the initramfs: a Landlocked
 * inner cannot read outside the workspace, so a dynamic inner would fail
 * on its own libraries rather than on the boundary under test.
 *
 * The same binary is the inner probe: `probe OP ARGS...` does one
 * filesystem operation and exits 0 on success or with errno (capped below
 * the trampoline's reserved 125/126). The inner runs from a copy inside the
 * workspace: Landlock needs READ_FILE to exec, and rv grants that only
 * beneath the workspace (no system read-only layer yet), so a binary
 * outside it cannot be exec'd at all. `exec-outside-workspace-denied` pins
 * that.
 *
 * Expected kernel regime comes from `rv.expect_abi=N` on the kernel command
 * line (0 = no Landlock). The live probe must match it exactly, so a lane
 * cannot silently test a different regime than it claims.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#endif

#define HELPER "/bin/rv-isolation-exec"
#define SELF "/init"
#define INNER "/e2e/workspace/probe"
#define ROOT "/e2e"
#define WORKSPACE ROOT "/workspace"
#define OUTSIDE ROOT "/outside"
#define ESTABLISH_FAILED 125
#define EXEC_FAILED 126
#define INHERITED_FD 7

static int failures;
static int checks;

/* ---- inner probe ------------------------------------------------------ */

static int probe_exit(int ok) {
    if (ok) {
        return 0;
    }
    return (errno > 0 && errno < 124) ? errno : 124;
}

static int probe(int argc, char **argv) {
    const char *op;
    int fd;
    char byte;

    if (argc < 4) {
        return 124;
    }
    op = argv[2];
    if (strcmp(op, "write") == 0) {
        fd = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        return probe_exit(fd >= 0 && write(fd, "x", 1) == 1);
    }
    if (strcmp(op, "read") == 0) {
        fd = open(argv[3], O_RDONLY);
        return probe_exit(fd >= 0 && read(fd, &byte, 1) >= 0);
    }
    if (strcmp(op, "readdir") == 0) {
        DIR *dir = opendir(argv[3]);
        return probe_exit(dir != NULL);
    }
    if (strcmp(op, "truncate") == 0) {
        return probe_exit(truncate(argv[3], 0) == 0);
    }
    if (strcmp(op, "mkdir") == 0) {
        return probe_exit(mkdir(argv[3], 0755) == 0);
    }
    if (strcmp(op, "rename") == 0 && argc >= 5) {
        return probe_exit(rename(argv[3], argv[4]) == 0);
    }
    if (strcmp(op, "writefd") == 0) {
        return probe_exit(write(atoi(argv[3]), "x", 1) == 1);
    }
    if (strcmp(op, "nnp") == 0) {
        errno = EPERM;
        return probe_exit(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1);
    }
    return 124;
}

/* ---- harness ---------------------------------------------------------- */

static void say(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    fflush(stdout);
}

static void check(int ok, const char *name, const char *format, ...) {
    va_list args;
    checks++;
    if (ok) {
        say("rv-kernel-e2e: PASS %s\n", name);
        return;
    }
    failures++;
    say("rv-kernel-e2e: FAIL %s: ", name);
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    say("\n");
}

static int exists(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0;
}

static int content_is(const char *path, const char *expected) {
    char buffer[64];
    ssize_t size;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    size = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (size < 0) {
        return 0;
    }
    buffer[size] = '\0';
    return strcmp(buffer, expected) == 0;
}

static int copy_file(const char *from, const char *to, mode_t mode) {
    char buffer[65536];
    ssize_t size;
    int ok;
    int in = open(from, O_RDONLY);
    int out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode);
    ok = in >= 0 && out >= 0;
    while (ok && (size = read(in, buffer, sizeof(buffer))) != 0) {
        ok = size > 0 && write(out, buffer, (size_t)size) == size;
    }
    if (in >= 0) {
        close(in);
    }
    if (out >= 0) {
        close(out);
    }
    return ok;
}

static int seed(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ssize_t want = (ssize_t)strlen(text);
    int ok = fd >= 0 && write(fd, text, (size_t)want) == want;
    if (fd >= 0) {
        close(fd);
    }
    return ok;
}

/* Run argv (argv[0] is the program) and return its exit status, or -1 when
 * it did not exit normally. */
static int run(char *const argv[]) {
    int status;
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        execv(argv[0], argv);
        _exit(127);
    }
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status);
}

/* rv-isolation-exec --workspace WS -- INNER probe OP A [B] */
static int contained(const char *workspace, const char *op, const char *a, const char *b) {
    char *argv[] = {
        HELPER, "--workspace", (char *)workspace, "--", INNER, "probe",
        (char *)op, (char *)a, (char *)b, NULL,
    };
    return run(argv);
}

static void common_cases(void) {
    const char *marker = WORKSPACE "/argv-must-not-exec";
    char *no_args[] = {HELPER, NULL};
    char *relative_inner[] = {
        HELPER, "--workspace", WORKSPACE, "--", "init", "probe", "write", (char *)marker, NULL,
    };
    char *missing_separator[] = {
        HELPER, "--workspace", WORKSPACE, SELF, "probe", "write", (char *)marker, NULL,
    };
    int status;

    status = run(no_args);
    check(status == ESTABLISH_FAILED, "argv-empty-exits-125", "exit %d", status);
    status = run(relative_inner);
    check(status == ESTABLISH_FAILED, "argv-relative-inner-exits-125", "exit %d", status);
    status = run(missing_separator);
    check(status == ESTABLISH_FAILED, "argv-missing-separator-exits-125", "exit %d", status);
    status = contained(ROOT "/no-such-workspace", "write", marker, NULL);
    check(status == ESTABLISH_FAILED, "missing-workspace-exits-125", "exit %d", status);
    status = contained(ROOT "/workspace-link", "write", marker, NULL);
    check(status == ESTABLISH_FAILED, "noncanonical-workspace-exits-125", "exit %d", status);
    check(!exists(marker), "rejected-argv-never-execs", "marker exists");
}

/* Landlock absent, disabled, or below ABI 3: the helper must refuse (125)
 * and never exec, rather than run the inner unconfined or with a weaker
 * ruleset that leaves truncate(2) open outside the workspace. */
static void refusal_cases(void) {
    const char *marker = WORKSPACE "/inner-ran";
    const char *outside = OUTSIDE "/written-unconfined";
    int status;

    status = contained(WORKSPACE, "write", marker, NULL);
    check(status == ESTABLISH_FAILED, "valid-argv-refuses-125", "exit %d", status);
    check(!exists(marker), "refusal-never-execs-inner", "inner wrote %s", marker);
    status = contained(WORKSPACE, "write", outside, NULL);
    check(status == ESTABLISH_FAILED && !exists(outside),
        "refusal-no-outside-write", "exit %d, outside exists=%d", status, exists(outside));
    status = contained(WORKSPACE, "truncate", OUTSIDE "/seed.txt", NULL);
    check(status == ESTABLISH_FAILED && content_is(OUTSIDE "/seed.txt", "keep-me\n"),
        "refusal-no-outside-truncate", "exit %d", status);
}

/* ABI >= 3: the helper applies the workspace ruleset, then execs. */
static void enforcement_cases(void) {
    int status;
    int fd;

    status = contained(WORKSPACE, "write", WORKSPACE "/inside.txt", NULL);
    check(status == 0 && exists(WORKSPACE "/inside.txt"), "write-inside-allowed", "exit %d", status);
    status = contained(WORKSPACE, "read", WORKSPACE "/note.txt", NULL);
    check(status == 0, "read-inside-allowed", "exit %d", status);
    status = contained(WORKSPACE, "mkdir", WORKSPACE "/subdir", NULL);
    check(status == 0, "mkdir-inside-allowed", "exit %d", status);

    status = contained(WORKSPACE, "write", OUTSIDE "/outside.txt", NULL);
    check(status == EACCES && !exists(OUTSIDE "/outside.txt"),
        "write-outside-denied", "exit %d", status);
    status = contained(WORKSPACE, "read", OUTSIDE "/seed.txt", NULL);
    check(status == EACCES, "read-outside-denied", "exit %d", status);
    status = contained(WORKSPACE, "readdir", OUTSIDE, NULL);
    check(status == EACCES, "readdir-outside-denied", "exit %d", status);
    status = contained(WORKSPACE, "mkdir", OUTSIDE "/made", NULL);
    check(status == EACCES && !exists(OUTSIDE "/made"), "mkdir-outside-denied", "exit %d", status);
    status = contained(WORKSPACE, "truncate", OUTSIDE "/seed.txt", NULL);
    check(status == EACCES && content_is(OUTSIDE "/seed.txt", "keep-me\n"),
        "truncate-outside-denied", "exit %d", status);
    status = contained(WORKSPACE, "write", WORKSPACE "/escape", NULL);
    check(status == EACCES && !exists(OUTSIDE "/via-link.txt"),
        "symlink-escape-denied", "exit %d", status);
    status = contained(WORKSPACE, "rename", WORKSPACE "/note.txt", OUTSIDE "/moved.txt");
    check((status == EACCES || status == EXDEV) && exists(WORKSPACE "/note.txt")
            && !exists(OUTSIDE "/moved.txt"),
        "rename-out-of-workspace-denied", "exit %d", status);

    status = contained(WORKSPACE, "nnp", "-", NULL);
    check(status == 0, "no-new-privs-set", "exit %d", status);

    /* Descriptors opened before the boundary are closed by the helper, so
     * the inner cannot write through one Landlock never sees. */
    fd = open(OUTSIDE "/fd-target.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0 && fd != INHERITED_FD) {
        dup2(fd, INHERITED_FD);
        close(fd);
    }
    status = contained(WORKSPACE, "writefd", "7", NULL);
    close(INHERITED_FD);
    check(status == EBADF && content_is(OUTSIDE "/fd-target.txt", ""),
        "inherited-fd-closed", "exit %d", status);

    {
        char *argv[] = {HELPER, "--workspace", WORKSPACE, "--", "/no/such/inner", NULL};
        status = run(argv);
        check(status == EXEC_FAILED, "missing-inner-exits-126", "exit %d", status);
    }
    {
        /* Today's ruleset has no system read-only layer: an inner outside
         * the workspace is not readable, so execve fails after apply. */
        char *argv[] = {
            HELPER, "--workspace", WORKSPACE, "--", SELF, "probe", "write",
            WORKSPACE "/outside-binary-ran", NULL,
        };
        status = run(argv);
        check(status == EXEC_FAILED && !exists(WORKSPACE "/outside-binary-ran"),
            "exec-outside-workspace-denied", "exit %d", status);
    }
}

static long expected_abi(void) {
    char line[4096];
    char *found;
    ssize_t size;
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    size = read(fd, line, sizeof(line) - 1);
    close(fd);
    if (size <= 0) {
        return -1;
    }
    line[size] = '\0';
    found = strstr(line, "rv.expect_abi=");
    if (found == NULL) {
        return -1;
    }
    return strtol(found + strlen("rv.expect_abi="), NULL, 10);
}

static int setup(void) {
    int console;
    mkdir("/dev", 0755);
    mkdir("/proc", 0755);
    mkdir(ROOT, 0755);
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) != 0) {
        return 0;
    }
    console = open("/dev/console", O_RDWR);
    if (console < 0) {
        return 0;
    }
    dup2(console, 0);
    dup2(console, 1);
    dup2(console, 2);
    if (console > 2) {
        close(console);
    }
    if (mount("proc", "/proc", "proc", 0, NULL) != 0
        || mount("tmpfs", ROOT, "tmpfs", 0, "mode=0755") != 0) {
        return 0;
    }
    return mkdir(WORKSPACE, 0755) == 0
        && mkdir(OUTSIDE, 0755) == 0
        && symlink(WORKSPACE, ROOT "/workspace-link") == 0
        && symlink(OUTSIDE "/via-link.txt", WORKSPACE "/escape") == 0
        && copy_file(SELF, INNER, 0755)
        && seed(OUTSIDE "/seed.txt", "keep-me\n")
        && seed(WORKSPACE "/note.txt", "inside-note\n");
}

static void finish(long abi, const char *kernel) {
    say("rv-kernel-e2e-result: %s checks=%d failures=%d abi=%ld kernel=%s\n",
        failures == 0 && checks > 0 ? "PASS" : "FAIL", checks, failures, abi, kernel);
    sync();
    reboot(RB_POWER_OFF);
    /* Unreachable unless power-off failed: PID 1 exiting panics the kernel,
     * and panic=-1 with QEMU -no-reboot ends the VM either way. */
    _exit(1);
}

int main(int argc, char **argv) {
    struct utsname uts;
    long expected;
    long live;
    int live_errno;

    if (argc >= 2 && strcmp(argv[1], "probe") == 0) {
        return probe(argc, argv);
    }
    if (getpid() != 1) {
        fprintf(stderr, "guest-init: must run as PID 1 inside the e2e guest\n");
        return 2;
    }
    if (uname(&uts) != 0) {
        strcpy(uts.release, "unknown");
    }
    if (!setup()) {
        say("rv-kernel-e2e: FAIL setup: errno %d\n", errno);
        failures++;
        finish(-1, uts.release);
    }

    errno = 0;
    live = syscall(SYS_landlock_create_ruleset, NULL, (size_t)0, 1u);
    live_errno = live < 0 ? errno : 0;
    expected = expected_abi();
    say("rv-kernel-e2e: kernel=%s landlock_abi=%ld errno=%d expected_abi=%ld\n",
        uts.release, live, live_errno, expected);
    if (expected < 0) {
        check(0, "expected-abi-on-cmdline", "rv.expect_abi= missing");
        finish(live, uts.release);
    }
    if (expected == 0) {
        check(live < 0 && (live_errno == ENOSYS || live_errno == EOPNOTSUPP),
            "kernel-has-no-landlock", "abi %ld errno %d", live, live_errno);
    } else {
        check(live == expected, "kernel-landlock-abi-matches-lane",
            "live abi %ld errno %d, lane expects %ld", live, live_errno, expected);
    }

    common_cases();
    if (live >= 3) {
        enforcement_cases();
    } else {
        refusal_cases();
    }
    finish(live, uts.release);
    return 1;
}
