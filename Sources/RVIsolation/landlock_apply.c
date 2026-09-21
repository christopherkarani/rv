#include "rv_landlock_apply.h"

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <linux/landlock.h>
#include <stdint.h>
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

#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif

/*
 * Write-class FS bits only. Keep in sync with LandlockAccessFS.writeClass.
 * Do not handle READ_*, EXECUTE, or net. TRUNCATE is required (ABI 3).
 */
#define RV_LANDLOCK_WRITE_CLASS                                        \
    (LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR     \
        | LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR \
        | LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG     \
        | LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO   \
        | LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM   \
        | LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE)

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

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        return -1;
    }

    abi = rv_sys_landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 3) {
        return -1;
    }

    handled = RV_LANDLOCK_WRITE_CLASS;

    /*
     * Pass only handled_access_fs. Network stays unrestricted
     * (handled_access_net is not supplied).
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

    parent_fd = open(canonical, O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
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
