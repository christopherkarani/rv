#include "rv_landlock_apply.h"

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <stdint.h>
/*
 * Header-independent fallbacks: pre-Landlock libc headers must degrade to
 * the runtime ABI probe failing closed (the trampoline exits 125), not to
 * a build failure. Values are the stable kernel UAPI assignments; the
 * ruleset attr is passed at sizeof(handled_access_fs), which every ABI
 * accepts, so the one-field fallback struct is layout-sufficient.
 */
#if defined(__has_include) && __has_include(<linux/landlock.h>)
#include <linux/landlock.h>
#else
struct landlock_ruleset_attr {
    uint64_t handled_access_fs;
};
struct landlock_path_beneath_attr {
    uint64_t allowed_access;
    int32_t parent_fd;
} __attribute__((packed));
#define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
#define LANDLOCK_RULE_PATH_BENEATH 1
#define LANDLOCK_ACCESS_FS_EXECUTE (1ULL << 0)
#define LANDLOCK_ACCESS_FS_WRITE_FILE (1ULL << 1)
#define LANDLOCK_ACCESS_FS_READ_FILE (1ULL << 2)
#define LANDLOCK_ACCESS_FS_READ_DIR (1ULL << 3)
#define LANDLOCK_ACCESS_FS_REMOVE_DIR (1ULL << 4)
#define LANDLOCK_ACCESS_FS_REMOVE_FILE (1ULL << 5)
#define LANDLOCK_ACCESS_FS_MAKE_CHAR (1ULL << 6)
#define LANDLOCK_ACCESS_FS_MAKE_DIR (1ULL << 7)
#define LANDLOCK_ACCESS_FS_MAKE_REG (1ULL << 8)
#define LANDLOCK_ACCESS_FS_MAKE_SOCK (1ULL << 9)
#define LANDLOCK_ACCESS_FS_MAKE_FIFO (1ULL << 10)
#define LANDLOCK_ACCESS_FS_MAKE_BLOCK (1ULL << 11)
#define LANDLOCK_ACCESS_FS_MAKE_SYM (1ULL << 12)
#endif
#if defined(__has_include) && __has_include(<linux/openat2.h>)
#include <linux/openat2.h>
#else
struct open_how {
    uint64_t flags;
    uint64_t mode;
    uint64_t resolve;
};
#define RESOLVE_NO_MAGICLINKS 0x02
#define RESOLVE_NO_SYMLINKS 0x04
#endif
#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#define SYS_landlock_add_rule 445
#define SYS_landlock_restrict_self 446
#endif

#ifndef O_PATH
#define O_PATH 010000000
#endif

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0400000
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifndef LANDLOCK_ACCESS_FS_REFER
#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif

#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif

/*
 * Handled FS bits. Keep in sync with LandlockAccessFS.writeClass,
 * LandlockAccessFS.readClass, and LandlockAccessFS.handledFS.
 * Do not handle EXECUTE or net. TRUNCATE is required (ABI 3).
 * Phase 6 grants read+write beneath the workspace. The system
 * read-only layer an inner program needs (/usr, /lib, loader) is
 * not granted here, and no network/process controls are installed,
 * so Swift still refuses contained before exec.
 */
#define RV_LANDLOCK_WRITE_CLASS                                        \
    (LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR     \
        | LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR \
        | LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG     \
        | LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO   \
        | LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM   \
        | LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE)

#define RV_LANDLOCK_READ_CLASS \
    (LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)

#define RV_LANDLOCK_HANDLED_FS (RV_LANDLOCK_WRITE_CLASS | RV_LANDLOCK_READ_CLASS)

static int rv_sys_landlock_create_ruleset(
    const struct landlock_ruleset_attr *attr,
    size_t size,
    uint32_t flags
) {
    return (int)syscall(SYS_landlock_create_ruleset, attr, size, flags);
}

static int rv_sys_landlock_add_rule(
    int ruleset_fd,
    int rule_type,
    const void *rule_attr,
    uint32_t flags
) {
    return (int)syscall(SYS_landlock_add_rule, ruleset_fd, rule_type, rule_attr, flags);
}

static int rv_sys_landlock_restrict_self(int ruleset_fd, uint32_t flags) {
    return (int)syscall(SYS_landlock_restrict_self, ruleset_fd, flags);
}

int rv_landlock_restrict_self_to_workspace(const char *workspace) {
    int abi;
    uint64_t handled;
    struct landlock_ruleset_attr attr;
    int ruleset_fd;
    int parent_fd;
    struct open_how workspace_open;
    struct landlock_path_beneath_attr beneath;
    int restrict_status;
    char canonical[PATH_MAX];

    if (workspace == NULL || workspace[0] != '/') {
        return -1;
    }
    if (realpath(workspace, canonical) == NULL) {
        return -1;
    }
    if (canonical[0] != '/' || canonical[1] == '\0') {
        return -1;
    }
    /* Swift supplies the canonical grant path. Never silently reinterpret it
     * as a different directory after a symlink was changed before launch. */
    if (strcmp(workspace, canonical) != 0) {
        return -1;
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        return -1;
    }

    abi = rv_sys_landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 3) {
        return -1;
    }

    handled = RV_LANDLOCK_HANDLED_FS;

    /*
     * Pass only handled_access_fs. Network stays unrestricted
     * (handled_access_net is not supplied): the target host-proxy
     * egress model needs net rules (ABI 4+) or a net namespace,
     * neither of which is installed here.
     */
    memset(&attr, 0, sizeof(attr));
    attr.handled_access_fs = handled;
    ruleset_fd = rv_sys_landlock_create_ruleset(
        &attr,
        sizeof(attr.handled_access_fs),
        0
    );
    if (ruleset_fd < 0) {
        return -1;
    }

    /* Resolve every component without symlinks atomically. O_NOFOLLOW alone
     * covers only the final component, leaving ancestor replacement races.
     * ABI >= 3 kernels support openat2; denied setup remains fail-closed. */
    memset(&workspace_open, 0, sizeof(workspace_open));
    workspace_open.flags = O_PATH | O_DIRECTORY | O_CLOEXEC;
    workspace_open.resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
    parent_fd = (int)syscall(
        SYS_openat2, AT_FDCWD, canonical, &workspace_open, sizeof(workspace_open)
    );
    if (parent_fd < 0) {
        close(ruleset_fd);
        return -1;
    }

    memset(&beneath, 0, sizeof(beneath));
    beneath.allowed_access = handled;
    beneath.parent_fd = parent_fd;
    if (rv_sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0) {
        close(parent_fd);
        close(ruleset_fd);
        return -1;
    }

    close(parent_fd);
    restrict_status = rv_sys_landlock_restrict_self(ruleset_fd, 0);
    close(ruleset_fd);
    if (restrict_status != 0) {
        return -1;
    }
    return 0;
}

#else

int rv_landlock_restrict_self_to_workspace(const char *workspace) {
    (void)workspace;
    return -1;
}

#endif
