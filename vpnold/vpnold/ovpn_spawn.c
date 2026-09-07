/*
 * ovpn_spawn.c — M2/M3 diagnostic: launch the embedded openvpn binary.
 *
 * posix_spawn()s the bundled setuid-root `ovpnroot` shim, which raises the
 * real uid/gid to 0 and then execs the bundled `openvpn` with the given .ovpn
 * config. Running openvpn with ruid=0 (not just euid=0) is required so the
 * `/sbin/route` children it spawns pass their getuid() guard and can install
 * routes. stdout+stderr are redirected to a log file that the Swift UI tails.
 * --management is enabled so a later milestone (M4) can drive it over a local
 * socket; here we just read the log.
 */

#include <spawn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>

extern char **environ;

/* Launch openvpn through the setuid-root ovpnroot shim.
 *   wrapper — path to the bundled ovpnroot (setuid-root on-device)
 *   bin     — path to the bundled openvpn (exec'd by ovpnroot as root)
 *   cfg     — path to the .ovpn config
 *   logpath — file that receives openvpn's stdout+stderr
 * Returns the child pid (>0) on success, or -errno on failure. */
int ovpn_spawn(const char *wrapper, const char *bin, const char *cfg,
               const char *logpath)
{
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, logpath,
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2); /* stderr -> same log */

    /* argv[0] is ovpnroot; argv[1] is the openvpn binary it should exec, and
     * the remainder are openvpn's own arguments.
     *
     * On Darwin/iOS the device name must be "utun" (so openvpn takes the
     * kernel utun_control path, not the nonexistent /dev/tun kext) AND the
     * device type must be given explicitly as "tun" — openvpn only infers
     * tun/tap from names literally starting with "tun"/"tap", so a bare
     * "utun" resolves to an undefined type ("problem with tun vs. tap"). */
    char *const argv[] = {
        (char *)wrapper,
        (char *)bin,
        "--config", (char *)cfg,
        "--verb", "4",
        "--dev", "utun",
        "--dev-type", "tun",
        "--management", "127.0.0.1", "7505",
        (char *)0
    };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, wrapper, &fa, (void *)0, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0)
        return -rc;
    return (int)pid;
}

/* Non-blocking check on the child. Returns 0 if it is still running, 1 if it
 * has exited (with *exitcode set: the exit status, or 128+signal if killed),
 * or -errno. Reaping it here also stops it lingering as a zombie. */
int ovpn_wait(int pid, int *exitcode)
{
    int st = 0;
    pid_t r = waitpid((pid_t)pid, &st, WNOHANG);
    if (r < 0)
        return -errno;
    if (r == 0)
        return 0;

    if (WIFEXITED(st))
        *exitcode = WEXITSTATUS(st);
    else if (WIFSIGNALED(st))
        *exitcode = 128 + WTERMSIG(st);
    else
        *exitcode = -1;
    return 1;
}

/* Send SIGTERM to the openvpn child. Returns 0 or -errno. */
int ovpn_kill(int pid)
{
    if (kill((pid_t)pid, SIGTERM) < 0)
        return -errno;
    return 0;
}
