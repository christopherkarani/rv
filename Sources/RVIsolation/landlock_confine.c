/*
 * Landlock confinement for an MCP server (docs/security/mcp-linux-sandbox.md).
 * Compiled only into rv-isolation-exec, which includes this file after
 * landlock_apply.c and shares its syscall wrappers.
 *
 *   rv-isolation-exec --confine FLOOR [--read PATH]... [--write PATH]...
 *                     [--tcp PORT]... -- EXECUTABLE ARGV0 [ARG...]
 *
 * In this process, before exec: NO_NEW_PRIVS, then one ruleset that
 * handles every access right the running kernel's Landlock knows, so that
 * nothing it can restrict is left open:
 *
 *   files     nothing is readable but each --read path (read, list,
 *             execute) and nothing is writable but each --write path
 *             (everything, beneath it)
 *   TCP       no bind, and connect only to each --tcp port (ABI 4)
 *   devices   ioctl only beneath a --write path (ABI 5)
 *   scopes    no abstract Unix socket and no signal outside this domain
 *             (ABI 6)
 *   sockets   no connect to a pathname Unix socket outside a --write path
 *             (ABI 9)
 *   UDP       no bind and no send (ABI 10)
 *
 * The ABI is asked of the kernel (LANDLOCK_CREATE_RULESET_VERSION), never
 * inferred from its version. FLOOR is the lowest ABI the caller accepts:
 * below it, or below 4, nothing is applied and nothing runs. Any failure
 * exits 125 with one line on stderr and does not exec. A --read path that
 * is gone, or has become a symlink, since the caller listed it is skipped:
 * that only withholds access.
 */
#ifdef __linux__

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>

#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif
#ifndef LANDLOCK_ACCESS_FS_RESOLVE_UNIX
#define LANDLOCK_ACCESS_FS_RESOLVE_UNIX (1ULL << 16)
#endif
#ifndef LANDLOCK_ACCESS_NET_BIND_TCP
#define LANDLOCK_ACCESS_NET_BIND_TCP (1ULL << 0)
#define LANDLOCK_ACCESS_NET_CONNECT_TCP (1ULL << 1)
#endif
#ifndef LANDLOCK_ACCESS_NET_BIND_UDP
#define LANDLOCK_ACCESS_NET_BIND_UDP (1ULL << 2)
#define LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP (1ULL << 3)
#endif
#ifndef LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET
#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif
#ifndef LANDLOCK_RULE_NET_PORT
#define LANDLOCK_RULE_NET_PORT 2
#endif

#define RV_CONFINE_MINIMUM_ABI 4

/* The first three fields of struct landlock_ruleset_attr, by value: the
 * build host's header may be older than the kernel this runs on. */
struct rv_ruleset_attr {
    uint64_t handled_access_fs;
    uint64_t handled_access_net;
    uint64_t scoped;
};

struct rv_net_port_attr {
    uint64_t allowed_access;
    uint64_t port;
};

/* Rights a rule on a file (not a directory) may carry. */
#define RV_FS_FILE_RIGHTS                                          \
    (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE     \
        | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_TRUNCATE \
        | LANDLOCK_ACCESS_FS_IOCTL_DEV)

#define RV_FS_READ_RIGHTS \
    (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)

static int rv_confine_fail(const char *what, const char *detail) {
    dprintf(STDERR_FILENO, "rv mcp: the server was not started: %s%s%s\n", what,
        detail != NULL ? ": " : "", detail != NULL ? detail : "");
    return -1;
}

/* Decimal digits only, at most `limit`. */
static int rv_confine_number(const char *text, unsigned long limit, unsigned long *value) {
    unsigned long parsed = 0;
    const char *digit = text;
    if (*digit == '\0') {
        return -1;
    }
    for (; *digit != '\0'; digit++) {
        if (*digit < '0' || *digit > '9') {
            return -1;
        }
        parsed = parsed * 10 + (unsigned long)(*digit - '0');
        if (parsed > limit) {
            return -1;
        }
    }
    *value = parsed;
    return 0;
}

static uint64_t rv_confine_handled_fs(int abi) {
    uint64_t handled = RV_LANDLOCK_HANDLED_FS | LANDLOCK_ACCESS_FS_EXECUTE;
    if (abi >= 5) {
        handled |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
    }
    if (abi >= 9) {
        handled |= LANDLOCK_ACCESS_FS_RESOLVE_UNIX;
    }
    return handled;
}

static uint64_t rv_confine_handled_net(int abi) {
    uint64_t handled = LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP;
    if (abi >= 10) {
        handled |= LANDLOCK_ACCESS_NET_BIND_UDP | LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP;
    }
    return handled;
}

/* 0: rule added. 1: path skipped (allowed only for a --read path).
 * -1: failed. Every component is resolved without following a symlink. */
