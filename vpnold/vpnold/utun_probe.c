/*
 * utun_probe.c — M2 diagnostic: does this kernel expose utun?
 *
 * Opens a PF_SYSTEM / SYSPROTO_CONTROL socket and asks the kernel for the
 * "com.apple.net.utun_control" control. Reports, stage by stage, whether:
 *   - the utun control is REGISTERED in the running kernel (CTLIOCGINFO), and
 *   - it can be opened for this uid (connect()).
 *
 * Notes on interpreting the result when run from the (mobile) app sandbox:
 *   - CTLIOCGINFO failing with ENOENT  => the kernel has NO utun at all.
 *   - CTLIOCGINFO succeeding but connect() failing with EPERM => utun EXISTS
 *     in the kernel but needs root; running openvpn as root (setuid) will work.
 *   - connect() succeeding => utun present AND usable by this uid.
 *
 * This is pure diagnostics — it opens nothing persistent and routes no traffic.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <net/if_utun.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

/* Returns a utun fd (>=0) on full success, or a negative stage code:
 *   -1 socket() failed, -2 CTLIOCGINFO failed, -3 connect() failed.
 * A human-readable explanation is written to msg. */
int utun_probe(char *msg, int msglen)
{
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        snprintf(msg, msglen, "socket(PF_SYSTEM, SYSPROTO_CONTROL) failed: %s",
                 strerror(errno));
        return -1;
    }

    struct ctl_info info;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
        snprintf(msg, msglen,
                 "CTLIOCGINFO(%s) failed: %s -> utun NOT registered in this kernel",
                 UTUN_CONTROL_NAME, strerror(errno));
        close(fd);
        return -2;
    }

    struct sockaddr_ctl addr;
    memset(&addr, 0, sizeof(addr));
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = info.ctl_id;
    addr.sc_unit = 0; /* 0 = kernel assigns next free utunN */
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        snprintf(msg, msglen,
                 "utun_control REGISTERED (ctl_id=%u) but connect failed: %s%s",
                 info.ctl_id, strerror(e),
                 e == EPERM ? " -> needs root; running openvpn as root should work"
                            : "");
        close(fd);
        return -3;
    }

    char ifname[32];
    socklen_t optlen = sizeof(ifname);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &optlen) < 0)
        strncpy(ifname, "utun?", sizeof(ifname));
    snprintf(msg, msglen,
             "SUCCESS: utun opened as %s (kernel supports utun, usable by this uid)",
             ifname);
    return fd;
}
