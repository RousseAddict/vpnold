/*
 * ovpndns.c — apply/restore the DNS servers pushed by the VPN server.
 *
 * openvpn on Darwin has no DNS integration at all: it parses
 * `dhcp-option DNS x.x.x.x` out of PUSH_REPLY, exports it as foreign_option_N
 * in the environment of its --up script, and then does nothing with it. So on
 * a full tunnel the device keeps resolving through whatever resolver DHCP gave
 * it — typically the LAN router, which is reachable over the *local* route and
 * therefore bypasses the tunnel entirely. That is a real DNS leak.
 *
 * On iOS the resolver (mDNSResponder) takes its configuration from configd's
 * dynamic store, NOT from /etc/resolv.conf — that file is merely a courtesy
 * copy that configd regenerates. So applying DNS means writing
 *
 *     State:/Network/Service/<service>/DNS
 *
 * which is the same key Tunnelblick drives via `scutil` on macOS, and undoing
 * it on the way down.
 *
 * WHICH service is not a detail — it is the whole thing. configd hands each
 * resolver to mDNSResponder tagged with the interface of the service it was
 * found under, and mDNSResponder then pins its query sockets to that interface
 * with IP_BOUND_IF. IP_BOUND_IF overrides the routing table, so a resolver
 * filed under the wifi service is sent out wifi even while 0/1 and 128.0/1
 * point at utun0 — and since the pushed server is off-LAN and en0 has no route
 * to it, the send fails outright with EADDRNOTAVAIL. Writing the DNS under the
 * pre-existing primary (en0) service therefore produced a resolver that could
 * not resolve anything, which was measured on-device: the identical query
 * answers in 0s unpinned or pinned to utun0, and cannot even be sent pinned to
 * en0.
 *
 * So we do not borrow the wifi service. We publish utun0 as a service of its
 * own and put the DNS under it, marked SUPPLEMENTAL with an empty match domain
 * — the split-DNS mechanism, which matches every name. configd hands a
 * supplemental resolver to mDNSResponder with no if_index, so it is not pinned
 * at all and its queries follow the routing table straight into the tunnel.
 * (Claiming the primary service instead does not work: IPMonitor recomputes
 * State:/Network/Global/IPv4 and puts en0 back immediately.) Everything we
 * overwrite is saved first and put back on the way down; and as the dynamic
 * store lives only in configd's memory, a reboot restores it regardless.
 *
 * SystemConfiguration's SCDynamicStore API is absent from the public iOS SDK
 * (no headers, and the stub library may not export it), so the four functions
 * are resolved with dlopen/dlsym against the framework on the device and the
 * prototypes are declared here.
 *
 * The same up/down hooks also block IPv6 to the internet while connected, so
 * that dual-stack traffic falls back to IPv4 and the tunnel instead of leaking
 * out of en0 (see v6_block).
 *
 * Invoked by openvpn as `ovpndns up` / `ovpndns down` (see ovpn_spawn.c), which
 * means it inherits openvpn's ruid=euid=0 — writing State: keys needs root.
 * openvpn's own stdout is our log file, so everything printed here shows up in
 * the app's log view. `ovpndns show` is a read-only dump for debugging from a
 * root shell.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* The iOS SDK strips <net/route.h>. These are the few routing-socket
 * definitions the IPv6 block below needs, copied from xnu, where this ABI
 * (RTM_VERSION 5) has not changed in well over a decade. */