static int rv_confine_allow_path(int ruleset_fd, const char *path, uint64_t access, int may_skip) {
    struct open_how how;
    struct landlock_path_beneath_attr beneath;
    struct stat info;
    int fd;

    if (path[0] != '/') {
        return rv_confine_fail("a confined path is not absolute", path);
    }
    memset(&how, 0, sizeof(how));
    how.flags = O_PATH | O_CLOEXEC;
    how.resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
    fd = (int)syscall(SYS_openat2, AT_FDCWD, path, &how, sizeof(how));
    if (fd < 0) {
        if (may_skip && (errno == ENOENT || errno == ELOOP || errno == ENOTDIR)) {
            return 1;
        }
        return rv_confine_fail(strerror(errno), path);
    }
    if (fstat(fd, &info) != 0) {
        close(fd);
        return rv_confine_fail(strerror(errno), path);
    }
    if (!S_ISDIR(info.st_mode)) {
        access &= RV_FS_FILE_RIGHTS;
    }
    memset(&beneath, 0, sizeof(beneath));
    beneath.allowed_access = access;
    beneath.parent_fd = fd;
    if (rv_sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0) {
        close(fd);
        return rv_confine_fail(strerror(errno), path);
    }
    close(fd);
    return 0;
}

/* Returns the index of EXECUTABLE in argv, or -1 after printing why not.
 * argv[1] is "--confine". */
int rv_landlock_confine(int argc, char **argv) {
    struct rv_ruleset_attr attr;
    struct rv_net_port_attr port_attr;
    unsigned long floor;
    unsigned long port;
    uint64_t handled_fs;
    int ruleset_fd;
    int restricted;
    int abi;
    int index;

    if (argc < 3 || rv_confine_number(argv[2], 1000, &floor) != 0 || floor < RV_CONFINE_MINIMUM_ABI) {
        rv_confine_fail("the confinement request is malformed", NULL);
        return -1;
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        rv_confine_fail("NO_NEW_PRIVS could not be set", strerror(errno));
        return -1;
    }
    abi = rv_sys_landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) {
        rv_confine_fail("this kernel has no Landlock", strerror(errno));
        return -1;
    }
    if ((unsigned long)abi < floor) {
        dprintf(STDERR_FILENO,
            "rv mcp: the server was not started: this kernel's Landlock is ABI %d and its sandbox needs ABI %lu\n", abi,
            floor);
        return -1;
    }

    handled_fs = rv_confine_handled_fs(abi);
    memset(&attr, 0, sizeof(attr));
    attr.handled_access_fs = handled_fs;
    attr.handled_access_net = rv_confine_handled_net(abi);
    if (abi >= 6) {
        attr.scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET | LANDLOCK_SCOPE_SIGNAL;
    }
    /* A kernel before ABI 6 rejects a size that includes `scoped`. */
    ruleset_fd = rv_sys_landlock_create_ruleset(
        (const struct landlock_ruleset_attr *)&attr,
        abi >= 6 ? sizeof(attr) : sizeof(attr) - sizeof(attr.scoped), 0);
    if (ruleset_fd < 0) {
        rv_confine_fail("the Landlock ruleset could not be created", strerror(errno));
        return -1;
    }

    for (index = 3; index < argc; index += 2) {
        if (strcmp(argv[index], "--") == 0) {
            break;
        }
        if (index + 1 >= argc) {
            close(ruleset_fd);
            rv_confine_fail("the confinement request is malformed", NULL);
            return -1;
        }
        if (strcmp(argv[index], "--read") == 0) {
            if (rv_confine_allow_path(ruleset_fd, argv[index + 1], RV_FS_READ_RIGHTS, 1) < 0) {
                close(ruleset_fd);
                return -1;
            }
        } else if (strcmp(argv[index], "--write") == 0) {
            if (rv_confine_allow_path(ruleset_fd, argv[index + 1], handled_fs, 0) != 0) {
                close(ruleset_fd);
                return -1;
            }
        } else if (strcmp(argv[index], "--tcp") == 0) {
            if (rv_confine_number(argv[index + 1], 65535, &port) != 0 || port == 0) {
                close(ruleset_fd);
                rv_confine_fail("a confined port is not a TCP port", argv[index + 1]);
                return -1;
            }
            memset(&port_attr, 0, sizeof(port_attr));
            port_attr.allowed_access = LANDLOCK_ACCESS_NET_CONNECT_TCP;
            port_attr.port = port;
            if (rv_sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_NET_PORT, &port_attr, 0) != 0) {
                close(ruleset_fd);
                rv_confine_fail("a port rule could not be added", strerror(errno));
                return -1;
            }
        } else {
            close(ruleset_fd);
            rv_confine_fail("the confinement request is malformed", argv[index]);
            return -1;
        }
    }
    /* "--", an absolute executable, and its argv[0]. */
    if (index + 2 >= argc || argv[index + 1][0] != '/') {
        close(ruleset_fd);
        rv_confine_fail("the confinement request is malformed", NULL);
        return -1;
    }

    restricted = rv_sys_landlock_restrict_self(ruleset_fd, 0);
    close(ruleset_fd);
    if (restricted != 0) {
        rv_confine_fail("the Landlock ruleset could not be enforced", strerror(errno));
        return -1;
    }
    return index + 1;
}

/* The running kernel's Landlock ABI; 0 when it has none. */
int rv_landlock_abi(void) {
    int abi = rv_sys_landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    return abi < 0 ? 0 : abi;
}

#else

int rv_landlock_confine(int argc, char **argv) {
    (void)argc;
    (void)argv;
    return -1;
}

int rv_landlock_abi(void) {
    return 0;
}

#endif
