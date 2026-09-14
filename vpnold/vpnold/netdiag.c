/* netdiag.c — TEMPORARY diagnostic helper.
 *
 * Runs one shell command and captures its combined output. Exists only so the
 * "Net check" button can print the verification steps into the in-app log,
 * which is far easier to share than SSHing into the phone and copying by hand.
 *
 * Foundation's Process/NSTask does not exist on iOS, hence popen(). Delete this
 * file (and NetDiagnostics.swift) once the tunnel is confirmed working.
 */

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <netdb.h>
#include <net/if.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* Runs `cmd` through /bin/sh with stderr folded into stdout, writing up to
 * outlen-1 bytes into out. Returns the command's exit status, or -errno. */
int run_cmd(const char *cmd, char *out, int outlen)
{
    if (!cmd || !out || outlen < 1) return -EINVAL;
    out[0] = '\0';

    char full[2048];
    snprintf(full, sizeof full, "%s 2>&1", cmd);

    FILE *p = popen(full, "r");
    if (!p) return -errno;

    /* Read to the end even after the buffer fills: closing the pipe early
     * would SIGPIPE the child and report a bogus failure. */
    int used = 0;
    char line[512];
    while (fgets(line, sizeof line, p)) {
        int n = (int)strlen(line);
        if (used + n < outlen - 1) {
            memcpy(out + used, line, n);
            used += n;
            out[used] = '\0';
        }
    }

    int st = pclose(p);
    if (st == -1) return -errno;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return 128 + WTERMSIG(st);
}

/* ------------------------------------------------------------------------ */

/* Append printf-style to the end of `out`, never past outlen-1. */
static void outf(char *out, int outlen, const char *fmt, ...)
{
    int used = (int)strlen(out);
    if (used >= outlen - 1) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(out + used, outlen - used, fmt, ap);
    va_end(ap);
}

/* Step over one DNS name (label sequence or 0xC0 compression pointer). */
static const unsigned char *skip_name(const unsigned char *p,
                                      const unsigned char *end)
{
    while (p < end) {
        if ((*p & 0xC0) == 0xC0) return (p + 2 <= end) ? p + 2 : NULL;
        if (*p == 0) return p + 1;
        p += 1 + *p;
    }
    return NULL;
}

/* Connect a TCP socket with a bounded timeout, so a black-holed route fails in
 * `secs` instead of hanging this thread for the TCP default of ~75s. Returns a
 * connected fd (blocking mode restored), or -1 with the reason written to out. */
static int connect_timeout(const struct sockaddr_in *to, int secs,
                           char *out, int outlen)
{
    char ip[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &to->sin_addr, ip, sizeof ip);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        outf(out, outlen, "socket: %s\n", strerror(errno));
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, (const struct sockaddr *)to, sizeof *to);
    if (rc < 0 && errno == EINPROGRESS) {
        fd_set w;
        FD_ZERO(&w);
        FD_SET(fd, &w);
        struct timeval tv;
        tv.tv_sec = secs;
        tv.tv_usec = 0;
        rc = select(fd + 1, NULL, &w, NULL, &tv);
        if (rc == 0) {
            outf(out, outlen, "connect %s:%d: TIMED OUT after %ds\n",
                 ip, ntohs(to->sin_port), secs);
            close(fd);
            return -1;
        }
        if (rc < 0) {
            outf(out, outlen, "select: %s\n", strerror(errno));
            close(fd);
            return -1;
        }
        int err = 0;
        socklen_t elen = sizeof err;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err) {
            outf(out, outlen, "connect %s:%d: %s\n",
                 ip, ntohs(to->sin_port), strerror(err));
            close(fd);
            return -1;
        }
    } else if (rc < 0) {
        outf(out, outlen, "connect %s:%d: %s\n",
             ip, ntohs(to->sin_port), strerror(errno));
        close(fd);
        return -1;
    }

    fcntl(fd, F_SETFL, flags);
    return fd;
}

/* Report the local address a connected socket ended up with. */
static void report_source(int fd, char *out, int outlen)
{
    struct sockaddr_in loc;
    socklen_t llen = sizeof loc;
    if (getsockname(fd, (struct sockaddr *)&loc, &llen) != 0) return;
    char lip[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &loc.sin_addr, lip, sizeof lip);
    outf(out, outlen, "source address %s (10.8.0.2 = via tunnel, "
                      "192.168.0.x = NOT tunnelled)\n", lip);
}

/* Pin a socket to one interface with IP_BOUND_IF, the way Darwin's resolver
 * scopes its queries. This is stronger than a route: it bypasses the routing
 * table, so a socket bound to en0 ignores `0/1 via utun0` and leaves over wifi
 * even with the tunnel up. Returns 0 on success. */
