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
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <termios.h>
#include <sys/sysmacros.h>
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
#define SCRATCH ROOT "/scratch"
#define UNIX_SOCKET OUTSIDE "/socket"
#define TEMP ROOT "/temp"
#define TEMP_SOCKET TEMP "/socket"
#define SCRATCH_SOCKET SCRATCH "/socket"
#define ABSTRACT_SOCKET "rv-kernel-e2e"
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
    if (strcmp(op, "tcp") == 0 || strcmp(op, "udp") == 0) {
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons((unsigned short)atoi(argv[3]));
        if (strcmp(op, "tcp") == 0) {
            fd = socket(AF_INET, SOCK_STREAM, 0);
            return probe_exit(fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
        }
        fd = socket(AF_INET, SOCK_DGRAM, 0);
        return probe_exit(fd >= 0
            && sendto(fd, "x", 1, 0, (struct sockaddr *)&address, sizeof(address)) == 1);
    }
    if (strcmp(op, "unix") == 0 || strcmp(op, "abstract") == 0) {
        struct sockaddr_un address;
        socklen_t length;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        if (strcmp(op, "unix") == 0) {
            strncpy(address.sun_path, argv[3], sizeof(address.sun_path) - 1);
            length = sizeof(address);
        } else {
            strncpy(address.sun_path + 1, argv[3], sizeof(address.sun_path) - 2);
            length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(argv[3]));
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        return probe_exit(fd >= 0 && connect(fd, (struct sockaddr *)&address, length) == 0);
    }
    if (strcmp(op, "signal") == 0) {
        return probe_exit(kill(atoi(argv[3]), 0) == 0);
    }
    if (strcmp(op, "ioctl") == 0) {
        struct termios modes;
        fd = open(argv[3], O_RDWR);
        if (fd < 0) {
            return errno;
        }
        /* Not a terminal: reaching the driver at all is the access. */
        return probe_exit(ioctl(fd, TCGETS, &modes) == 0 || errno == ENOTTY);
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

/* ABI >= 3 only: below it the helper exits 125 for every argv, so these
 * cases could not tell the argv lock from the ABI refusal. */
static void argv_lock_cases(void) {
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

/* Setup failed before /dev/console was usable: point stdout at the console
 * anyway (creating the node if devtmpfs never mounted) so the FAIL line
 * still reaches the serial log. */
/* ---- MCP server confinement (rv-isolation-exec --confine) -------------- */

/* rv-isolation-exec --confine FLOOR --read WORKSPACE --write SCRATCH
 *     --temp TEMP --temp /dev [--tcp PORT] -- INNER INNER probe OP A */
static int confined(const char *floor, const char *port, const char *op, const char *a) {
    char *argv[20];
    int count = 0;
    argv[count++] = HELPER;
    argv[count++] = "--confine";
    argv[count++] = (char *)floor;
    argv[count++] = "--read";
    argv[count++] = WORKSPACE;
    argv[count++] = "--write";
    argv[count++] = SCRATCH;
    argv[count++] = "--temp";
    argv[count++] = TEMP;
    argv[count++] = "--temp";
    argv[count++] = "/dev";
    if (port != NULL) {
        argv[count++] = "--tcp";
        argv[count++] = (char *)port;
    }
    argv[count++] = "--";
    argv[count++] = INNER;
    argv[count++] = INNER; /* the inner's own argv[0] */
    argv[count++] = "probe";
    argv[count++] = (char *)op;
    argv[count++] = (char *)a;
    argv[count] = NULL;
    return run(argv);
}

/* A TCP listener on loopback; returns its port, or 0. */
static int tcp_listener(void) {
    struct sockaddr_in address;
    socklen_t length = sizeof(address);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 8) != 0
        || getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        return 0;
    }
    return ntohs(address.sin_port);
}

/* A pathname Unix listener this process holds. */
static int unix_listener(const char *path) {
    struct sockaddr_un address;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, path);
    return fd >= 0 && bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0;
}

/* Loopback up, two TCP listeners, three pathname Unix listeners (outside
 * every root, in the --temp root, in the --write root) and one abstract
 * one, all held by this process, outside any cage. */
static int confine_setup(char *port_a, char *port_b, size_t size) {
    struct ifreq interface;
    struct sockaddr_un address;
    int control = socket(AF_INET, SOCK_DGRAM, 0);
    int fd;
    int a;
    int b;

    memset(&interface, 0, sizeof(interface));
    strcpy(interface.ifr_name, "lo");
    interface.ifr_flags = IFF_UP;
    if (control < 0 || ioctl(control, SIOCSIFFLAGS, &interface) != 0) {
        return 0;
    }
    a = tcp_listener();
    b = tcp_listener();
    if (a == 0 || b == 0 || mkdir(SCRATCH, 0755) != 0 || mkdir(TEMP, 0755) != 0) {
        return 0;
    }
    if (!unix_listener(TEMP_SOCKET) || !unix_listener(SCRATCH_SOCKET)) {
        return 0;
    }
    snprintf(port_a, size, "%d", a);
    snprintf(port_b, size, "%d", b);

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, UNIX_SOCKET);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 8) != 0) {
        return 0;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path + 1, ABSTRACT_SOCKET);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    return fd >= 0
        && bind(fd, (struct sockaddr *)&address,
            (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ABSTRACT_SOCKET))) == 0
        && listen(fd, 8) == 0;
}

