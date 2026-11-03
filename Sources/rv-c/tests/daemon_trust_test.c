/* Darwin-only: the trust manifest is a macOS artifact. Includes the
 * implementation so the static manifest parser is tested without
 * widening daemon_trust.h; file-level checks (root ownership, mode,
 * ACLs, protected_path) stay on the manifest_load path. */
#include "../daemon_trust.c"

#include <stdio.h>
#include <string.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

#define REQ(id) "anchor apple generic and identifier \\\"" id "\\\" and certificate leaf[subject.OU] = \\\"ABCDE12345\\\""
#define ENTRY(role, id) \
    "{\"role\":\"" role "\",\"requirement\":\"" REQ(id) "\"," \
    "\"requiredIdentifier\":\"" id "\",\"requiredTeamIdentifier\":\"ABCDE12345\"}"

static void reset(void) {
    if (g_has_service) {
        entry_free(&g_service);
        g_has_service = 0;
    }
}

static int parse(const char *json) {
    reset();
    return manifest_parse((const unsigned char *)json, strlen(json));
}

static void expect_valid(const char *name, const char *json, int want_service) {
    if (!parse(json)) {
        fail(name, "expected valid manifest");
        return;
    }
    if (g_has_service != want_service) {
        fail(name, "service presence mismatch");
    }
    if (want_service && strcmp(g_service.required_identifier, "dev.rv.rvd") != 0) {
        fail(name, "wrong service entry kept");
    }
}

static void expect_invalid(const char *name, const char *json) {
    if (parse(json)) {
        fail(name, "expected invalid manifest");
    }
    if (g_has_service) {
        fail(name, "invalid manifest kept a service entry");
    }
}

int main(void) {
    /* Baseline: known roles only. */
    expect_valid("service_only", "[" ENTRY("service", "dev.rv.rvd") "]", 1);
    expect_valid("empty", "[]", 0);

    /* Forward compatibility: a role from a newer build is skipped, not
     * fatal, so an older client keeps verifying the service. */
    expect_valid("unknown_role_skipped",
                 "[" ENTRY("service", "dev.rv.rvd") "," ENTRY("futureRoleFromNewerBuild", "dev.rv.mcp") "]", 1);
    expect_valid("unknown_role_first",
                 "[" ENTRY("futureRoleFromNewerBuild", "dev.rv.mcp") "," ENTRY("service", "dev.rv.rvd") "]", 1);
    expect_valid("only_unknown_role", "[" ENTRY("futureRoleFromNewerBuild", "dev.rv.mcp") "]", 0);
    expect_valid("unknown_role_new_key",
                 "[" ENTRY("service", "dev.rv.rvd") ","
                 "{\"role\":\"futureRoleFromNewerBuild\",\"socketPath\":\"/x\",\"requirement\":\"nonsense\"}]", 1);
    expect_valid("duplicate_unknown_roles",
                 "[" ENTRY("futureRoleFromNewerBuild", "a.b") "," ENTRY("futureRoleFromNewerBuild", "c.d") ","
                 ENTRY("service", "dev.rv.rvd") "]", 1);

    /* Unknown-role entries must still be well-formed flat string objects. */
    expect_invalid("unknown_role_number_value",
                   "[" ENTRY("service", "dev.rv.rvd") ",{\"role\":\"futureRoleFromNewerBuild\",\"port\":7}]");
    expect_invalid("unknown_role_nested_value",
                   "[" ENTRY("service", "dev.rv.rvd") ",{\"role\":\"futureRoleFromNewerBuild\",\"x\":{}}]");
    expect_invalid("unknown_role_duplicate_key",
                   "[" ENTRY("service", "dev.rv.rvd") ",{\"role\":\"futureRoleFromNewerBuild\",\"role\":\"cli\"}]");
    expect_invalid("entry_without_role",
                   "[" ENTRY("service", "dev.rv.rvd") ",{\"requirement\":\"" REQ("a.b") "\"}]");
    expect_invalid("entry_not_object", "[" ENTRY("service", "dev.rv.rvd") ",\"futureRoleFromNewerBuild\"]");

    /* Known roles stay exactly as strict. */
    expect_invalid("known_role_unknown_key",
                   "[{\"role\":\"service\",\"requirement\":\"" REQ("dev.rv.rvd") "\","
                   "\"requiredIdentifier\":\"dev.rv.rvd\",\"requiredTeamIdentifier\":\"ABCDE12345\","
                   "\"extra\":\"x\"}]");
    expect_invalid("known_role_bad_requirement",
                   "[{\"role\":\"service\",\"requirement\":\"not a requirement (\","
                   "\"requiredIdentifier\":\"dev.rv.rvd\",\"requiredTeamIdentifier\":\"ABCDE12345\"}]");
    expect_invalid("known_role_missing_team",
                   "[{\"role\":\"service\",\"requirement\":\"" REQ("dev.rv.rvd") "\","
                   "\"requiredIdentifier\":\"dev.rv.rvd\"}]");
    expect_invalid("duplicate_known_roles",
                   "[" ENTRY("service", "dev.rv.rvd") "," ENTRY("service", "dev.rv.rvd") "]");
    expect_invalid("dev_hash_unprotected_path",
                   "[{\"role\":\"service\",\"requirement\":\"cdhash H\\\"0123456789abcdef0123456789abcdef01234567\\\"\","
                   "\"developmentCDHash\":\"0123456789abcdef0123456789abcdef01234567\","
                   "\"developmentExecutablePath\":\"/tmp/rvd\"}]");
    expect_invalid("trailing_bytes", "[" ENTRY("service", "dev.rv.rvd") "]x");
    expect_invalid("not_array", ENTRY("service", "dev.rv.rvd"));

    reset();
    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("daemon_trust tests ok\n");
    return 0;
}