#if __has_include(<net/route.h>)
#include <net/route.h>
#else
struct rt_metrics {
    u_int32_t rmx_locks, rmx_mtu, rmx_hopcount;
    int32_t   rmx_expire;
    u_int32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar,
              rmx_pksent, rmx_filler[4];
};
struct rt_msghdr {
    u_short rtm_msglen;
    u_char  rtm_version;
    u_char  rtm_type;
    u_short rtm_index;
    int     rtm_flags;
    int     rtm_addrs;
    pid_t   rtm_pid;
    int     rtm_seq;
    int     rtm_errno;
    int     rtm_use;
    u_int32_t rtm_inits;
    struct rt_metrics rtm_rmx;
};
#define RTM_VERSION 5
#define RTM_ADD     0x1
#define RTM_DELETE  0x2
#define RTF_UP      0x1
#define RTF_GATEWAY 0x2
#define RTF_REJECT  0x8
#define RTF_STATIC  0x800
#define RTA_DST     0x1
#define RTA_GATEWAY 0x2
#define RTA_NETMASK 0x4
#endif

/* Where the pre-VPN values of every key we touch are parked between up and
 * down. */
#define BACKUP_PATH "/var/tmp/ovpndns-backup.plist"

/* The service we publish for the tunnel. A fixed id rather than a fresh UUID so
 * that a leftover from a crashed session is found and reused instead of
 * accumulating. Shaped like a UUID because everything else under
 * State:/Network/Service/ is. */
#define VPN_SERVICE_ID "6F1D2C3B-4A59-4E7F-8C0D-9B2E1A3F5D47"

/* ── SystemConfiguration, resolved at runtime ─────────────────────────────── */

typedef const struct __SCDynamicStore *SCDynamicStoreRef;

typedef SCDynamicStoreRef (*sc_create_f)(CFAllocatorRef, CFStringRef,
                                         void *, void *);
typedef CFPropertyListRef (*sc_copy_f)(SCDynamicStoreRef, CFStringRef);
typedef Boolean (*sc_set_f)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef);
typedef Boolean (*sc_remove_f)(SCDynamicStoreRef, CFStringRef);

static sc_create_f sc_create;
static sc_copy_f   sc_copy;
static sc_set_f    sc_set;
static sc_remove_f sc_remove;

static int sc_load(void)
{
    void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework"
                     "/SystemConfiguration", RTLD_LAZY);
    if (!h) {
        printf("ovpndns: dlopen SystemConfiguration failed: %s\n", dlerror());
        return -1;
    }
    sc_create = (sc_create_f)dlsym(h, "SCDynamicStoreCreate");
    sc_copy   = (sc_copy_f)dlsym(h, "SCDynamicStoreCopyValue");
    sc_set    = (sc_set_f)dlsym(h, "SCDynamicStoreSetValue");
    sc_remove = (sc_remove_f)dlsym(h, "SCDynamicStoreRemoveValue");
    if (!sc_create || !sc_copy || !sc_set || !sc_remove) {
        printf("ovpndns: SCDynamicStore symbols missing from the framework\n");
        return -1;
    }
    return 0;
}

/* ── small helpers ────────────────────────────────────────────────────────── */

static void say_cf(const char *label, CFTypeRef obj)
{
    if (!obj) {
        printf("ovpndns: %s = <none>\n", label);
        return;
    }
    CFStringRef desc = CFCopyDescription(obj);
    char buf[2048];
    if (CFStringGetCString(desc, buf, sizeof buf, kCFStringEncodingUTF8))
        printf("ovpndns: %s = %s\n", label, buf);
    CFRelease(desc);
}

/* The DNS key of the service that currently carries the default route, e.g.
 * "State:/Network/Service/E1B2.../DNS". Caller releases. */
static CFStringRef copy_dns_key(SCDynamicStoreRef store)
{
    CFPropertyListRef global = sc_copy(store, CFSTR("State:/Network/Global/IPv4"));
    if (!global) {
        printf("ovpndns: State:/Network/Global/IPv4 is empty — no primary "
               "service, cannot place DNS\n");
        return NULL;
    }

    CFStringRef key = NULL;
    if (CFGetTypeID(global) == CFDictionaryGetTypeID()) {
        CFStringRef psid = CFDictionaryGetValue((CFDictionaryRef)global,
                                                CFSTR("PrimaryService"));
        if (psid && CFGetTypeID(psid) == CFStringGetTypeID())
            key = CFStringCreateWithFormat(NULL, NULL,
                                           CFSTR("State:/Network/Service/%@/DNS"),
                                           psid);
    }
    CFRelease(global);

    if (!key)
        printf("ovpndns: no PrimaryService in State:/Network/Global/IPv4\n");
    return key;
}

