/*
 * ovpnroot.c — setuid-root launcher shim for the embedded openvpn.
 *
 * The app runs as `mobile`. When it posix_spawn()s the setuid-root openvpn
 * directly, openvpn gets euid=0 but ruid=mobile. That is enough for the utun
 * open and `ifconfig` (kernel authorizes those by euid), but `/sbin/route`
 * has a userland getuid() guard that checks the REAL uid and refuses with
 * "must be root to alter routing table" — so no routes get installed.
 *
 * This shim is itself setuid-root (chmod 4755, owner root:wheel on-device).
 * When the mobile app execs it, euid becomes 0; it then setgid(0)/setuid(0)
 * to raise the REAL uid+gid to 0, and execs openvpn. openvpn (and every
 * route/ifconfig child it spawns) therefore runs with ruid=euid=0.
 *
 * Usage: ovpnroot <openvpn-path> [openvpn args...]
 * argv[1] is the program to exec; argv[1..] become the child's argv.
 */

#include <unistd.h>
#include <string.h>

/* stderr is the openvpn.log the app tails, so failures here are visible
 * on-device instead of the shim dying silently. */
static void say(const char *msg)
{
    ssize_t n = write(2, msg, strlen(msg));
    (void)n;
}

static const char not_setuid[] =
    "ovpnroot: cannot become root - this binary is not setuid-root.\n"
    "ovpnroot: as root on-device, run against THIS app dir:\n"
    "ovpnroot:   chown root:wheel openvpn ovpnroot && chmod 4755 openvpn ovpnroot\n";

int main(int argc, char **argv)
{
    if (argc < 2) {
        say("ovpnroot: usage: ovpnroot <binary> [args...]\n");
        return 2; /* need at least the target binary path */
    }

    if (geteuid() != 0) {
        say(not_setuid);
        return 3;
    }

    /* Raise real (and saved) gid/uid to 0. Must succeed while euid==0. */
    if (setgid(0) != 0) {
        say(not_setuid);
        return 3;
    }
    if (setuid(0) != 0) {
        say(not_setuid);
        return 4;
    }

    execv(argv[1], &argv[1]);
    say("ovpnroot: execv of the openvpn binary failed\n");
    return 127; /* execv only returns on failure */
}
