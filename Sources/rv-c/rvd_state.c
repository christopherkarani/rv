#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "rvd_state.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

static const char kArmed[] = "armed\n";
static const char kRestartingPrefix[] = "restarting ";

enum RvRvdState rv_rvd_state_parse(const char *buf, size_t len, long long now) {
    size_t prefix = sizeof kRestartingPrefix - 1;
    size_t i;
    long long deadline = 0;
    if (buf == NULL) {
        return RV_RVD_STATE_INVALID;
    }
    if (len == sizeof kArmed - 1 && memcmp(buf, kArmed, len) == 0) {
        return RV_RVD_STATE_ARMED;
    }
    /* "restarting " + 1..18 digits + "\n": no sign, no leading zero, no
     * other whitespace. 18 digits cannot overflow a long long. */
    if (len < prefix + 2 || len > prefix + 19 || memcmp(buf, kRestartingPrefix, prefix) != 0
        || buf[len - 1] != '\n' || buf[prefix] == '0') {
        return RV_RVD_STATE_INVALID;
    }
    for (i = prefix; i < len - 1; i++) {
        if (buf[i] < '0' || buf[i] > '9') {
            return RV_RVD_STATE_INVALID;
        }
        deadline = deadline * 10 + (buf[i] - '0');
    }
    if (deadline < now || deadline > now + RV_RVD_STATE_RESTART_WINDOW_S) {
        return RV_RVD_STATE_RESTART_EXPIRED;
    }
    return RV_RVD_STATE_RESTARTING;
}

enum RvRvdState rv_rvd_state_read(const char *path, long long now) {
    struct stat st;
    char buf[RV_RVD_STATE_MAX + 1];
    size_t got = 0;
    int fd;
    if (path == NULL) {
        return RV_RVD_STATE_INVALID;
    }
    fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        return errno == ENOENT ? RV_RVD_STATE_ABSENT : RV_RVD_STATE_INVALID;
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()
        || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0
        || st.st_size < 0 || st.st_size > RV_RVD_STATE_MAX) {
        close(fd);
        return RV_RVD_STATE_INVALID;
    }
    /* Read to EOF (one byte past the cap) so a file that grew after fstat
     * is refused rather than parsed from a prefix. */
    for (;;) {
        ssize_t n = read(fd, buf + got, sizeof buf - got);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0) {
            close(fd);
            return RV_RVD_STATE_INVALID;
        }
        if (n == 0) {
            break;
        }
        got += (size_t)n;
        if (got > RV_RVD_STATE_MAX) {
            close(fd);
            return RV_RVD_STATE_INVALID;
        }
    }
    close(fd);
    return rv_rvd_state_parse(buf, got, now);
}

int rv_rvd_state_allows_observe(enum RvRvdState state) {
    return state == RV_RVD_STATE_ABSENT || state == RV_RVD_STATE_RESTARTING;
}
