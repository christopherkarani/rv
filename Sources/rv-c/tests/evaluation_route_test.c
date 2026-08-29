#include "evaluation_route.h"

#include <stdio.h>
#include <string.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

int main(void) {
    if (rv_should_miss_replay("1.0.0", NULL) != 1) fail("nil", "want miss");
    if (rv_should_miss_replay("1.0.0", "") != 1) fail("empty", "want miss");
    if (rv_should_miss_replay("1.0.0", "not-a-version") != 1) fail("unparseable", "want miss");
    if (rv_should_miss_replay("", "1.0.0") != 1) fail("client empty", "want miss");
    if (rv_should_miss_replay("not-a-version", "1.0.0") != 1) fail("client unparseable", "want miss");
    if (rv_should_miss_replay("1.0.0", "1.9.9") != 0) fail("same major", "want trust");
    if (rv_should_miss_replay("1.0.0", "2.0.0") != 1) fail("major skew", "want miss");
    if (g_fails) return 1;
    return 0;
}
