import Foundation

/// TEMPORARY — the on-device verification checklist, wired to one button.
///
/// Everything the "Net check" button does lives here and in netdiag.c, so the
/// whole feature can be removed by deleting these two files plus the button row
/// and the two declarations in the bridging header.
///
/// Each step runs off the main thread (popen and connect both block) and reports
/// back on the main thread. Results are emitted as one block per step rather
/// than line by line: every append re-lays-out the whole UITextView, and once
/// openvpn's --verb 4 output is in there that costs enough to visibly freeze the
/// UI for a hundred separate appends.
enum NetDiagnostics {

    /// Its own queue: `.global()` is iOS 8+, and each new queue costs an OS
    /// thread, so there is exactly one, created once.
    private static let queue = DispatchQueue(label: "vpnold.netdiag")

    private enum Step {
        /// A shell command, run via popen.
        case shell(title: String, command: String)
        /// Resolve + TCP connect, optionally fetching an HTTP path. `hostHeader`
        /// overrides the HTTP Host: header so `host` can be a literal IP.
        case probe(title: String, host: String, hostHeader: String?,
                   port: Int32, path: String?)
        /// Raw DNS query straight to a server, bypassing mDNSResponder.
        /// `iface` pins the socket to one interface (UDP only).
        case dns(title: String, server: String, name: String,
                 tcp: Bool, iface: String?)

        var title: String {
            switch self {
            case .shell(let t, _):          return t
            case .probe(let t, _, _, _, _): return t
            case .dns(let t, _, _, _, _):   return t
            }
        }
    }

    private static func steps() -> [Step] {
        let dns = Bundle.main.bundlePath + "/ovpndns"
        return [
            .shell(title: "1. routes (0/1 + 128.0/1 via 10.8.0.1 = full tunnel)",
                   command: "netstat -rn -f inet | head -20"),
            .shell(title: "2. utun interface",
                   command: "ifconfig utun0"),
            .shell(title: "3. resolver as configd sees it",
                   command: "'\(dns)' show"),
            // The resolver list as a CONSUMER sees it, not as configd stores
            // it: scutil asks dns_configuration_copy(), the same API
            // mDNSResponder uses, so it shows which resolvers actually made it
            // through and what interface each is scoped to. Only present if
            // the jailbreak shipped it.
            .shell(title: "3b. resolvers as a consumer sees them (scutil)",
                   command: "scutil --dns 2>&1 | head -40"),
            .shell(title: "4. openvpn process",
                   command: "ps ax | grep [o]penvpn"),
            .shell(title: "5. dns backup file (present only while connected)",
                   command: "ls -l /var/tmp/ovpndns-backup.plist"),
            // No DNS involved, so this isolates "do packets get out at all"
            // from "does name resolution work".
            .probe(title: "6. egress to a literal IP, no DNS",
                   host: "1.1.1.1", hostHeader: nil,
                   port: 80, path: "/cdn-cgi/trace"),
            // Same thing against a host that is not Cloudflare. Step 6 connects
            // and is then closed with no data, but DNS over TCP to the same
            // Cloudflare IP works, so TCP through the tunnel is fine and the
            // empty reply has to be about that host. This says whether ordinary
            // HTTP works — and it reads back our exit IP by literal address, so
            // it still answers that even while the system resolver is wedged.
            .probe(title: "7. HTTP to a non-Cloudflare IP + exit IP, no DNS",
                   host: "34.160.111.145", hostHeader: "ifconfig.me",
                   port: 80, path: "/ip"),
            // 7-9 are the discriminator. All three use a socket created after
            // the tunnel came up, so they carry the right source address.
            // If these answer but step 10 does not, the tunnel is fine and
            // mDNSResponder is stuck; if none answer, UDP is not crossing the
            // tunnel; if only the LAN one answers, the tunnel drops UDP.
            .dns(title: "8. DNS direct to the pushed server (via tunnel)",
                 server: "94.140.14.14", name: "example.com",
                 tcp: false, iface: nil),
            .dns(title: "9. DNS direct to a different server (via tunnel)",
                 server: "1.1.1.1", name: "example.com",
                 tcp: false, iface: nil),
            .dns(title: "10. CONTROL: DNS to the LAN router (does not use tunnel)",
                 server: "192.168.0.1", name: "example.com",
                 tcp: false, iface: nil),
            // Kept as the standing proof that TCP data crosses the tunnel: a
            // full handshake plus a request and a reply, to a server 9 already
            // showed answers.
            .dns(title: "11. same query over TCP/53 (TCP data through tunnel)",
                 server: "1.1.1.1", name: "example.com",
                 tcp: true, iface: nil),
            // 12-13 reproduce what mDNSResponder is believed to be doing. Its
            // DNS entry lives under the en0 service and PrimaryInterface is
            // still en0, so Darwin scopes its queries to en0 with IP_BOUND_IF —
            // which overrides `0/1 via utun0` and sends them out wifi instead.
            // Step 8 is this exact query unpinned and it works, so if 12 fails
            // the pinning is the whole difference, and that is the bug.
            .dns(title: "12. pushed DNS server, pinned to en0 (what the resolver does)",
                 server: "94.140.14.14", name: "example.com",
                 tcp: false, iface: "en0"),
            // Proves IP_BOUND_IF itself works, so a failure at 12 means the
            // path is bad, not that the probe is broken.
            .dns(title: "13. CONTROL: LAN router, pinned to en0",
                 server: "192.168.0.1", name: "example.com",
                 tcp: false, iface: "en0"),
            // Goes through mDNSResponder, i.e. the normal system resolver.
            // Everything above bypasses it, so this is the only step that can
            // fail on the resolver rather than on the network.
            .probe(title: "14. system resolver (mDNSResponder)",
                   host: "ifconfig.me", hostHeader: nil, port: 80, path: "/ip"),
            // 15-16 choose between the two non-leaky fixes for the scoping bug.
            //
            // 15: is loopback exempt from en0 scoping? Nothing listens on
            // 127.0.0.1:53, so the useful outcomes are both "failures":
            //   "send: Can't assign requested address" = scoping killed it, so
            //       pointing the resolver at a local forwarder would fail too.
            //   "recv=-1 Connection refused" = the packet DID reach lo0, so a
            //       forwarder on 127.0.0.1:53 is viable.
            .dns(title: "15. loopback pinned to en0 (is a local forwarder viable?)",
                 server: "127.0.0.1", name: "example.com",
                 tcp: false, iface: "en0"),
            // 16: if the resolver were scoped to utun0 instead of en0, would it
            // work? A reply here means making utun0 the primary service fixes
            // this properly, with no DNS leaving the tunnel.
            .dns(title: "16. pushed DNS server pinned to utun0 (is the utun0 fix viable?)",
                 server: "94.140.14.14", name: "example.com",
                 tcp: false, iface: "utun0"),
        ]
    }

