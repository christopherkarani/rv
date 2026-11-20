/* local_eval.c: output framing, and the spawn/verify/deadline contract.
 * argv: <final> <escalate> <hang> <crash> <garbage> <final-log> — fake
 * evaluators built by run.sh from fake_evaluator.c. */
#include "local_eval.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures;

static void fail(const char *name, const char *why) {
    fprintf(stderr, "local_eval_test: %s: %s\n", name, why);
    failures++;
}

static void expect_parse(const char *name, const char *out, int want, const char *want_body, const char *want_reason) {
    const char *body = NULL;
    size_t body_len = 0;
    char reason[32] = "";
    enum RvLocalVerdict v = rv_local_parse_output(out, strlen(out), &body, &body_len, reason, sizeof reason);
    if ((int)v != want) {
        fail(name, "verdict");
        return;
    }
    if (want == RV_LOCAL_FINAL) {
        if (body_len != strlen(want_body) || memcmp(body, want_body, body_len) != 0) {
            fail(name, "body");
        }
    } else if (strcmp(reason, want_reason) != 0) {
        fail(name, reason);
    }
}

static int accept_all(pid_t pid, const char *path) {
    (void)pid;
    (void)path;
    return 1;
}

static int reject_all(pid_t pid, const char *path) {
    (void)pid;
    (void)path;
    return 0;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Accepts, but only after the 100 ms deadline the slow-verify case sets. */
static int accept_slowly(pid_t pid, const char *path) {
    (void)pid;
    (void)path;
    usleep(150 * 1000);
    return 1;
}

static const char *ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
static const unsigned char INPUT[] = "{\"tool_name\":\"Bash\"}";

static enum RvLocalVerdict run(const char *path, long deadline, RvLocalVerify verify, char *reason, char **json) {
    size_t len = 0;
    *json = NULL;
    return rv_local_evaluate(path, "claude", ID, "/var/empty", "nobody",
        INPUT, sizeof INPUT - 1, deadline, verify, json, &len, reason, 32);
}

int main(int argc, char **argv) {
    char reason[32];
    char *json = NULL;
    long long started;

    if (argc != 7) {
        fprintf(stderr, "usage: local_eval_test final escalate hang crash garbage final-log\n");
        return 2;
    }

    expect_parse("final", "rv-hook-local/1 final\n{\"id\":1}", RV_LOCAL_FINAL, "{\"id\":1}", NULL);
    expect_parse("final-empty-body", "rv-hook-local/1 final\n", RV_LOCAL_ESCALATE, NULL, "protocol");
    expect_parse("escalate", "rv-hook-local/1 escalate policy-gate\n", RV_LOCAL_ESCALATE, NULL, "policy-gate");
    expect_parse("escalate-no-newline", "rv-hook-local/1 escalate judge", RV_LOCAL_ESCALATE, NULL, "protocol");
    expect_parse("escalate-bad-reason", "rv-hook-local/1 escalate J\n", RV_LOCAL_ESCALATE, NULL, "protocol");
    expect_parse("other-version", "rv-hook-local/2 final\n{}", RV_LOCAL_ESCALATE, NULL, "protocol");
    expect_parse("garbage", "allow\n", RV_LOCAL_ESCALATE, NULL, "protocol");
    expect_parse("empty", "", RV_LOCAL_ESCALATE, NULL, "protocol");

    unlink(argv[6]);
    if (run(argv[1], 1000, reject_all, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "untrusted") != 0) {
        fail("untrusted", reason);
    }
    if (access(argv[6], F_OK) == 0) {
        fail("untrusted", "a rejected evaluator must not receive the call");
    }
    free(json);

    unlink(argv[6]);
    if (run(argv[1], 100, accept_slowly, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "timeout") != 0) {
        fail("slow-verify", reason);
    }
    if (access(argv[6], F_OK) == 0) {
        fail("slow-verify", "an evaluator verified past the deadline must not receive the call");
    }
    free(json);

    if (run(argv[1], 1000, accept_all, reason, &json) != RV_LOCAL_FINAL || json == NULL
        || strstr(json, ID) == NULL || strncmp(json, "{\"id\"", 5) != 0) {
        fail("final", reason);
    }
    free(json);

    if (run(argv[2], 1000, accept_all, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "judge") != 0) {
        fail("escalate", reason);
    }
    free(json);

    started = now_ms();
    if (run(argv[3], 300, accept_all, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "timeout") != 0) {
        fail("hang", reason);
    }
    if (now_ms() - started > 900) {
        fail("hang", "deadline not enforced");
    }
    free(json);

    if (run(argv[4], 1000, accept_all, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "exit") != 0) {
        fail("crash", reason);
    }
    free(json);

    if (run(argv[5], 1000, accept_all, reason, &json) != RV_LOCAL_ESCALATE || strcmp(reason, "protocol") != 0) {
        fail("garbage", reason);
    }
    free(json);

    if (run("/nonexistent/rv-hook-local", 1000, accept_all, reason, &json) != RV_LOCAL_ESCALATE) {
        fail("missing", reason);
    }
    free(json);

    if (failures != 0) {
        return 1;
    }
    printf("local_eval_test: ok\n");
    return 0;
}
