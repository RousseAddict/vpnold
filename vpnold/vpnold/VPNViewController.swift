import UIKit

/// The VPN screen: pick a config, connect, disconnect, watch the state.
///
/// Everything else — the log, the post-reinstall chore, the temporary network
/// checklist — is behind the Settings button, because none of it is needed once
/// a tunnel is up.
final class VPNViewController: UIViewController {

    private let statusLabel = UILabel()
    private let bytesLabel = UILabel()
    private weak var configButton: UIButton?
    private weak var toggleButton: UIButton?

    private var ovpnPid: Int32 = 0
    /// Set between "signal SIGTERM" and the child actually being reaped, so the
    /// button can say so instead of offering to connect again mid-teardown.
    private var stopping = false
    private var tailTimer: Timer?
    private var logShown = 0        // bytes of openvpn.log already displayed
    private var shownCrashReport = false

    private let mgmt = ManagementClient()
    private var mgmtRetryTimer: Timer?
    private var mgmtRetries = 0

    private var logPath: String { NSTemporaryDirectory() + "openvpn.log" }
    private var openvpnBin: String { Bundle.main.bundlePath + "/openvpn" }
    private var ovpnrootBin: String { Bundle.main.bundlePath + "/ovpnroot" }
    private var ovpndnsBin: String { Bundle.main.bundlePath + "/ovpndns" }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "vpnold"
        view.backgroundColor = UIColor.black

        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Settings", style: .plain,
                            target: self, action: #selector(showSettings))

        let pad: CGFloat = 12
        let w = view.bounds.width - 2 * pad
        var y: CGFloat = 24

