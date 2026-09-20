#ifndef vpnold_Bridging_Header_h
#define vpnold_Bridging_Header_h

/* See ovpn_spawn.c / root_helper.c / crash_trap.c */

/* Spawn the embedded openvpn via the setuid-root ovpnroot shim (wrapper) so it
 * runs with real uid 0 and can install routes. `dns` is the bundled ovpndns
 * helper, wired up as openvpn's --up/--down script. `mgmtpw` is the file
 * holding the management-interface password, and is required. Output goes to
 * logpath. Returns child pid (>0) or -errno. */
int ovpn_spawn(const char *wrapper, const char *bin, const char *cfg,
               const char *dns, const char *mgmtpw, const char *logpath);

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

/* TEMPORARY (netdiag.c / NetDiagnostics.swift): run one shell command, capture
 * its combined output into out. Returns the exit status or -errno. */
int run_cmd(const char *cmd, char *out, int outlen);

/* TEMPORARY: resolve + TCP-connect to host:port (optionally GET `path` over
 * HTTP), reporting the resolved address, the connect result and the source
 * address the kernel chose. Pass path = NULL to only connect. `hostname` is the
 * HTTP Host: header (NULL = use host), so a literal IP can be fetched from
 * without involving the resolver. */
int net_probe(const char *host, const char *hostname, int port,
              const char *path, char *out, int outlen);

/* TEMPORARY: send a DNS A query for `name` straight to `server`, bypassing
 * mDNSResponder entirely. use_tcp selects TCP/53 over the default UDP/53.
 * `iface` (UDP only, NULL to skip) pins the socket to one interface with
 * IP_BOUND_IF, which bypasses the routing table the way Darwin's resolver does.
 * Returns 0 if a reply arrived. */
int dns_probe(const char *server, const char *name, int use_tcp,
              const char *iface, char *out, int outlen);

#endif
