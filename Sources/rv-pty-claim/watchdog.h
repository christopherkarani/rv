#ifndef RV_PTY_CLAIM_WATCHDOG_H
#define RV_PTY_CLAIM_WATCHDOG_H

#include <stdint.h>
#include <sys/types.h>

/*
 * Arms the out-of-host watchdog for the calling leader. 0 disables the
 * deadline, the CPU cap or the owner. A nonzero owner is the leader of
 * the runtime this process serves: its exit ends this tree too.
 * Returns 0 only after the watchdog reports it is tracking the leader
 * (and watching the owner); any other result means it is not running.
 */
int rv_start_watchdog(uint64_t deadline_seconds, uint64_t cpu_seconds, pid_t owner);

#endif