static int bind_to_iface(int fd, const char *iface, char *out, int outlen)
{
    unsigned int idx = if_nametoindex(iface);
    if (idx == 0) {
        outf(out, outlen, "no such interface %s\n", iface);
        return -1;
    }
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx) != 0) {
        outf(out, outlen, "IP_BOUND_IF %s: %s\n", iface, strerror(errno));
        return -1;
    }
    outf(out, outlen, "socket pinned to %s (ignores the routing table)\n", iface);
    return 0;
}

/* Send one DNS A query for `name` straight to `server` and report what comes
 * back. `use_tcp` selects TCP/53 instead of UDP/53. `iface`, when not NULL,
 * pins the socket to that interface.
 *
 * This exists to separate two very different failures that look identical from
 * getaddrinfo: the resolver daemon being wedged (mDNSResponder holding sockets
 * bound to the pre-tunnel source address) versus the tunnel simply not carrying
 * UDP. Our own socket is created fresh, after the tunnel is up, so it gets the
 * correct source address — if this succeeds while getaddrinfo fails, the tunnel
 * is fine and mDNSResponder is the problem.
 *
 * Returns 0 if a well-formed reply arrived. */
int dns_probe(const char *server, const char *name, int use_tcp,
              const char *iface, char *out, int outlen)
{
    if (!server || !name || !out || outlen < 1) return -EINVAL;
    out[0] = '\0';

    unsigned char q[512];
    int n = 0;
    q[n++] = 0x12; q[n++] = 0x34;          /* transaction id */
    q[n++] = 0x01; q[n++] = 0x00;          /* standard query, recursion desired */
    q[n++] = 0x00; q[n++] = 0x01;          /* qdcount = 1 */
    q[n++] = 0x00; q[n++] = 0x00;          /* ancount */
    q[n++] = 0x00; q[n++] = 0x00;          /* nscount */
    q[n++] = 0x00; q[n++] = 0x00;          /* arcount */

    /* Encode "example.com" as 7"example"3"com"0 */
    const char *s = name;
    while (*s && n < (int)sizeof q - 6) {
        const char *dot = strchr(s, '.');
        int len = dot ? (int)(dot - s) : (int)strlen(s);
        if (len <= 0 || len > 63) return -EINVAL;
        q[n++] = (unsigned char)len;
        memcpy(q + n, s, len);
        n += len;
        if (!dot) break;
        s = dot + 1;
    }
    q[n++] = 0x00;
    q[n++] = 0x00; q[n++] = 0x01;          /* qtype  = A */
    q[n++] = 0x00; q[n++] = 0x01;          /* qclass = IN */

    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = htons(53);
    if (inet_pton(AF_INET, server, &to.sin_addr) != 1) {
        outf(out, outlen, "bad server address %s\n", server);
        return -EINVAL;
    }

    outf(out, outlen, "query %s @%s over %s%s%s\n",
         name, server, use_tcp ? "TCP/53" : "UDP/53",
         iface ? " pinned to " : "", iface ? iface : "");

    time_t t0 = time(NULL);
    int fd;
    unsigned char r[1024];
    ssize_t got;

    if (use_tcp) {
        /* connect_timeout makes its own socket, so pinning is UDP-only —
         * which is all the resolver question needs. */
        fd = connect_timeout(&to, 6, out, outlen);
        if (fd < 0) return -ETIMEDOUT;
        report_source(fd, out, outlen);

        struct timeval tv;
        tv.tv_sec = 6;
        tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        /* DNS over TCP prefixes the message with a 2-byte length. */
        unsigned char framed[514];
        framed[0] = (unsigned char)(n >> 8);
        framed[1] = (unsigned char)(n & 0xFF);
        memcpy(framed + 2, q, n);
        if (send(fd, framed, n + 2, 0) < 0) {
            outf(out, outlen, "send: %s\n", strerror(errno));
            close(fd);
            return -errno;
        }
        unsigned char hdr[2];
        got = recv(fd, hdr, 2, MSG_WAITALL);
        if (got == 2) got = recv(fd, r, sizeof r, 0);
        else          got = (got == 0) ? 0 : -1;
    } else {
        fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) {
            outf(out, outlen, "socket: %s\n", strerror(errno));
            return -errno;
        }
        if (iface && bind_to_iface(fd, iface, out, outlen) != 0) {
            close(fd);
            return -EINVAL;
        }
        struct timeval tv;
        tv.tv_sec = 5;
        tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        /* connect() rather than sendto(): an unconnected UDP socket is never
         * bound on Darwin, so getsockname would just report 0.0.0.0 and tell
         * us nothing about which interface the query left by. */
        if (connect(fd, (struct sockaddr *)&to, sizeof to) < 0) {
            outf(out, outlen, "connect %s: %s\n", server, strerror(errno));
            close(fd);
            return -errno;
        }
        report_source(fd, out, outlen);

        if (send(fd, q, n, 0) < 0) {
            outf(out, outlen, "send %s: %s\n", server, strerror(errno));
            close(fd);
            return -errno;
        }
        got = recv(fd, r, sizeof r, 0);
    }
    close(fd);

    if (got < 12) {
        outf(out, outlen, "NO REPLY (%lds elapsed, recv=%ld %s)\n",
             (long)(time(NULL) - t0), (long)got,
             got < 0 ? strerror(errno) : "peer closed");
        return -ETIMEDOUT;
    }

    int rcode = r[3] & 0x0F;
    int ancount = (r[6] << 8) | r[7];
    outf(out, outlen, "reply in %lds: rcode=%d answers=%d\n",
         (long)(time(NULL) - t0), rcode, ancount);

    const unsigned char *p = r + 12, *end = r + got;
    p = skip_name(p, end);                 /* question name */
    if (!p || p + 4 > end) return 0;
    p += 4;                                /* qtype + qclass */

    for (int i = 0; i < ancount && p && p + 10 <= end; i++) {
        p = skip_name(p, end);
        if (!p || p + 10 > end) break;
        int type = (p[0] << 8) | p[1];
        int rdlen = (p[8] << 8) | p[9];
        p += 10;
        if (p + rdlen > end) break;
        if (type == 1 && rdlen == 4) {
            char aip[INET_ADDRSTRLEN] = "?";
            inet_ntop(AF_INET, p, aip, sizeof aip);
            outf(out, outlen, "  A %s\n", aip);
        }
        p += rdlen;
    }
    return 0;
}

