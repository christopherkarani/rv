#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "json_reply.h"
#include "observe_gate.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

static void expect_config(const char *name, const char *json, const char *host, int want) {
    int got = rv_guard_config_observes(json, strlen(json), host);
    if (got != want) {
        fprintf(stderr, "  json: %s host: %s got %d want %d\n", json, host, got, want);
        fail(name, "observe mismatch");
    }
}

/* Same resolution as JudgeRuntime.guardMode minus RV_GUARD_MODE:
 * guard.hosts.<host> > guard.mode (nested) > "guard.mode" (flat) > enforce. */
static void test_resolution(void) {
    expect_config("nested_observe", "{\"guard\":{\"mode\":\"observe\"}}", "claude", 1);
    expect_config("nested_observe_case", "{\"guard\":{\"mode\":\"OBSERVE\"}}", "claude", 1);
    expect_config("nested_enforce", "{\"guard\":{\"mode\":\"enforce\"}}", "claude", 0);
    expect_config("flat_observe", "{\"guard.mode\":\"observe\"}", "codex", 1);
    expect_config("nested_wins_over_flat",
                  "{\"guard\":{\"mode\":\"enforce\"},\"guard.mode\":\"observe\"}", "claude", 0);
    /* An unknown nested value is enforce; it does not fall through to flat. */
    expect_config("nested_unknown_is_enforce",
                  "{\"guard\":{\"mode\":\"bogus\"},\"guard.mode\":\"observe\"}", "claude", 0);
    expect_config("nested_empty_falls_to_flat",
                  "{\"guard\":{\"mode\":\"\"},\"guard.mode\":\"observe\"}", "claude", 1);
    expect_config("host_block_beats_global",
                  "{\"guard\":{\"mode\":\"observe\",\"hosts\":{\"claude\":\"block\"}}}", "claude", 0);
    expect_config("other_host_follows_global",
                  "{\"guard\":{\"mode\":\"observe\",\"hosts\":{\"claude\":\"block\"}}}", "cursor", 1);
    expect_config("host_observe_over_enforce",
                  "{\"guard\":{\"hosts\":{\"claude\":\"observe\"}}}", "claude", 1);
    /* A stale hook on an `off` host must never block. */
    expect_config("host_off", "{\"guard\":{\"hosts\":{\"claude\":\"OFF\"}}}", "claude", 1);
    expect_config("host_unknown_falls_through",
                  "{\"guard\":{\"mode\":\"observe\",\"hosts\":{\"claude\":\"bogus\"}}}", "claude", 1);
    expect_config("host_key_case_sensitive",
                  "{\"guard\":{\"hosts\":{\"Claude\":\"observe\"}}}", "claude", 0);
    expect_config("guard_not_object_uses_flat",
                  "{\"guard\":\"observe\",\"guard.mode\":\"observe\"}", "claude", 1);
    expect_config("non_string_mode", "{\"guard\":{\"mode\":1}}", "claude", 0);
    expect_config("escaped_value", "{\"guard\":{\"mode\":\"obs\\u0065rve\"}}", "claude", 1);
    expect_config("other_keys_skipped",
                  "{\"analytics\":{\"enabled\":false},\"list\":[1,2.5e3,{\"a\":null}],"
                  "\"guard\":{\"x\":true,\"mode\":\"observe\"}}", "claude", 1);
    expect_config("no_config_keys", "{}", "claude", 0);
}

/* Anything rvd would not read as observe, or that is ambiguous, is enforce. */
static void test_fail_closed(void) {
    const char nul_value[] = "{\"guard\":{\"mode\":\"observe\\u0000\"}}";
    expect_config("truncated", "{\"guard\":{\"mode\":\"observe\"}", "claude", 0);
    expect_config("trailing_garbage", "{\"guard\":{\"mode\":\"observe\"}} x", "claude", 0);
    expect_config("array_root", "[{\"guard\":{\"mode\":\"observe\"}}]", "claude", 0);
    expect_config("empty", "", "claude", 0);
    expect_config("dup_mode",
                  "{\"guard\":{\"mode\":\"observe\",\"mode\":\"enforce\"}}", "claude", 0);
    expect_config("dup_guard",
                  "{\"guard\":{\"mode\":\"enforce\"},\"guard\":{\"mode\":\"observe\"}}", "claude", 0);
    expect_config("dup_flat", "{\"guard.mode\":\"enforce\",\"guard.mode\":\"observe\"}", "claude", 0);
    expect_config("dup_host",
                  "{\"guard\":{\"hosts\":{\"claude\":\"block\",\"claude\":\"observe\"}}}", "claude", 0);
    expect_config("nul_in_value", nul_value, "claude", 0);
    /* Swift lowercases Unicode (KELVIN SIGN -> k), so "BLOC\u212A" is block
     * to rvd; any non-ASCII value byte is enforce here, never a fall-through. */
    expect_config("non_ascii_host_value",
                  "{\"guard\":{\"mode\":\"observe\",\"hosts\":{\"claude\":\"BLOC\\u212A\"}}}", "claude", 0);
    expect_config("non_ascii_mode_value", "{\"guard\":{\"mode\":\"obs\xc3\xa9rve\"}}", "claude", 0);
    if (rv_guard_config_observes(NULL, 0, "claude") != 0) fail("null_json", "observe");
    {
        const char flat[] = "{\"guard.mode\":\"observe\"}";
        if (rv_guard_config_observes(flat, strlen(flat), NULL) != 0) fail("null_host", "observe");
    }
}

