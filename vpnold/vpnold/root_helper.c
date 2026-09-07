/*
 * root_helper.c — run one command as root via `su`, driven from the app.
 *
 * After every (re)install the embedded openvpn/ovpnroot binaries must be made
 * setuid-root again, which normally means an SSH session and a manual
 * chown/chmod. This does the same thing from the UI.
 *
 * `su` reads its password with getpass(), which opens /dev/tty — it ignores
 * stdin. So the child is started under a pty (forkpty); the pty slave becomes
 * its controlling terminal and we answer the prompt on the master side. The
 * password is only ever written to that pty: it is NOT part of the command
 * line (where `ps` would expose it) and it is not stored anywhere.
 *
 * Authentication is still done by su itself — this only automates the typing.
 */

#include <sys/types.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#if __has_include(<util.h>)
#include <util.h>
#else
/* util.h is one of the headers stripped from the iOS SDK; forkpty itself
 * lives in libSystem, so just declare it. */
extern int forkpty(int *amaster, char *name, void *termp, void *winp);
#endif

/* Run `command` as root. `out` receives whatever su and the command print
 * (prompt included), NUL-terminated.
 * Returns su's exit status (0 = success), or -errno on failure to start. */
int run_as_root(const char *password, const char *command, char *out, int outlen)
{
    if (!password || !command || !out || outlen < 2)
        return -EINVAL;
    out[0] = '\0';

    int master = -1;
    pid_t pid = forkpty(&master, (char *)0, (void *)0, (void *)0);
    if (pid < 0)
        return -errno;

    if (pid == 0) {
        /* Child: stdin/stdout/stderr and the controlling tty are the pty slave,
         * so getpass() finds a terminal to prompt on. */
        execl("/usr/bin/su", "su", "root", "-c", command, (char *)0);
        execl("/bin/su", "su", "root", "-c", command, (char *)0);
        _exit(127); /* no su on this device */
    }

    int used = 0;
    int sent_password = 0;
    time_t deadline = time((time_t *)0) + 20;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(master, &rfds);
        struct timeval tv = { 1, 0 };

        int r = select(master + 1, &rfds, (fd_set *)0, (fd_set *)0, &tv);
        if (r > 0) {
            char buf[512];
            ssize_t n = read(master, buf, sizeof buf);
            if (n <= 0)
                break; /* EOF — su exited */
            int room = outlen - 1 - used;
            if (room > 0) {
                int take = (n < room) ? (int)n : room;
                memcpy(out + used, buf, take);
                used += take;
                out[used] = '\0';
            }
            /* Answer the first "Password:" prompt we see. */
            if (!sent_password && strstr(out, "assword")) {
                ssize_t w = write(master, password, strlen(password));
                w = write(master, "\n", 1);
                (void)w;
                sent_password = 1;
            }
        } else if (r < 0 && errno != EINTR) {
            break;
        }
        if (time((time_t *)0) > deadline)
            break; /* wedged — don't hang the UI thread's helper queue */
    }

    close(master);

    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        return -errno;
    if (WIFEXITED(st))
        return WEXITSTATUS(st);
    return -ECHILD;
}
