#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "rvd_state.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_fails;
static const long long kNow = 1800000000LL;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

static void expect_parse(const char *name, const char *text, enum RvRvdState want) {
    enum RvRvdState got = rv_rvd_state_parse(text, strlen(text), kNow);
    if (got != want) {
        fprintf(stderr, "  text: \"%s\" got %d want %d\n", text, (int)got, (int)want);
        fail(name, "parse mismatch");
    }
}

static void expect_restarting(const char *name, long long deadline, enum RvRvdState want) {
    char text[64];
    snprintf(text, sizeof text, "restarting %lld\n", deadline);
    expect_parse(name, text, want);
}

static void test_parse(void) {
    expect_parse("armed", "armed\n", RV_RVD_STATE_ARMED);
    expect_restarting("restart_now", kNow, RV_RVD_STATE_RESTARTING);
    expect_restarting("restart_60", kNow + 60, RV_RVD_STATE_RESTARTING);
    expect_restarting("restart_window_edge", kNow + RV_RVD_STATE_RESTART_WINDOW_S, RV_RVD_STATE_RESTARTING);
    /* Expired: the announced restart never came back. */
    expect_restarting("restart_expired", kNow - 1, RV_RVD_STATE_RESTART_EXPIRED);
    /* Far future: a forged marker cannot buy a long window. */
    expect_restarting("restart_far_future", kNow + RV_RVD_STATE_RESTART_WINDOW_S + 1,
                      RV_RVD_STATE_RESTART_EXPIRED);
    expect_parse("restart_huge", "restarting 999999999999999999\n", RV_RVD_STATE_RESTART_EXPIRED);
    expect_parse("restart_overlong_digits", "restarting 9999999999999999999\n", RV_RVD_STATE_INVALID);
    expect_parse("empty", "", RV_RVD_STATE_INVALID);
    expect_parse("armed_no_newline", "armed", RV_RVD_STATE_INVALID);
    expect_parse("armed_crlf", "armed\r\n", RV_RVD_STATE_INVALID);
    expect_parse("armed_trailing", "armed\nx", RV_RVD_STATE_INVALID);
    expect_parse("armed_upper", "ARMED\n", RV_RVD_STATE_INVALID);
    expect_parse("restart_no_newline", "restarting 1800000060", RV_RVD_STATE_INVALID);
    expect_parse("restart_no_digits", "restarting \n", RV_RVD_STATE_INVALID);
    expect_parse("restart_negative", "restarting -1\n", RV_RVD_STATE_INVALID);
    expect_parse("restart_plus", "restarting +1800000060\n", RV_RVD_STATE_INVALID);
    expect_parse("restart_leading_zero", "restarting 01800000060\n", RV_RVD_STATE_INVALID);
    expect_parse("restart_two_spaces", "restarting  1800000060\n", RV_RVD_STATE_INVALID);
    expect_parse("restart_trailing_space", "restarting 1800000060 \n", RV_RVD_STATE_INVALID);
    expect_parse("restart_hex", "restarting 0x6b49d200\n", RV_RVD_STATE_INVALID);
    expect_parse("garbage", "allow\n", RV_RVD_STATE_INVALID);
    {
        /* Embedded NUL: length-delimited, never C-string parsed. */
        static const char nul[] = "armed\0\n";
        if (rv_rvd_state_parse(nul, sizeof nul - 1, kNow) != RV_RVD_STATE_INVALID) {
            fail("embedded_nul", "must be invalid");
        }
    }
    if (rv_rvd_state_parse(NULL, 0, kNow) != RV_RVD_STATE_INVALID) {
        fail("null_buf", "must be invalid");
    }
}

static void test_allows(void) {
    if (!rv_rvd_state_allows_observe(RV_RVD_STATE_ABSENT)
        || !rv_rvd_state_allows_observe(RV_RVD_STATE_RESTARTING)
        || rv_rvd_state_allows_observe(RV_RVD_STATE_ARMED)
        || rv_rvd_state_allows_observe(RV_RVD_STATE_RESTART_EXPIRED)
        || rv_rvd_state_allows_observe(RV_RVD_STATE_INVALID)
        || rv_rvd_state_allows_observe((enum RvRvdState)99)) {
        fail("allows_observe", "only absent and restarting may step aside");
    }
}

