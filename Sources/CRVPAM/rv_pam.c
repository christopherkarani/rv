#include "rv_pam.h"

#ifdef __linux__

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

/* Linux-PAM's ABI (security/_pam_types.h), by value: stable since 0.99. */
struct rv_pam_msg {
    int msg_style;
    const char *msg;
};

struct rv_pam_response {
    char *resp;
    int resp_retcode;
};

struct rv_pam_conv {
    int (*conv)(int count, const struct rv_pam_msg **messages, struct rv_pam_response **responses, void *data);
    void *data;
};

#define RV_PAM_SUCCESS 0
#define RV_PAM_BUF_ERR 5
#define RV_PAM_CONV_ERR 19
#define RV_PAM_DISALLOW_NULL_AUTHTOK 0x0001
#define RV_PAM_MAX_MESSAGES 32
#define RV_PAM_ANSWER_BYTES 1025

struct rv_pam_state {
    rv_pam_converse converse;
    void *context;
    int answers;
};

static void rv_pam_wipe(char *text) {
    if (text != NULL) {
        explicit_bzero(text, strlen(text));
    }
}

static int rv_pam_conversation(
    int count, const struct rv_pam_msg **messages, struct rv_pam_response **responses, void *data) {
    struct rv_pam_state *state = data;
    struct rv_pam_response *replies;
    char answer[RV_PAM_ANSWER_BYTES];
    int index;

    if (count <= 0 || count > RV_PAM_MAX_MESSAGES || messages == NULL || responses == NULL) {
        return RV_PAM_CONV_ERR;
    }
    replies = calloc((size_t)count, sizeof(*replies));
    if (replies == NULL) {
        return RV_PAM_BUF_ERR;
    }
    for (index = 0; index < count; index++) {
        int kind = messages[index]->msg_style;
        const char *text = messages[index]->msg != NULL ? messages[index]->msg : "";
        int wants_answer = kind == RV_PAM_SECRET || kind == RV_PAM_VISIBLE;
        if (kind < RV_PAM_SECRET || kind > RV_PAM_INFO) {
            goto fail;
        }
        memset(answer, 0, sizeof(answer));
        if (state->converse(state->context, kind, text, answer, sizeof(answer)) != 0) {
            goto fail;
        }
        if (wants_answer) {
            answer[sizeof(answer) - 1] = '\0';
            replies[index].resp = strdup(answer);
            explicit_bzero(answer, sizeof(answer));
            if (replies[index].resp == NULL) {
                goto fail;
            }
            state->answers++;
        }
    }
    *responses = replies;
    return RV_PAM_SUCCESS;

fail:
    explicit_bzero(answer, sizeof(answer));
    for (index = 0; index < count; index++) {
        rv_pam_wipe(replies[index].resp);
        free(replies[index].resp);
    }
    free(replies);
    return RV_PAM_CONV_ERR;
}

int rv_pam_authenticate(const char *service, const char *user, rv_pam_converse converse, void *context, int *answers) {
    int (*start)(const char *, const char *, const struct rv_pam_conv *, void **);
    int (*authenticate)(void *, int);
    int (*account)(void *, int);
    int (*end)(void *, int);
    struct rv_pam_state state = { converse, context, 0 };
    struct rv_pam_conv conversation = { rv_pam_conversation, &state };
    void *library;
    void *handle = NULL;
    int status;

    *answers = 0;
    library = dlopen("libpam.so.0", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        return RV_PAM_UNAVAILABLE;
    }
    start = (int (*)(const char *, const char *, const struct rv_pam_conv *, void **))dlsym(library, "pam_start");
    authenticate = (int (*)(void *, int))dlsym(library, "pam_authenticate");
    account = (int (*)(void *, int))dlsym(library, "pam_acct_mgmt");
    end = (int (*)(void *, int))dlsym(library, "pam_end");
    if (start == NULL || authenticate == NULL || account == NULL || end == NULL) {
        return RV_PAM_UNAVAILABLE;
    }
    if (start(service, user, &conversation, &handle) != RV_PAM_SUCCESS || handle == NULL) {
        return RV_PAM_UNAVAILABLE;
    }
    status = authenticate(handle, RV_PAM_DISALLOW_NULL_AUTHTOK);
    if (status == RV_PAM_SUCCESS) {
        status = account(handle, RV_PAM_DISALLOW_NULL_AUTHTOK);
    }
    end(handle, status);
    *answers = state.answers;
    return status == RV_PAM_SUCCESS ? RV_PAM_AUTHENTICATED : RV_PAM_REFUSED;
}

#else

int rv_pam_authenticate(const char *service, const char *user, rv_pam_converse converse, void *context, int *answers) {
    (void)service;
    (void)user;
    (void)converse;
    (void)context;
    *answers = 0;
    return RV_PAM_UNAVAILABLE;
}

#endif
