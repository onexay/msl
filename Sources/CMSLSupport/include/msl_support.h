#ifndef MSL_SUPPORT_H
#define MSL_SUPPORT_H
#include <stddef.h>
#include <sys/types.h>

/// sendmsg() `len` bytes with `nfds` file descriptors attached (SCM_RIGHTS).
/// Returns bytes sent or -1 (errno set).
ssize_t msl_send_with_fds(int sock, const void *buf, size_t len, const int *fds, int nfds);

/// recvmsg() up to `len` bytes; received fds are stored in `fds` (capacity
/// `*nfds`), and `*nfds` is updated to the count received.
ssize_t msl_recv_with_fds(int sock, void *buf, size_t len, int *fds, int *nfds);

#endif
