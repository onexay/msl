// SPDX-License-Identifier: Apache-2.0
#include "msl_support.h"
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>

#define MSL_MAX_FDS 8

ssize_t msl_send_with_fds(int sock, const void *buf, size_t len, const int *fds, int nfds) {
    if (nfds < 0 || nfds > MSL_MAX_FDS) return -1;
    struct iovec iov = { .iov_base = (void *)buf, .iov_len = len };
    char ctrl[CMSG_SPACE(sizeof(int) * MSL_MAX_FDS)];
    memset(ctrl, 0, sizeof(ctrl));
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
    if (nfds > 0) {
        msg.msg_control = ctrl;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * nfds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);
    }
    return sendmsg(sock, &msg, 0);
}

ssize_t msl_recv_with_fds(int sock, void *buf, size_t len, int *fds, int *nfds) {
    int cap = *nfds;
    *nfds = 0;
    struct iovec iov = { .iov_base = buf, .iov_len = len };
    char ctrl[CMSG_SPACE(sizeof(int) * MSL_MAX_FDS)];
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof(ctrl) };
    ssize_t n = recvmsg(sock, &msg, 0);
    if (n < 0) return n;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            int count = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
            for (int i = 0; i < count; i++) {
                int fd;
                memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
                if (*nfds < cap) fds[(*nfds)++] = fd;
            }
        }
    }
    return n;
}