    /// Runs the checklist. `emit` and `finished` are always called on the main
    /// thread; `emit` gets a block of text that already ends in a newline.
    static func run(emit: @escaping (String) -> Void,
                    finished: @escaping () -> Void) {
        let all = steps()
        emit("[net] ---- check start (\(all.count) steps) ----\n")

        queue.async {
            for step in all {
                DispatchQueue.main.async { emit("[net] " + step.title + "\n") }

                let text: String
                switch step {
                case .shell(_, let command):
                    var buf = [CChar](repeating: 0, count: 8192)
                    let rc = run_cmd(command, &buf, 8192)
                    let s = String(cString: buf)
                    text = s.isEmpty ? "(no output, rc \(rc))" : s
                case .probe(_, let host, let hostHeader, let port, let path):
                    var buf = [CChar](repeating: 0, count: 16384)
                    _ = net_probe(host, hostHeader, port, path, &buf, 16384)
                    let s = String(cString: buf)
                    text = s.isEmpty ? "(no output)" : s
                case .dns(_, let server, let name, let tcp, let iface):
                    var buf = [CChar](repeating: 0, count: 4096)
                    _ = dns_probe(server, name, tcp ? 1 : 0, iface, &buf, 4096)
                    let s = String(cString: buf)
                    text = s.isEmpty ? "(no output)" : s
                }

                var block = ""
                for line in text.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { block += "      " + t + "\n" }
                }
                DispatchQueue.main.async { emit(block) }
            }
            DispatchQueue.main.async {
                emit("[net] ---- check done ----\n")
                finished()
            }
        }
    }
}
