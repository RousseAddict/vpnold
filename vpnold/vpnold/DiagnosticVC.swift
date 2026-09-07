import UIKit

// M2/M4 spike UI: run the utun probe, launch the embedded openvpn, and drive it
// over its management socket (state + byte counters + clean disconnect), showing
// everything on screen so no SSH is needed on the device.
final class DiagnosticVC: UIViewController, UIAlertViewDelegate {

    /// `su` under a pty must not run on the main thread. (.global() is iOS 8+.)
    private static let rootQueue = DispatchQueue(label: "vpnold.root")

    private let log = UITextView()
    private let uuidLabel = UILabel()
    private let statusLabel = UILabel()
    private let bytesLabel = UILabel()
    private var ovpnPid: Int32 = 0
    private var tailTimer: Timer?
    private var logShown = 0        // bytes of openvpn.log already displayed
    private var shownCrashReport = false

    private let mgmt = ManagementClient()
    private var mgmtRetryTimer: Timer?
    private var mgmtRetries = 0

    private var logPath: String { NSTemporaryDirectory() + "openvpn.log" }
    private var openvpnBin: String { Bundle.main.bundlePath + "/openvpn" }
    private var ovpnrootBin: String { Bundle.main.bundlePath + "/ovpnroot" }

    /// The `/var/mobile/Applications/<UUID>/` directory name. Changes on every
    /// reinstall, and both helper binaries must be setuid-root again after each
    /// one — so show it on screen rather than making the user hunt for it.
    private var appUUID: String {
        ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let b = view.bounds
        let btnH: CGFloat = 44
        let pad: CGFloat = 8
        var y: CGFloat = 24

        uuidLabel.frame = CGRect(x: pad, y: y, width: b.width - 2 * pad, height: 30)
        uuidLabel.font = UIFont(name: "Courier", size: 10)
        uuidLabel.textColor = UIColor(white: 0.7, alpha: 1)
        uuidLabel.numberOfLines = 2
        uuidLabel.autoresizingMask = [.flexibleWidth]
        uuidLabel.text = "app dir: \(appUUID)"
        view.addSubview(uuidLabel)
        y += 30 + pad

        addButtonRow([("Probe utun", #selector(runProbe)),
                      ("Fix perms (root)", #selector(fixPermissions))], y: y, height: btnH)
        y += btnH + pad
        addButtonRow([("Run OpenVPN", #selector(runOpenVPN))], y: y, height: btnH)
        y += btnH + pad
        addButtonRow([("Stop", #selector(stopOpenVPN))], y: y, height: btnH)
        y += btnH + pad

        for label in [statusLabel, bytesLabel] {
            label.frame = CGRect(x: pad, y: y, width: b.width - 2 * pad, height: 18)
            label.font = UIFont(name: "Courier-Bold", size: 12)
            label.textColor = .white
            label.autoresizingMask = [.flexibleWidth]
            view.addSubview(label)
            y += 20
        }
        statusLabel.text = "state: idle"
        bytesLabel.text = "in: -   out: -"

        y += pad
        let top = y
        log.frame = CGRect(x: pad, y: top, width: b.width - 2 * pad, height: b.height - top - pad)
        log.isEditable = false
        log.backgroundColor = UIColor(white: 0.08, alpha: 1)
        log.textColor = UIColor(red: 0.4, green: 1, blue: 0.4, alpha: 1)
        log.font = UIFont(name: "Courier", size: 11)
        log.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(log)

        wireManagement()

        append("vpnold M4 diagnostic ready.")
        append("openvpn: \(openvpnBin)")
        append("Tap 'Probe utun' first, then 'Run OpenVPN'.")
    }

    private func addButtonRow(_ items: [(String, Selector)], y: CGFloat, height: CGFloat) {
        let pad: CGFloat = 8
        let total = view.bounds.width - 2 * pad
        let w = (total - pad * CGFloat(items.count - 1)) / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            let btn = makeButton(item.0, frame: CGRect(x: pad + CGFloat(i) * (w + pad),
                                                       y: y, width: w, height: height))
            btn.addTarget(self, action: item.1, for: .touchUpInside)
            view.addSubview(btn)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CrashReport.stage("ui-visible")
        guard !shownCrashReport, let report = CrashReport.takeReport() else { return }
        shownCrashReport = true
        LogViewController.present(from: self, text: report,
                                  banner: "The previous run crashed. Its log follows — tap Copy.")
    }

    private func makeButton(_ title: String, frame: CGRect) -> UIButton {
        // .custom, not .system: on iOS 6 `.system` is UIButtonTypeRoundedRect,
        // which draws a white bezel image on top of backgroundColor — a white
        // title on it is invisible.
        let btn = UIButton(type: .custom)
        btn.frame = frame
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = UIColor(white: 0.22, alpha: 1)
        btn.setTitleColor(.white, for: .normal)
        btn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.titleLabel?.minimumScaleFactor = 0.7
        btn.layer.borderColor = UIColor(white: 0.45, alpha: 1).cgColor
        btn.layer.borderWidth = 1
        btn.layer.cornerRadius = 6
        btn.autoresizingMask = [.flexibleWidth]
        return btn
    }

    private func append(_ s: String) { appendRaw(s + "\n") }

    private func appendRaw(_ s: String) {
        log.text = (log.text ?? "") + s
        let end = NSRange(location: (log.text as NSString).length, length: 0)
        log.scrollRangeToVisible(end)
    }

    @objc private func runProbe() {
        var buf = [CChar](repeating: 0, count: 256)
        let rc = utun_probe(&buf, 256)
        let msg = String(cString: buf)
        append("[probe] rc=\(rc): \(msg)")
    }

    // MARK: - setuid-root helpers (replaces the manual SSH chown/chmod)

    @objc private func fixPermissions() {
        CrashReport.stage("fix-perms: tapped")
        // Built property-by-property on purpose. The convenience initializer
        // UIAlertView(title:message:delegate:cancelButtonTitle:otherButtonTitles:)
        // lives in the Swift UIKit *overlay* (libswiftUIKit.dylib); calling it
        // traps in dyld_stub_binder on the 5.1.5 runtime we ship, because a
        // symbol it binds lazily is not there. Everything below is a plain
        // objc_msgSend from this binary, so no overlay code is involved.
        let alert = UIAlertView()
        alert.title = "Root password"
        alert.message = "su root — make openvpn + ovpnroot setuid-root in\n\(appUUID)"
        alert.delegate = self
        alert.alertViewStyle = .secureTextInput
        alert.addButton(withTitle: "Cancel")
        alert.cancelButtonIndex = 0
        alert.addButton(withTitle: "Run")
        CrashReport.stage("fix-perms: alert built")
        alert.show()
        CrashReport.stage("fix-perms: alert shown")
    }

    private func applyPermissions(password: String) {
        // bundlePath is /var/mobile/Applications/<UUID>/vpnold.app — no spaces
        // or quotes, and it comes from the OS, not from user input.
        let app = Bundle.main.bundlePath
        let cmd = "chown root:wheel '\(app)/openvpn' '\(app)/ovpnroot'"
                + " && chmod 4755 '\(app)/openvpn' '\(app)/ovpnroot'"
                + " && ls -l '\(app)/openvpn' '\(app)/ovpnroot'"
        append("[perm] su root: chown root:wheel + chmod 4755")

        DiagnosticVC.rootQueue.async {
            var out = [CChar](repeating: 0, count: 4096)
            CrashReport.stage("fix-perms: forkpty su")
            // The password goes to su over a pty, never on the command line.
            let rc = run_as_root(password, cmd, &out, 4096)
            CrashReport.stage("fix-perms: su returned \(rc)")
            let text = String(cString: out)
            DispatchQueue.main.async {
                for line in text.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { self.append("[perm] " + t) }
                }
                switch rc {
                case 0:   self.append("[perm] OK — expect -rwsr-xr-x root wheel above.")
                case 127: self.append("[perm] no `su` at /usr/bin/su or /bin/su.")
                default:  self.append("[perm] failed (rc \(rc)) — wrong password?")
                }
            }
        }
    }

    private func findConfig() -> String? {
        let candidates = [
            Bundle.main.bundlePath + "/test.ovpn",
            NSHomeDirectory() + "/Documents/test.ovpn",
            "/var/mobile/Documents/test.ovpn",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - openvpn process

    @objc private func runOpenVPN() {
        guard ovpnPid == 0 else { append("[ovpn] already running (pid \(ovpnPid))"); return }
        guard let cfg = findConfig() else {
            append("[ovpn] no test.ovpn found. Put it in the app bundle,")
            append("       ~/Documents, or /var/mobile/Documents.")
            return
        }
        append("[ovpn] config: \(cfg)")
        let pid = ovpn_spawn(ovpnrootBin, openvpnBin, cfg, logPath)
        if pid <= 0 {
            append("[ovpn] spawn failed: errno \(-pid) (\(String(cString: strerror(-pid))))")
            append("       did you setuid-root ovpnroot? see instructions.")
            return
        }
        ovpnPid = pid
        logShown = 0   // ovpn_spawn re-creates the log with O_TRUNC
        append("[ovpn] spawned pid \(pid); tailing log...")
        tailTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                         selector: #selector(tailLog),
                                         userInfo: nil, repeats: true)
        startManagement()
    }

    /// Appends only what is new in openvpn.log, so the app's own [ovpn]/[mgmt]
    /// messages stay interleaved instead of being overwritten, then reports the
    /// child's exit if it died.
    @objc private func tailLog() {
        if let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let ns = text as NSString
            if ns.length > logShown {
                appendRaw(ns.substring(from: logShown))
                logShown = ns.length
            }
        }

        guard ovpnPid != 0 else { return }
        var code: Int32 = 0
        guard ovpn_wait(ovpnPid, &code) == 1 else { return }

        append("[ovpn] process exited, status \(code)")
        if code == 3 || code == 4 {
            append("       ovpnroot is not setuid-root — as root on-device:")
            append("       cd /var/mobile/Applications/\(appUUID)/vpnold.app")
            append("       chown root:wheel openvpn ovpnroot")
            append("       chmod 4755 openvpn ovpnroot")
        }
        ovpnPid = 0
        tailTimer?.invalidate()
        tailTimer = nil
        stopManagement()
        statusLabel.text = "state: exited (\(code))"
    }

    @objc private func stopOpenVPN() {
        guard ovpnPid != 0 else { return }
        if mgmt.isOpen {
            // Clean shutdown through the management interface: openvpn runs its
            // normal exit path and removes the routes it installed.
            append("[mgmt] signal SIGTERM")
            mgmt.send("signal SIGTERM")
        } else {
            _ = ovpn_kill(ovpnPid)
            append("[ovpn] SIGTERM sent to pid \(ovpnPid)")
        }
        ovpnPid = 0
        tailTimer?.invalidate()
        tailTimer = nil
        stopManagement()
        statusLabel.text = "state: idle"
        bytesLabel.text = "in: -   out: -"
    }

    // MARK: - management interface

    private func wireManagement() {
        mgmt.onOpenChange = { [weak self] open in
            guard let self = self else { return }
            if open {
                self.mgmtRetryTimer?.invalidate()
                self.mgmtRetryTimer = nil
                self.append("[mgmt] connected to 127.0.0.1:7505")
                self.mgmt.requestCurrentState() // where it is right now
                self.mgmt.send("state on")      // real-time >STATE: notifications
                self.mgmt.send("bytecount 1")   // >BYTECOUNT: every second
            }
        }
        mgmt.onState = { [weak self] state, detail in
            self?.statusLabel.text = detail.isEmpty ? "state: \(state)"
                                                    : "state: \(state)  \(detail)"
        }
        mgmt.onByteCount = { [weak self] bin, bout in
            self?.bytesLabel.text = "in: \(Self.human(bin))   out: \(Self.human(bout))"
        }
        mgmt.onLine = { [weak self] line in
            // Only surface management chatter that is not already in the log file.
            if line.hasPrefix("SUCCESS:") || line.hasPrefix("ERROR:") || line.hasPrefix("[mgmt]") {
                self?.append(line)
            }
        }
    }

    /// openvpn opens its management socket shortly after launch, so retry.
    private func startManagement() {
        mgmtRetries = 0
        mgmtRetryTimer?.invalidate()
        mgmtRetryTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                              selector: #selector(retryManagement),
                                              userInfo: nil, repeats: true)
    }

    @objc private func retryManagement() {
        guard !mgmt.isOpen else { return }
        mgmtRetries += 1
        if mgmtRetries > 15 {
            append("[mgmt] gave up connecting to 127.0.0.1:7505")
            mgmtRetryTimer?.invalidate()
            mgmtRetryTimer = nil
            return
        }
        mgmt.open()
    }

    private func stopManagement() {
        mgmtRetryTimer?.invalidate()
        mgmtRetryTimer = nil
        mgmt.close()
    }

    // MARK: - UIAlertViewDelegate

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        CrashReport.stage("fix-perms: alert button \(buttonIndex)")
        guard buttonIndex != alertView.cancelButtonIndex,
              let pw = alertView.textField(at: 0)?.text, !pw.isEmpty else { return }
        applyPermissions(password: pw)
    }

    private static func human(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }
}