/* State:/Network/Service/<VPN_SERVICE_ID>/<leaf>. Caller releases. */
static CFStringRef vpn_key(const char *leaf)
{
    return CFStringCreateWithFormat(NULL, NULL,
                                    CFSTR("State:/Network/Service/"
                                          VPN_SERVICE_ID "/%s"),
                                    leaf);
}

static CFStringRef cfstr(const char *s)
{
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

/* A one-element CFArray, the shape configd wants for Addresses/SubnetMasks. */
static CFArrayRef one_str(const char *s)
{
    CFStringRef v = cfstr(s);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&v, 1, &kCFTypeArrayCallBacks);
    CFRelease(v);
    return a;
}

static void dict_set_str(CFMutableDictionaryRef d, CFStringRef k, const char *s)
{
    CFStringRef v = cfstr(s);
    if (v) {
        CFDictionarySetValue(d, k, v);
        CFRelease(v);
    }
}

/* Record the current value of `key` so do_down can put it back. A key with no
 * value is recorded too, with no "value" entry, which means "remove it again". */
static void backup_add(CFMutableArrayRef list, SCDynamicStoreRef store,
                       CFStringRef key)
{
    CFMutableDictionaryRef e =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(e, CFSTR("key"), key);
    CFPropertyListRef old = sc_copy(store, key);
    if (old) {
        CFDictionarySetValue(e, CFSTR("value"), old);
        CFRelease(old);
    }
    CFArrayAppendValue(list, e);
    CFRelease(e);
}

static int write_file(const char *path, const void *bytes, size_t len)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        return -1;
    ssize_t n = write(fd, bytes, len);
    close(fd);
    return (n == (ssize_t)len) ? 0 : -1;
}

static CFDataRef copy_file_data(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return NULL;
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    unsigned char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0)
        CFDataAppendBytes(data, buf, n);
    close(fd);
    return data;
}

/* ── IPv6 leak block ──────────────────────────────────────────────────────── */

/* The tunnel is IPv4-only here, but en0 keeps its native IPv6 and its own IPv6
 * default route. So while the VPN is up, anything dual-stack (and curl, Safari
 * and friends PREFER IPv6) goes straight out of the LAN, around the tunnel —
 * measured on-device: `curl -4 ifconfig.me` gave the VPN exit, `curl -6` the
 * home ISP.
 *
 * It cannot be routed into the tunnel instead: none of the servers in use push
 * IPv6, and this jailbreak's /sbin/ifconfig and /sbin/route were built without
 * INET6 ("bad keyword: inet6"), so openvpn could not configure it even if one
 * did. What can be done is to make IPv6 to the internet fail FAST, so that every
 * client falls back to IPv4 — which does go through the tunnel.
 *
 * Hence one REJECT route for 2000::/3, the whole global-unicast space. It is
 * more specific than en0's ::/0, so it wins for unscoped traffic; connect()
 * then fails at once with EHOSTUNREACH rather than timing out, and link-local
 * and ULA (LAN) IPv6 are untouched. Written straight to a PF_ROUTE socket
 * because the route(8) here cannot express it. The kernel forgets it on reboot,
 * and if a session dies without running `down` the block simply stays until
 * the next disconnect: failing closed, not open. */