/* Below ABI 4 nothing is confined and nothing runs. */
static void confine_refusal_cases(void) {
    const char *marker = WORKSPACE "/confine-refusal-ran";
    int status = confined("4", NULL, "write", marker);
    check(status == ESTABLISH_FAILED, "confine-refuses-125", "exit %d", status);
    check(!exists(marker), "confine-refusal-never-execs", "inner wrote %s", marker);
}

/* ABI 4 and up: files and TCP always; each other channel is open below
 * the ABI that closes it and closed from it on. */
static void confine_cases(long abi) {
    char port_a[16];
    char port_b[16];
    int status;

    if (!confine_setup(port_a, port_b, sizeof(port_a))) {
        check(0, "confine-setup", "errno %d", errno);
        return;
    }
    status = confined("4", NULL, "read", WORKSPACE "/note.txt");
    check(status == 0, "confine-read-allowed", "exit %d", status);
    status = confined("4", NULL, "read", OUTSIDE "/seed.txt");
    check(status == EACCES, "confine-read-outside-denied", "exit %d", status);
    status = confined("4", NULL, "write", SCRATCH "/made.txt");
    check(status == 0 && exists(SCRATCH "/made.txt"), "confine-write-root-allowed", "exit %d", status);
    status = confined("4", NULL, "write", WORKSPACE "/confine-made.txt");
    check(status == EACCES && !exists(WORKSPACE "/confine-made.txt"), "confine-write-elsewhere-denied",
        "exit %d", status);
    status = confined("4", NULL, "nnp", "-");
    check(status == 0, "confine-no-new-privs-set", "exit %d", status);

    status = confined("4", NULL, "tcp", port_a);
    check(status == EACCES, "confine-tcp-denied", "exit %d", status);
    status = confined("4", port_a, "tcp", port_a);
    check(status == 0, "confine-tcp-listed-port-allowed", "exit %d", status);
    status = confined("4", port_a, "tcp", port_b);
    check(status == EACCES, "confine-tcp-other-port-denied", "exit %d", status);

    status = confined("999", NULL, "write", SCRATCH "/floor-ran");
    check(status == ESTABLISH_FAILED && !exists(SCRATCH "/floor-ran"), "confine-floor-above-abi-refuses",
        "exit %d", status);
    status = confined("3", NULL, "write", SCRATCH "/low-floor-ran");
    check(status == ESTABLISH_FAILED && !exists(SCRATCH "/low-floor-ran"), "confine-floor-below-4-refuses",
        "exit %d", status);

    status = confined("4", NULL, "abstract", ABSTRACT_SOCKET);
    check(status == (abi >= 6 ? EPERM : 0), "confine-abstract-unix-by-abi", "abi %ld exit %d", abi, status);
    status = confined("4", NULL, "signal", "1");
    check(status == (abi >= 6 ? EPERM : 0), "confine-signal-by-abi", "abi %ld exit %d", abi, status);
    status = confined("4", NULL, "unix", UNIX_SOCKET);
    check(status == (abi >= 9 ? EACCES : 0), "confine-pathname-unix-by-abi", "abi %ld exit %d", abi, status);
    /* A shared directory is writable, but a socket in it is not the
     * server's to reach; one in its own directory is. */
    status = confined("4", NULL, "write", TEMP "/made.txt");
    check(status == 0 && exists(TEMP "/made.txt"), "confine-temp-root-writable", "exit %d", status);
    status = confined("4", NULL, "unix", TEMP_SOCKET);
    check(status == (abi >= 9 ? EACCES : 0), "confine-unix-in-temp-by-abi", "abi %ld exit %d", abi, status);
    status = confined("4", NULL, "unix", SCRATCH_SOCKET);
    check(status == 0, "confine-unix-in-write-root-allowed", "abi %ld exit %d", abi, status);
    /* ioctl on a device the server opens: granted nowhere, /dev included. */
    status = confined("4", NULL, "ioctl", "/dev/null");
    check(status == (abi >= 5 ? EACCES : 0), "confine-device-ioctl-by-abi", "abi %ld exit %d", abi, status);
    status = confined("4", NULL, "udp", "9");
    check(status == (abi >= 10 ? EACCES : 0), "confine-udp-by-abi", "abi %ld exit %d", abi, status);
}

static void console_fallback(void) {
    int fd = open("/dev/console", O_WRONLY);
    if (fd < 0 && mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1)) == 0) {
        fd = open("/dev/console", O_WRONLY);
    }
    if (fd >= 0 && fd != 1) {
        dup2(fd, 1);
        close(fd);
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
        int setup_errno = errno;
        if (fcntl(1, F_GETFD) < 0) {
            console_fallback();
        }
        say("rv-kernel-e2e: FAIL setup: errno %d\n", setup_errno);
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

    if (live >= 3) {
        argv_lock_cases();
        enforcement_cases();
    } else {
        refusal_cases();
    }
    if (live >= 4) {
        confine_cases(live);
    } else {
        confine_refusal_cases();
    }
    finish(live, uts.release);
    return 1;
}
