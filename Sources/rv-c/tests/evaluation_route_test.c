#include "evaluation_route.h"

#include <stdio.h>
#include <string.h>

/* Vector-driven parity test. Vectors live in evaluation_route_vectors.tsv,
 * shared with Tests/RVIPCTests/EvaluationRouteTests.swift. Usage:
 *   evaluation_route_test <vectors.tsv>
 * run.sh passes the path; a missing file is a hard failure, not a skip.
 */

static int g_fails;

static void fail(int lineno, const char *detail) {
    fprintf(stderr, "FAIL vectors.tsv:%d: %s\n", lineno, detail);
    g_fails += 1;
}

/* Split *cursor at the next tab. Returns the field (NUL-terminated in place)
 * and advances *cursor past the tab, or NULL when no tab remains. */
static char *take_field(char **cursor) {
    char *field;
    char *tab;

    if (cursor == NULL || *cursor == NULL) {
        return NULL;
    }
    field = *cursor;
    tab = strchr(field, '\t');
    if (tab == NULL) {
        *cursor = NULL;
        return field;
    }
    *tab = '\0';
    *cursor = tab + 1;
    return field;
}

int main(int argc, char **argv) {
    FILE *vectors;
    char line[256];
    int lineno;
    int cases;

    if (argc != 2) {
        fprintf(stderr, "usage: evaluation_route_test <vectors.tsv>\n");
        return 1;
    }
    vectors = fopen(argv[1], "r");
    if (vectors == NULL) {
        fprintf(stderr, "FAIL: cannot open vectors file %s\n", argv[1]);
        return 1;
    }
    lineno = 0;
    cases = 0;
    while (fgets(line, sizeof line, vectors) != NULL) {
        char *cursor;
        char *client;
        char *service;
        char *expect;
        const char *service_arg;
        int want_miss;
        int got;
        size_t len;

        lineno += 1;
        /* Skip comments and blank lines. */
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\0') {
            continue;
        }
        /* Strip one trailing newline (and optional CR). Interior bytes,
         * including leading spaces, are significant and never trimmed. */
        len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
            len -= 1;
        }
        if (len > 0 && line[len - 1] == '\r') {
            line[len - 1] = '\0';
        }
        cursor = line;
        client = take_field(&cursor);
        service = take_field(&cursor);
        expect = cursor;
        if (client == NULL || service == NULL || expect == NULL || expect[0] == '\0') {
            fail(lineno, "malformed row (want client<TAB>service<TAB>expect)");
            continue;
        }
        if (strcmp(expect, "service") == 0) {
            want_miss = 0;
        } else if (strcmp(expect, "inProcess") == 0) {
            want_miss = 1;
        } else {
            fail(lineno, "expect must be service or inProcess");
            continue;
        }
        service_arg = strcmp(service, "NULL") == 0 ? NULL : service;
        got = rv_should_miss_replay(client, service_arg);
        if (got != want_miss) {
            char detail[128];
            snprintf(
                detail,
                sizeof detail,
                "client=\"%s\" service=\"%s\" want miss=%d got %d",
                client,
                service_arg == NULL ? "NULL" : service_arg,
                want_miss,
                got
            );
            fail(lineno, detail);
            continue;
        }
        cases += 1;
    }
    fclose(vectors);
    if (cases == 0) {
        fprintf(stderr, "FAIL: vectors file %s contributed zero cases\n", argv[1]);
        return 1;
    }
    if (g_fails) return 1;
    return 0;
}
