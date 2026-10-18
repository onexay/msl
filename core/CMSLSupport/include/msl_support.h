// SPDX-License-Identifier: Apache-2.0
#ifndef MSL_SUPPORT_H
#define MSL_SUPPORT_H
#include <stddef.h>
#include <sys/types.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOMessage.h>

// IOMessage's compound macros cannot be imported directly by Swift.
static const uint32_t MSLHostCanSleep = kIOMessageCanSystemSleep;
static const uint32_t MSLHostWillSleep = kIOMessageSystemWillSleep;
static const uint32_t MSLHostWillWake = kIOMessageSystemWillPowerOn;
static const uint32_t MSLHostDidWake = kIOMessageSystemHasPoweredOn;
static const uint32_t MSLHostWillNotSleep = kIOMessageSystemWillNotSleep;

/// sendmsg() `len` bytes with `nfds` file descriptors attached (SCM_RIGHTS).
/// Returns bytes sent or -1 (errno set).
ssize_t msl_send_with_fds(int sock, const void *buf, size_t len, const int *fds, int nfds);

/// recvmsg() up to `len` bytes; received fds are stored in `fds` (capacity
/// `*nfds`), and `*nfds` is updated to the count received.
ssize_t msl_recv_with_fds(int sock, void *buf, size_t len, int *fds, int *nfds);

/// The first socket launchd opened for this job's `Sockets` entry `name`
/// (launch_activate_socket); -1 when not started by launchd with one.
int msl_launchd_socket(const char *name);

/// Subscribe to macOS clock changes without a Foundation main run loop.
unsigned int msl_observe_clock(const char *name, int *token, dispatch_queue_t queue, dispatch_block_t changed);
void msl_cancel_clock_observer(int token);

#endif