static void write_file(const char *path, const char *text, size_t len, mode_t mode) {
    int fd;
    unlink(path);
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0 || write(fd, text, len) != (ssize_t)len) {
        fail("fixture", path);
    }
    if (fd >= 0) {
        close(fd);
    }
    if (chmod(path, mode) != 0) {
        fail("fixture_chmod", path);
    }
}

static void expect_read(const char *name, const char *path, enum RvRvdState want) {
    enum RvRvdState got = rv_rvd_state_read(path, kNow);
    if (got != want) {
        fprintf(stderr, "  path: %s got %d want %d\n", path, (int)got, (int)want);
        fail(name, "read mismatch");
    }
}

static void test_read(void) {
    char dir[] = "/tmp/rv-rvd-state.XXXXXX";
    char path[256];
    char link[256];
    char sub[256];
    char big[RV_RVD_STATE_MAX + 2];
    if (mkdtemp(dir) == NULL) {
        fail("mkdtemp", dir);
        return;
    }
    snprintf(path, sizeof path, "%s/rvd-state", dir);
    snprintf(link, sizeof link, "%s/link", dir);
    snprintf(sub, sizeof sub, "%s/missing-dir/rvd-state", dir);

    expect_read("absent", path, RV_RVD_STATE_ABSENT);
    expect_read("absent_parent", sub, RV_RVD_STATE_ABSENT);
    if (rv_rvd_state_read(NULL, kNow) != RV_RVD_STATE_INVALID) {
        fail("null_path", "must be invalid");
    }

    write_file(path, "armed\n", 6, 0600);
    expect_read("armed_file", path, RV_RVD_STATE_ARMED);
    write_file(path, "armed\n", 6, 0644);
    expect_read("armed_0644", path, RV_RVD_STATE_ARMED);
    write_file(path, "restarting 1800000060\n", 22, 0600);
    expect_read("restarting_file", path, RV_RVD_STATE_RESTARTING);

    /* A planted restart is refused when anyone else could have written it. */
    write_file(path, "restarting 1800000060\n", 22, 0620);
    expect_read("group_writable", path, RV_RVD_STATE_INVALID);
    write_file(path, "restarting 1800000060\n", 22, 0602);
    expect_read("world_writable", path, RV_RVD_STATE_INVALID);

    /* A symlink to a valid restart marker is refused (O_NOFOLLOW). */
    write_file(path, "restarting 1800000060\n", 22, 0600);
    unlink(link);
    if (symlink(path, link) != 0) {
        fail("symlink_fixture", link);
    }
    expect_read("symlink", link, RV_RVD_STATE_INVALID);
    unlink(link);

    /* A dangling symlink is not absence. */
    if (symlink("/nonexistent/rv-rvd-state", link) != 0) {
        fail("dangling_fixture", link);
    }
    expect_read("dangling_symlink", link, RV_RVD_STATE_INVALID);
    unlink(link);

    /* Not a regular file. */
    if (mkdir(link, 0700) != 0) {
        fail("dir_fixture", link);
    }
    expect_read("directory", link, RV_RVD_STATE_INVALID);
    rmdir(link);
    if (mkfifo(link, 0600) != 0) {
        fail("fifo_fixture", link);
    }
    expect_read("fifo", link, RV_RVD_STATE_INVALID);
    unlink(link);

    /* Oversized. */
    memset(big, ' ', sizeof big);
    write_file(path, big, RV_RVD_STATE_MAX + 1, 0600);
    expect_read("oversized", path, RV_RVD_STATE_INVALID);
    write_file(path, "", 0, 0600);
    expect_read("empty_file", path, RV_RVD_STATE_INVALID);

    /* Unreadable (skipped as root, which reads through mode bits). */
    if (geteuid() != 0) {
        write_file(path, "restarting 1800000060\n", 22, 0200);
        expect_read("unreadable", path, RV_RVD_STATE_INVALID);
    }

    unlink(path);
    rmdir(dir);
}

int main(void) {
    test_parse();
    test_allows();
    test_read();
    if (g_fails != 0) {
        fprintf(stderr, "rvd_state tests: %d failure(s)\n", g_fails);
        return 1;
    }
    printf("rvd_state tests ok\n");
    return 0;
}
