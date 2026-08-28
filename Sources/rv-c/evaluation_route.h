#ifndef RV_EVALUATION_ROUTE_H
#define RV_EVALUATION_ROUTE_H

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static inline int rv_semver_major(const char *semver) {
    const char *dot;
    size_t n;
    size_t i;
    unsigned long value;
    char buffer[16];
    char *end;

    if (semver == NULL || semver[0] == '\0') {
        return -1;
    }
    dot = strchr(semver, '.');
    n = dot == NULL ? strlen(semver) : (size_t)(dot - semver);
    if (n == 0 || n >= sizeof buffer) {
        return -1;
    }
    for (i = 0; i < n; i++) {
        if (semver[i] < '0' || semver[i] > '9') {
            return -1;
        }
    }
    memcpy(buffer, semver, n);
    buffer[n] = '\0';
    value = strtoul(buffer, &end, 10);
    if (end == buffer || *end != '\0' || value > (unsigned long)INT_MAX) {
        return -1;
    }
    return (int)value;
}

static inline int rv_should_miss_replay(const char *client, const char *service) {
    int client_major;
    int service_major;

    if (service == NULL || service[0] == '\0') {
        return 1;
    }
    client_major = rv_semver_major(client);
    service_major = rv_semver_major(service);
    if (client_major < 0 || service_major < 0) {
        return 1;
    }
    return client_major != service_major;
}

#endif