static char g_dir[256];

static void path_in(char *out, size_t cap, const char *leaf) {
    snprintf(out, cap, "%s/%s", g_dir, leaf);
}

static void write_file(const char *path, const char *body, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0 || write(fd, body, strlen(body)) != (ssize_t)strlen(body)) {
        fail("fixture", path);
    }
    if (fd >= 0) {
        close(fd);
    }
    chmod(path, mode);
}

static void expect_gate(const char *name, const char *config, const char *managed, int want) {
    int got = rv_observe_gate_applies(config, managed, "claude");
    if (got != want) {
        fprintf(stderr, "  got %d want %d\n", got, want);
        fail(name, "gate mismatch");
    }
}

static void test_gate_io(void) {
    char config[512];
    char managed[512];
    char link[512];
    char big[512];
    char *body;
    size_t n;
    FILE *f;

    snprintf(g_dir, sizeof g_dir, "%s/rv-observe-gate-XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (mkdtemp(g_dir) == NULL) {
        fail("mkdtemp", "failed");
        return;
    }
    path_in(config, sizeof config, "config.json");
    path_in(managed, sizeof managed, "managed");
    path_in(link, sizeof link, "link.json");
    path_in(big, sizeof big, "big.json");

    expect_gate("missing_config", config, managed, 0);

    write_file(config, "{\"guard\":{\"mode\":\"observe\"}}", 0600);
    expect_gate("observe_config", config, managed, 1);

    write_file(config, "{\"guard\":{\"mode\":\"observe\"}}", 0644);
    expect_gate("observe_config_0644", config, managed, 1);

    /* Another account could flip a group- or world-writable file. */
    write_file(config, "{\"guard\":{\"mode\":\"observe\"}}", 0666);
    expect_gate("writable_by_others", config, managed, 0);
    write_file(config, "{\"guard\":{\"mode\":\"observe\"}}", 0620);
    expect_gate("writable_by_group", config, managed, 0);
    chmod(config, 0600);

    write_file(config, "{\"guard\":{\"mode\":\"enforce\"}}", 0600);
    expect_gate("enforce_config", config, managed, 0);
    write_file(config, "{\"guard\":{\"mode\":\"observe\"}}", 0600);

    /* An organization bundle (present, valid or not) pins enforce. */
    if (mkdir(managed, 0755) != 0) {
        fail("fixture", "mkdir managed");
    }
    expect_gate("managed_present", config, managed, 0);
    rmdir(managed);
    write_file(managed, "x", 0600);
    expect_gate("managed_file_present", config, managed, 0);
    unlink(managed);
    if (symlink("/nonexistent-rv-managed", managed) != 0) {
        fail("fixture", "symlink managed");
    }
    expect_gate("managed_dangling_symlink", config, managed, 0);
    unlink(managed);
    expect_gate("managed_gone_again", config, managed, 1);

    if (symlink(config, link) != 0) {
        fail("fixture", "symlink config");
    }
    expect_gate("config_symlink", link, managed, 0);
    unlink(link);

    expect_gate("config_is_directory", g_dir, managed, 0);

    n = (size_t)RV_OBSERVE_CONFIG_MAX + 1;
    body = malloc(n + 1);
    if (body != NULL) {
        const char *prefix = "{\"guard\":{\"mode\":\"observe\"}}";
        memset(body, ' ', n);
        memcpy(body, prefix, strlen(prefix));
        body[n] = '\0';
        f = fopen(big, "w");
        if (f != NULL) {
            fwrite(body, 1, n, f);
            fclose(f);
        }
        chmod(big, 0600);
        free(body);
        expect_gate("oversized_config", big, managed, 0);
        unlink(big);
    }

    if (rv_observe_gate_applies(NULL, managed, "claude") != 0) fail("null_config", "observe");
    if (rv_observe_gate_applies(config, NULL, "claude") != 0) fail("null_managed", "observe");
    if (rv_observe_gate_applies(config, managed, NULL) != 0) fail("null_host_gate", "observe");

    unlink(config);
    rmdir(g_dir);
}

int main(void) {
    test_resolution();
    test_fail_closed();
    test_gate_io();
    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("observe_gate tests ok\n");
    return 0;
}