        let cfg = makeButton("Config: -", frame: CGRect(x: pad, y: y, width: w, height: 44))
        cfg.addTarget(self, action: #selector(chooseConfig), for: .touchUpInside)
        view.addSubview(cfg)
        configButton = cfg
        y += 44 + pad * 2

        // One button, not two: "stopped" and "running" are the only states the
        // user acts on, and offering the wrong one is how you kill a tunnel by
        // accident.
        let toggle = makeButton("Connect", frame: CGRect(x: pad, y: y, width: w, height: 64))
        toggle.titleLabel?.font = UIFont.boldSystemFont(ofSize: 22)
        toggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        view.addSubview(toggle)
        toggleButton = toggle
        y += 64 + pad * 2

        for label in [statusLabel, bytesLabel] {
            label.frame = CGRect(x: pad, y: y, width: w, height: 20)
            label.font = UIFont(name: "Courier-Bold", size: 13)
            label.textColor = UIColor(white: 0.75, alpha: 1)
            label.backgroundColor = UIColor.clear
            label.autoresizingMask = [.flexibleWidth]
            view.addSubview(label)
            y += 22
        }
        statusLabel.text = "state: idle"
        bytesLabel.text = "in: -   out: -"

        wireManagement()
        refreshConfigButton()
        refreshToggleButton()
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
        btn.setTitleColor(UIColor.white, for: .normal)
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

    @objc private func showSettings() {
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    // MARK: - config selection

    /// Keeps the button title in step with the current selection. The list is
    /// re-read from disk each time, so configs dropped in over SSH show up
    /// without reinstalling.
    private func refreshConfigButton() {
        let name = (ConfigStore.selected as NSString?)?.lastPathComponent
        configButton?.setTitle("Config: \(name ?? "none found")", for: .normal)
    }

    @objc private func chooseConfig() {
        let count = ConfigStore.available().count
        ConfigPickerVC.present(from: self) { [weak self] path in
            guard let self = self else { return }
            self.refreshConfigButton()
            RunLog.line("[ovpn] config set to \(path)")
        }
        if count == 0 { RunLog.line("[ovpn] no .ovpn files found — see the list of paths.") }
    }

    // MARK: - openvpn process

    private func refreshToggleButton() {
        let title: String
        let colour: UIColor
        if stopping {
            title = "Disconnecting..."
            colour = UIColor(white: 0.22, alpha: 1)
        } else if ovpnPid != 0 {
            title = "Disconnect"
            colour = UIColor(red: 0.45, green: 0.12, blue: 0.12, alpha: 1)
        } else {
            title = "Connect"
            colour = UIColor(red: 0.12, green: 0.38, blue: 0.16, alpha: 1)
        }
        toggleButton?.setTitle(title, for: .normal)
        toggleButton?.backgroundColor = colour
    }

    @objc private func toggleTapped() {
        guard !stopping else { return }
        if ovpnPid == 0 { start() } else { stop() }
    }

    private func start() {
        guard let cfg = ConfigStore.selected else {
            statusLabel.text = "state: no .ovpn config"
            RunLog.line("[ovpn] no .ovpn file found. Put one in the app bundle,")
            RunLog.line("       ~/Documents, or /var/mobile/Documents.")
            return
        }
        RunLog.line("[ovpn] config: \(cfg)")
        let pid = ovpn_spawn(ovpnrootBin, openvpnBin, cfg, ovpndnsBin, logPath)
        if pid <= 0 {
            statusLabel.text = "state: spawn failed"
            RunLog.line("[ovpn] spawn failed: errno \(-pid) (\(String(cString: strerror(-pid))))")
            RunLog.line("       run Settings → Fix permissions first.")
            return
        }
        ovpnPid = pid
        logShown = 0   // ovpn_spawn re-creates the log with O_TRUNC
        RunLog.line("[ovpn] spawned pid \(pid); tailing log...")
        statusLabel.text = "state: starting..."
        refreshToggleButton()
        tailTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                         selector: #selector(tailLog),
                                         userInfo: nil, repeats: true)
        startManagement()
    }

    private func stop() {
        guard ovpnPid != 0 else { return }
        if mgmt.isOpen {
            // Clean shutdown through the management interface: openvpn runs its
            // normal exit path and removes the routes it installed.
            RunLog.line("[mgmt] signal SIGTERM")
            mgmt.send("signal SIGTERM")
        } else {
            _ = ovpn_kill(ovpnPid)
            RunLog.line("[ovpn] SIGTERM sent to pid \(ovpnPid)")
        }
        // Deliberately keep tailing and keep ovpnPid set. Everything that
        // matters on the way out — route deletion, and the `ovpndns down` that
        // puts the resolver back — is logged AFTER this point, and tailLog() is
        // what reaps the child. Tearing all that down here hid the entire
        // shutdown and left openvpn as a zombie.
        stopping = true
        statusLabel.text = "state: stopping..."
        refreshToggleButton()
    }

    /// Appends only what is new in openvpn.log, so the app's own [ovpn]/[mgmt]
    /// messages stay interleaved instead of being overwritten, then reports the
    /// child's exit if it died.
    @objc private func tailLog() {
        if let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let ns = text as NSString
            if ns.length > logShown {
                RunLog.append(ns.substring(from: logShown))
                logShown = ns.length
            }
        }

        guard ovpnPid != 0 else { return }
        var code: Int32 = 0
        guard ovpn_wait(ovpnPid, &code) == 1 else { return }

        RunLog.line("[ovpn] process exited, status \(code)")
        if code == 3 || code == 4 {
            RunLog.line("       ovpnroot is not setuid-root — run Settings → Fix permissions.")
        }
        ovpnPid = 0
        stopping = false
        tailTimer?.invalidate()
        tailTimer = nil
        stopManagement()
        statusLabel.text = "state: exited (\(code))"
        bytesLabel.text = "in: -   out: -"
        refreshToggleButton()
    }

    // MARK: - management interface

    private func wireManagement() {
        mgmt.onOpenChange = { [weak self] open in
            guard let self = self else { return }
            if open {
                self.mgmtRetryTimer?.invalidate()
                self.mgmtRetryTimer = nil
                RunLog.line("[mgmt] connected to 127.0.0.1:7505")
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
            self?.bytesLabel.text = "in: \(VPNViewController.human(bin))"
                                  + "   out: \(VPNViewController.human(bout))"
        }
        mgmt.onLine = { line in
            // Only surface management chatter that is not already in the log file.
            if line.hasPrefix("SUCCESS:") || line.hasPrefix("ERROR:") || line.hasPrefix("[mgmt]") {
                RunLog.line(line)
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
            RunLog.line("[mgmt] gave up connecting to 127.0.0.1:7505")
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

    private static func human(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }
}
