#ifndef vpnold_Bridging_Header_h
#define vpnold_Bridging_Header_h

/* M2 diagnostics — see utun_probe.c / ovpn_spawn.c */

/* Probe whether the kernel exposes com.apple.net.utun_control.
 * Writes a human-readable explanation into msg; returns a utun fd (>=0) on
 * full success or a negative stage code. */
int utun_probe(char *msg, int msglen);

/* Spawn the embedded openvpn via the setuid-root ovpnroot shim (wrapper) so it
 * runs with real uid 0 and can install routes. Output goes to logpath.
 * Returns child pid (>0) or -errno. */
int ovpn_spawn(const char *wrapper, const char *bin, const char *cfg,
               const char *logpath);

/* Install signal handlers that append a backtrace to `path` when the process
 * dies (see crash_trap.c). Returns 0, or -1 if the file could not be opened. */
int crash_trap_install(const char *path);

/* Append one breadcrumb line to that same file. */
void crash_trap_note(const char *line);

/* Run one command as root through `su`, answering its password prompt on a pty
 * (see root_helper.c). Output goes to out; returns su's exit status or -errno. */
int run_as_root(const char *password, const char *command, char *out, int outlen);

/* Non-blocking child check: 0 = running, 1 = exited (*exitcode set), -errno. */
int ovpn_wait(int pid, int *exitcode);

/* SIGTERM the openvpn child. Returns 0 or -errno. */
int ovpn_kill(int pid);

#endif