/* Resolve `host`, open a TCP connection to it, and optionally fetch `path`
 * over plain HTTP/1.0. Everything is reported into out.
 *
 * This replaces the ping steps. /usr/bin/ping on this device answers
 * "unsupported packet type: 5" whether or not the VPN is up, so it tells us
 * nothing — and a TCP probe actually proves more:
 *   - getaddrinfo succeeding proves the pushed DNS servers are reachable and
 *     answering (i.e. resolution really works through the tunnel),
 *   - connect succeeding proves packets get out and replies come back,
 *   - getsockname tells us the source address the kernel picked, which is the
 *     direct answer to "did this leave through utun0 or through wifi?".
 *
 * AF_INET only, on purpose: the tunnel carries IPv4, and letting this fall back
 * to IPv6 would test the very path that bypasses the VPN.
 *
 * `hostname` is what goes in the HTTP Host: header; pass NULL to use `host`.
 * Passing a literal IP as `host` plus the real name as `hostname` fetches from
 * a name-based virtual host without involving the resolver at all, which is how
 * we read our exit IP while mDNSResponder is wedged.
 *
 * Returns 0 on a completed connection, or a negative errno-ish code. */
int net_probe(const char *host, const char *hostname, int port,
              const char *path, char *out, int outlen)
{
    if (!host || !out || outlen < 1) return -EINVAL;
    out[0] = '\0';

    char portstr[16];
    snprintf(portstr, sizeof portstr, "%d", port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    time_t t0 = time(NULL);
    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0 || !res) {
        outf(out, outlen, "resolve %s: FAILED after %lds (%s)\n",
             host, (long)(time(NULL) - t0), gai_strerror(gai));
        return -EHOSTUNREACH;
    }

    char ip[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr,
              ip, sizeof ip);
    outf(out, outlen, "resolve %s -> %s (%lds)\n",
         host, ip, (long)(time(NULL) - t0));

    struct sockaddr_in to;
    memcpy(&to, res->ai_addr, sizeof to);
    freeaddrinfo(res);

    int fd = connect_timeout(&to, 6, out, outlen);
    if (fd < 0) return -ETIMEDOUT;

    outf(out, outlen, "connect %s:%d OK (%lds)\n",
         ip, port, (long)(time(NULL) - t0));
    report_source(fd, out, outlen);

    if (path) {
        char req[512];
        snprintf(req, sizeof req,
                 "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
                 path, hostname ? hostname : host);
        if (send(fd, req, strlen(req), 0) < 0) {
            outf(out, outlen, "send: %s\n", strerror(errno));
        } else {
            struct timeval rtv;
            rtv.tv_sec = 15;
            rtv.tv_usec = 0;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof rtv);

            char buf[1024];
            ssize_t n;
            int total = 0;
            while (total < 3072 && (n = recv(fd, buf, sizeof buf - 1, 0)) > 0) {
                buf[n] = '\0';
                outf(out, outlen, "%s", buf);
                total += (int)n;
            }
            /* How the read loop ended is the whole point: a clean FIN after
             * zero bytes means the peer (or something in the path) tore the
             * connection down rather than answering, ETIMEDOUT means the reply
             * never arrived at all, and ECONNRESET means an RST came back. */
            const char *why = (n == 0)             ? "peer closed (FIN)"
                            : (errno == EAGAIN ||
                               errno == EWOULDBLOCK) ? "timed out, nothing more"
                                                     : strerror(errno);
            outf(out, outlen, "\n[%d bytes of HTTP reply in %lds, ended: %s]\n",
                 total, (long)(time(NULL) - t0), why);
        }
    }

    close(fd);
    return 0;
}