static int v6_block(int on)
{
    struct {
        struct rt_msghdr hdr;
        struct sockaddr_in6 dst, gw, mask;   /* 28 bytes each, already aligned */
    } m;
    memset(&m, 0, sizeof m);

    m.hdr.rtm_msglen  = sizeof m;
    m.hdr.rtm_version = RTM_VERSION;
    m.hdr.rtm_type    = on ? RTM_ADD : RTM_DELETE;
    m.hdr.rtm_flags   = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_REJECT;
    m.hdr.rtm_addrs   = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    m.hdr.rtm_pid     = getpid();
    m.hdr.rtm_seq     = 1;

    m.dst.sin6_len = m.gw.sin6_len = m.mask.sin6_len = sizeof(struct sockaddr_in6);
    m.dst.sin6_family = m.gw.sin6_family = m.mask.sin6_family = AF_INET6;
    m.dst.sin6_addr.s6_addr[0]  = 0x20;   /* 2000:: */
    m.mask.sin6_addr.s6_addr[0] = 0xe0;   /* /3     */
    m.gw.sin6_addr.s6_addr[15]  = 1;      /* ::1    */

    int s = socket(PF_ROUTE, SOCK_RAW, 0);
    if (s < 0) {
        printf("ovpndns: IPv6 block: routing socket: %s\n", strerror(errno));
        return 1;
    }
    ssize_t n = write(s, &m, sizeof m);
    int err = (n < 0) ? errno : 0;
    close(s);

    /* Already there (a session that died without `down`) / already gone. */
    if (err == (on ? EEXIST : ESRCH))
        err = 0;
    if (err) {
        printf("ovpndns: IPv6 block %s FAILED: %s\n", on ? "on" : "off",
               strerror(err));
        return 1;
    }
    printf("ovpndns: IPv6 to the internet %s (reject route 2000::/3)\n",
           on ? "BLOCKED while connected" : "restored");
    return 0;
}

/* ── up ───────────────────────────────────────────────────────────────────── */

static void add_str(CFMutableArrayRef arr, const char *s)
{
    CFStringRef cf = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    if (cf) {
        CFArrayAppendValue(arr, cf);
        CFRelease(cf);
    }
}

/* openvpn calls its --up script as
 *     <script> <dev> <tun_mtu> <link_mtu> <local_ip> <X> <init|restart>
 * with our own "up" in front, so dev and local are argv[2] and argv[5].
 *
 * <X> is NOT always a netmask. With `topology subnet` it is, but with
 * `topology net30` or `p2p` (the default, and what e.g. vpnbook pushes) it is
 * the far end's IP, and publishing that as SubnetMasks hands configd a
 * non-contiguous garbage mask. openvpn's environment says which case this is:
 * `ifconfig_netmask` is only exported for subnet topology, and a point-to-point
 * link is a /32 on our side. The env is preferred for dev/local too, with argv
 * as the fallback. Returns 0 if dev and local were found. */
static int tunnel_params(int argc, char **argv, const char **dev,
                         const char **local, const char **mask)
{
    *dev   = getenv("dev");
    *local = getenv("ifconfig_local");
    *mask  = getenv("ifconfig_netmask");
    if (!*dev && argc > 2)   *dev = argv[2];
    if (!*local && argc > 5) *local = argv[5];
    if (!*mask)              *mask = "255.255.255.255";
    return (*dev && *local) ? 0 : -1;
}

