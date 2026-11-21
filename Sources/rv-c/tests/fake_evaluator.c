/* A stand-in `rv-hook-local` for run.sh. FAKE_MODE (compile time) picks
 * what it does; FAKE_LOG (compile time) receives what it was given: argv,
 * cwd, environment and stdin, so tests can prove the hook sanitizes them. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef FAKE_MODE
#error "FAKE_MODE required"
#endif
#ifndef FAKE_LOG
#error "FAKE_LOG required"
#endif

extern char **environ;

static void log_call(const char *input, size_t n, int argc, char **argv) {
    FILE *f = fopen(FAKE_LOG, "w");
    char cwd[4096];
    char **e;
    int i;
    if (f == NULL) {
        return;
    }
    for (i = 1; i < argc; i++) {
        fprintf(f, "arg=%s\n", argv[i]);
    }
    fprintf(f, "cwd=%s\n", getcwd(cwd, sizeof cwd) ? cwd : "?");
    for (e = environ; *e != NULL; e++) {
        fprintf(f, "env=%s\n", *e);
    }
    fprintf(f, "stdin=");
    fwrite(input, 1, n, f);
    fprintf(f, "\n");
    fclose(f);
}

int main(int argc, char **argv) {
    static char input[1 << 21];
    size_t n = 0;
    ssize_t r;
    const char *mode = FAKE_MODE;
    const char *id = (argc == 5) ? argv[4] : "";

    while ((r = read(STDIN_FILENO, input + n, sizeof input - n)) > 0) {
        n += (size_t)r;
    }
    log_call(input, n, argc, argv);

    if (strcmp(mode, "final") == 0 || strcmp(mode, "wrong-id") == 0) {
        if (strcmp(mode, "wrong-id") == 0) {
            id = "00000000-0000-0000-0000-000000000000";
        }
        printf("rv-hook-local/1 final\n"
               "{\"id\":\"%s\",\"protocol\":\"rv.ipc.v1\",\"result\":{\"hookEvaluate\":"
               "{\"exitCode\":0,\"serviceSemver\":\"1.0.0\","
               "\"stdout\":\"LOCAL-FINAL-MARKER\\n\",\"via\":\"xpc\"}}}",
               id);
        return 0;
    }
    if (strcmp(mode, "escalate") == 0) {
        printf("rv-hook-local/1 escalate judge\n");
        return 0;
    }
    if (strcmp(mode, "hang") == 0) {
        for (;;) {
            pause();
        }
    }
    if (strcmp(mode, "crash") == 0) {
        printf("rv-hook-local/1 final\n{\"id\":\"%s\"", id);
        fflush(stdout);
        raise(SIGSEGV);
        return 0;
    }
    if (strcmp(mode, "garbage") == 0) {
        printf("allow\n");
        return 0;
    }
    return 3;
}
