#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "observe_gate.h"
#include "json_reply.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

/* Reads the whole regular file at fd (size already checked). */
static char *read_exact(int fd, size_t size) {
    size_t got = 0;
    char *buf = malloc(size + 1);
    if (buf == NULL) {
        return NULL;
    }
    while (got < size) {
        ssize_t n = read(fd, buf + got, size - got);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            free(buf);
            return NULL;
        }
        got += (size_t)n;
    }
    buf[size] = '\0';
    return buf;
}

int rv_observe_gate_applies(const char *config_path, const char *managed_dir, const char *host) {
    struct stat st;
    int fd;
    char *json;
    int observes;
    if (config_path == NULL || managed_dir == NULL || host == NULL) {
        return 0;
    }
    if (lstat(managed_dir, &st) == 0 || errno != ENOENT) {
        return 0;
    }
    fd = open(config_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        return 0;
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()
        || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0
        || st.st_size < 0 || st.st_size > RV_OBSERVE_CONFIG_MAX) {
        close(fd);
        return 0;
    }
    json = read_exact(fd, (size_t)st.st_size);
    close(fd);
    if (json == NULL) {
        return 0;
    }
    observes = rv_guard_config_observes(json, (size_t)st.st_size, host);
    free(json);
    return observes;
}