static int do_up(SCDynamicStoreRef store, int argc, char **argv)
{
    CFMutableArrayRef servers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef domains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);

    /* openvpn exports the pushed options as foreign_option_1..N, numbered
     * contiguously from 1, each looking like "dhcp-option DNS 1.2.3.4". */
    for (int i = 1; i < 128; i++) {
        char name[32];
        snprintf(name, sizeof name, "foreign_option_%d", i);
        const char *val = getenv(name);
        if (!val)
            break;
        printf("ovpndns: %s = %s\n", name, val);

        if (strncmp(val, "dhcp-option ", 12) != 0)
            continue;
        const char *opt = val + 12;
        if (strncmp(opt, "DNS ", 4) == 0)
            add_str(servers, opt + 4);
        else if (strncmp(opt, "DNS6 ", 5) == 0)
            add_str(servers, opt + 5);
        else if (strncmp(opt, "DOMAIN ", 7) == 0)
            add_str(domains, opt + 7);
        else if (strncmp(opt, "DOMAIN-SEARCH ", 14) == 0)
            add_str(domains, opt + 14);
    }

    if (CFArrayGetCount(servers) == 0) {
        printf("ovpndns: server pushed no DNS servers — leaving resolver "
               "configuration alone\n");
        CFRelease(servers);
        CFRelease(domains);
        return 0;
    }

    const char *dev, *local, *mask;
    if (tunnel_params(argc, argv, &dev, &local, &mask) != 0) {
        printf("ovpndns: openvpn did not pass the tunnel parameters — "
               "leaving resolver configuration alone\n");
        CFRelease(servers);
        CFRelease(domains);
        return 1;
    }
    /* The tunnel's far end, as openvpn resolved it from the pushed
     * route-gateway. Only used to fill in Router, so its absence is survivable. */
    const char *gw = getenv("route_vpn_gateway");
    printf("ovpndns: tunnel %s %s/%s gateway %s\n", dev, local, mask,
           gw ? gw : "(unknown)");

    CFStringRef ipv4_key = vpn_key("IPv4");
    CFStringRef dns_key  = vpn_key("DNS");
    /* The wifi service's DNS. We overwrite it as well, so that anything still
     * holding on to the old primary asks the VPN's servers rather than the
     * LAN's — a query that fails beats a query that leaks. */
    CFStringRef old_key  = copy_dns_key(store);

    /* Save every key before touching any of them — but only the first time.
     * openvpn runs --up again after a ping-restart, and by then the store holds
     * OUR values, so a second save would overwrite the real originals with
     * them and leave `down` nothing to restore. */
    if (access(BACKUP_PATH, F_OK) == 0) {
        printf("ovpndns: %s already exists (restart) — keeping the original "
               "backup\n", BACKUP_PATH);
    } else {
        CFMutableArrayRef backup =
            CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        backup_add(backup, store, ipv4_key);
        backup_add(backup, store, dns_key);
        backup_add(backup, store, CFSTR("State:/Network/Global/DNS"));
        if (old_key)
            backup_add(backup, store, old_key);

        CFDataRef blob = CFPropertyListCreateData(NULL, backup,
                                                  kCFPropertyListXMLFormat_v1_0,
                                                  0, NULL);
        int saved = (blob && write_file(BACKUP_PATH, CFDataGetBytePtr(blob),
                                        CFDataGetLength(blob)) == 0);
        if (blob) CFRelease(blob);
        CFRelease(backup);

        if (!saved) {
            /* Without a backup, `down` could not undo any of this — refuse to
             * start rather than risk leaving the device pointed at a dead
             * tunnel. */
            printf("ovpndns: cannot write %s — refusing to change DNS\n",
                   BACKUP_PATH);
            if (old_key) CFRelease(old_key);
            CFRelease(dns_key);
            CFRelease(ipv4_key);
            CFRelease(servers);
            CFRelease(domains);
            return 1;
        }
    }

    /* 1. Publish utun0 as a service. This is what gives the resolver below an
     *    interface, and so decides where mDNSResponder pins its sockets. */
    CFMutableDictionaryRef ipv4 =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    CFArrayRef addrs = one_str(local);
    CFArrayRef masks = one_str(mask);
    CFDictionarySetValue(ipv4, CFSTR("Addresses"), addrs);
    CFDictionarySetValue(ipv4, CFSTR("SubnetMasks"), masks);
    dict_set_str(ipv4, CFSTR("InterfaceName"), dev);
    if (gw)
        dict_set_str(ipv4, CFSTR("Router"), gw);
    CFRelease(addrs);
    CFRelease(masks);

    /* 2. The resolver, under that service. */
    CFMutableDictionaryRef dns =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dns, CFSTR("ServerAddresses"), servers);
    if (CFArrayGetCount(domains) > 0)
        CFDictionarySetValue(dns, CFSTR("SearchDomains"), domains);

    /* The same resolver again, but marked SUPPLEMENTAL with an empty match
     * domain — which matches every name. This is the mechanism macOS uses for
     * VPN split-DNS, and it is how we get used without having to be the primary
     * service: configd hands mDNSResponder a match-all resolver that is still
     * attached to this service. A supplemental resolver is handed out with no
     * if_index at all, so mDNSResponder does not pin its socket and the query
     * follows the routing table into the tunnel — which is the whole fix. */
    CFMutableDictionaryRef vpn_dns = CFDictionaryCreateMutableCopy(NULL, 0, dns);
    CFArrayRef match = one_str("");
    CFDictionarySetValue(vpn_dns, CFSTR("SupplementalMatchDomains"), match);
    CFRelease(match);
    /* Order is a priority, lowest first; anything else supplemental on this
     * device will be a real domain, so a high number is still safe. */
    int order_val = 100000;
    CFNumberRef order = CFNumberCreate(NULL, kCFNumberIntType, &order_val);
    CFArrayRef orders = CFArrayCreate(NULL, (const void **)&order, 1,
                                      &kCFTypeArrayCallBacks);
    CFDictionarySetValue(vpn_dns, CFSTR("SupplementalMatchOrders"), orders);
    CFRelease(orders);
    CFRelease(order);

    /* State:/Network/Global/IPv4 is deliberately left alone: IPMonitor owns it,
     * recomputes it from the services it manages, and put en0 straight back
     * every time we claimed it. The supplemental resolver above is what makes
     * that not matter. */
    Boolean ok = sc_set(store, ipv4_key, ipv4);
    ok &= sc_set(store, dns_key, vpn_dns);
    ok &= sc_set(store, CFSTR("State:/Network/Global/DNS"), dns);
    if (old_key)
        ok &= sc_set(store, old_key, dns);

    say_cf("published service IPv4", ipv4);
    say_cf("applied DNS", vpn_dns);
    printf("ovpndns: SCDynamicStoreSetValue %s\n", ok ? "OK" : "FAILED");

    CFRelease(vpn_dns);
    CFRelease(dns);
    CFRelease(ipv4);
    if (old_key) CFRelease(old_key);
    CFRelease(dns_key);
    CFRelease(ipv4_key);
    CFRelease(servers);
    CFRelease(domains);
    return ok ? 0 : 1;
}

