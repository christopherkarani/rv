/*
 * PAM authentication for the approvals custodian's presence helper
 * (docs/security/mcp-linux-custodian.md). libpam is loaded at run time
 * (dlopen "libpam.so.0"), so building rv needs no PAM headers.
 */
#ifndef RV_PAM_H
#define RV_PAM_H

#include <stddef.h>

/* What PAM asks the owner. */
enum rv_pam_message {
    RV_PAM_SECRET = 1, /* answer expected, not echoed */
    RV_PAM_VISIBLE = 2, /* answer expected, echoed */
    RV_PAM_ERROR = 3, /* text to show */
    RV_PAM_INFO = 4, /* text to show */
};

/*
 * Called for each message. For RV_PAM_SECRET and RV_PAM_VISIBLE it writes
 * a NUL-terminated answer of at most `size` bytes (NUL included) into
 * `answer` and returns 0; any other return aborts the authentication.
 */
typedef int (*rv_pam_converse)(void *context, int kind, const char *text, char *answer, size_t size);

enum rv_pam_outcome {
    RV_PAM_AUTHENTICATED = 0,
    RV_PAM_REFUSED = 1, /* PAM said no, or the account may not log in */
    RV_PAM_UNAVAILABLE = 2, /* libpam could not be loaded or started */
};

/*
 * Authenticates `user` with the PAM service `service` and checks the
 * account is valid. `*answers` is the number of answers the owner gave.
 */
int rv_pam_authenticate(const char *service, const char *user, rv_pam_converse converse, void *context, int *answers);

#endif