/* ── down ─────────────────────────────────────────────────────────────────── */

static int do_down(SCDynamicStoreRef store)
{
    CFDataRef blob = copy_file_data(BACKUP_PATH);
    if (!blob) {
        printf("ovpndns: no %s — DNS was never changed, nothing to restore\n",
               BACKUP_PATH);
        return 0;
    }

    CFPropertyListRef backup =
        CFPropertyListCreateWithData(NULL, blob, kCFPropertyListImmutable,
                                     NULL, NULL);
    CFRelease(blob);
    if (!backup || CFGetTypeID(backup) != CFArrayGetTypeID()) {
        printf("ovpndns: %s is unreadable — leaving DNS as it is\n", BACKUP_PATH);
        if (backup) CFRelease(backup);
        return 1;
    }

    /* Put every saved key back exactly as it was. Entries with no "value" are
     * ones that did not exist before us — the utun0 service keys — so those get
     * removed, leaving configd to recompute from the interfaces it owns. */
    int rc = 0;
    CFIndex n = CFArrayGetCount((CFArrayRef)backup);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef e = CFArrayGetValueAtIndex((CFArrayRef)backup, i);
        if (CFGetTypeID(e) != CFDictionaryGetTypeID())
            continue;
        CFStringRef key = CFDictionaryGetValue(e, CFSTR("key"));
        if (!key || CFGetTypeID(key) != CFStringGetTypeID())
            continue;
        CFPropertyListRef old = CFDictionaryGetValue(e, CFSTR("value"));

        say_cf("restoring key", key);
        Boolean ok = old ? sc_set(store, key, old) : sc_remove(store, key);
        if (old)
            say_cf("  restored to", old);
        else
            printf("ovpndns:   removed (did not exist before the tunnel)\n");
        if (!ok) {
            printf("ovpndns:   FAILED\n");
            rc = 1;
        }
    }

    CFRelease(backup);
    unlink(BACKUP_PATH);
    return rc;
}

/* ── show ─────────────────────────────────────────────────────────────────── */

static int do_show(SCDynamicStoreRef store)
{
    CFPropertyListRef v;

    v = sc_copy(store, CFSTR("State:/Network/Global/IPv4"));
    say_cf("State:/Network/Global/IPv4", v);
    if (v) CFRelease(v);

    v = sc_copy(store, CFSTR("State:/Network/Global/DNS"));
    say_cf("State:/Network/Global/DNS", v);
    if (v) CFRelease(v);

    CFStringRef key = copy_dns_key(store);
    if (key) {
        v = sc_copy(store, key);
        say_cf("primary service DNS", v);
        if (v) CFRelease(v);
        CFRelease(key);
    }

    /* Our own service. Global/IPv4 above will still name en0 — that is expected
     * and harmless; what matters is that the DNS here carries
     * SupplementalMatchDomains, which is what keeps it unpinned. */
    key = vpn_key("IPv4");
    v = sc_copy(store, key);
    say_cf("vpn service IPv4", v);
    if (v) CFRelease(v);
    CFRelease(key);

    key = vpn_key("DNS");
    v = sc_copy(store, key);
    say_cf("vpn service DNS", v);
    if (v) CFRelease(v);
    CFRelease(key);

    /* Not authoritative on iOS, but useful to see what configd believes. */
    CFDataRef rc = copy_file_data("/etc/resolv.conf");
    if (rc) {
        printf("ovpndns: /etc/resolv.conf =\n%.*s\n",
               (int)CFDataGetLength(rc), (const char *)CFDataGetBytePtr(rc));
        CFRelease(rc);
    } else {
        printf("ovpndns: /etc/resolv.conf unreadable\n");
    }
    return 0;
}

/* ── entry point ──────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
    /* Line buffering: stdout is openvpn's log file, shared with openvpn's own
     * writes, so flush per line to keep the log readable. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    const char *mode = (argc > 1) ? argv[1] : "show";

    /* `ovpndns v6 on|off` — the IPv6 block alone, for testing or for clearing a
     * block left behind by a session that died, from a root shell. */
    if (strcmp(mode, "v6") == 0) {
        if (argc < 3 || (strcmp(argv[2], "on") != 0 && strcmp(argv[2], "off") != 0)) {
            printf("usage: ovpndns v6 on|off\n");
            return 2;
        }
        return v6_block(strcmp(argv[2], "on") == 0);
    }

    /* Before, and independent of, the DNS work below: a resolver problem must
     * neither stop the block going up nor keep it from coming down. */
    int v6rc = 0;
    if (strcmp(mode, "up") == 0)
        v6rc = v6_block(1);
    else if (strcmp(mode, "down") == 0)
        v6rc = v6_block(0);

    if (sc_load() != 0)
        return 1;

    SCDynamicStoreRef store = sc_create(NULL, CFSTR("ovpndns"), NULL, NULL);
    if (!store) {
        printf("ovpndns: SCDynamicStoreCreate failed\n");
        return 1;
    }

    int rc;
    if (strcmp(mode, "up") == 0)
        rc = do_up(store, argc, argv);
    else if (strcmp(mode, "down") == 0)
        rc = do_down(store);
    else
        rc = do_show(store);

    CFRelease(store);
    rc |= v6rc;

    /* openvpn treats a non-zero --up exit as fatal; DNS and the IPv6 block are
     * best-effort, so the tunnel should stay up even when either failed. */
    if (rc != 0 && strcmp(mode, "up") == 0) {
        printf("ovpndns: continuing with the tunnel despite the failure above\n");
        rc = 0;
    }
    return rc;
}
