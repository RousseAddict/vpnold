import UIKit

/// The VPN screen: pick a config, connect, disconnect, watch the state.
///
/// Everything else — the log, the post-install root chore, the setup guide, the
/// temporary network checklist — is behind the Settings button, because none of
/// it is needed once a tunnel is up.
final class VPNViewController: UIViewController {

    /// What the user is shown, as opposed to the dozen states openvpn reports.
    /// Only the colour and the headline differ; openvpn's own wording is kept
    /// underneath, so nothing is hidden, just ranked.
    private enum Phase {
        case idle, connecting, connected, stopping, failed

        var headline: String {
            switch self {
            case .idle:       return "Not connected"
            case .connecting: return "Connecting"
            case .connected:  return "Connected"
            case .stopping:   return "Disconnecting"
            case .failed:     return "Disconnected"
            }
        }

        var colour: UIColor {
            switch self {
            case .idle:       return UIColor(white: 0.45, alpha: 1)
            case .connecting: return UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1)
            case .connected:  return UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
            case .stopping:   return UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1)
            case .failed:     return UIColor(red: 0.9, green: 0.35, blue: 0.3, alpha: 1)
            }
        }
    }

    private weak var configButton: UIButton?
    private weak var toggleButton: UIButton?
    private let stateDot = UIView()
    private let stateLabel = UILabel()
    private let detailLabel = UILabel()
    private let inValue = UILabel()
    private let outValue = UILabel()

    private var ovpnPid: Int32 = 0
    /// Set between "signal SIGTERM" and the child actually being reaped, so the
    /// button can say so instead of offering to connect again mid-teardown.
    private var stopping = false
    private var tailTimer: Timer?
    private var logShown = 0        // bytes of openvpn.log already displayed
    private var shownCrashReport = false
    private var shownOnboarding = false

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
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Settings", style: .plain,
                            target: self, action: #selector(showSettings))

        let pad: CGFloat = 12
        let w = view.bounds.width - 2 * pad
        var y: CGFloat = 20

        let cfg = makeButton("Config: -", frame: CGRect(x: pad, y: y, width: w, height: 44))
        cfg.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        cfg.addTarget(self, action: #selector(chooseConfig), for: .touchUpInside)
        view.addSubview(cfg)
        configButton = cfg
        y += 44 + pad

        // One button, not two: "stopped" and "running" are the only states the
        // user acts on, and offering the wrong one is how you kill a tunnel by
        // accident.
        let toggle = makeButton("Connect", frame: CGRect(x: pad, y: y, width: w, height: 60))
        toggle.titleLabel?.font = UIFont.boldSystemFont(ofSize: 21)
        toggle.layer.borderWidth = 0
        toggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        view.addSubview(toggle)
        toggleButton = toggle
        y += 60 + pad

        y = buildStatusCard(x: pad, y: y, width: w) + pad
        _ = buildTrafficCard(x: pad, y: y, width: w)

        wireManagement()
        refreshConfigButton()
        setPhase(.idle, detail: "Pick a config, then Connect.")
        refreshToggleButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CrashReport.stage("ui-visible")

        if !shownCrashReport, let report = CrashReport.takeReport() {
            shownCrashReport = true
            LogViewController.present(from: self, text: report,
                                      banner: "The previous run crashed. Its log follows — tap Copy.")
            return
        }
        // After the crash log, not instead of it: a crash on the previous run is
        // the more urgent of the two, and both are modal.
        if !shownOnboarding && OnboardingVC.shouldShow {
            shownOnboarding = true
            present(OnboardingVC(), animated: true, completion: nil)
            return
        }
        refreshConfigButton()
    }

    // MARK: - chrome

    private func makeButton(_ title: String, frame: CGRect) -> UIButton {
        // .custom, not .system: on iOS 6 `.system` is UIButtonTypeRoundedRect,
        // which draws a white bezel image on top of backgroundColor — a white
        // title on it is invisible.
        let btn = UIButton(type: .custom)
        btn.frame = frame
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = UIColor(white: 0.16, alpha: 1)
        btn.setTitleColor(UIColor.white, for: .normal)
        btn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.titleLabel?.minimumScaleFactor = 0.7
        btn.layer.borderColor = UIColor(white: 0.3, alpha: 1).cgColor
        btn.layer.borderWidth = 1
        btn.layer.cornerRadius = 6
        btn.autoresizingMask = [.flexibleWidth]
        return btn
    }

    private func makeCard(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> UIView {
        let card = UIView(frame: CGRect(x: x, y: y, width: width, height: height))
        card.autoresizingMask = [.flexibleWidth]
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 8
        view.addSubview(card)
        return card
    }

    /// Returns the y of its bottom edge.
    private func buildStatusCard(x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let height: CGFloat = 78
        let card = makeCard(x: x, y: y, width: width, height: height)

        stateDot.frame = CGRect(x: 16, y: 24, width: 12, height: 12)
        stateDot.layer.cornerRadius = 6
        card.addSubview(stateDot)

        stateLabel.frame = CGRect(x: 38, y: 16, width: width - 54, height: 28)
        stateLabel.autoresizingMask = [.flexibleWidth]
        stateLabel.backgroundColor = UIColor.clear
        stateLabel.font = UIFont.boldSystemFont(ofSize: 20)
        stateLabel.textColor = UIColor.white
        card.addSubview(stateLabel)

        detailLabel.frame = CGRect(x: 16, y: 46, width: width - 32, height: 22)
        detailLabel.autoresizingMask = [.flexibleWidth]
        detailLabel.backgroundColor = UIColor.clear
        detailLabel.font = UIFont(name: "Courier", size: 11)
        detailLabel.textColor = UIColor(white: 0.55, alpha: 1)
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.7
        card.addSubview(detailLabel)

        return y + height
    }

    private func buildTrafficCard(x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let height: CGFloat = 62
        let card = makeCard(x: x, y: y, width: width, height: height)
        let half = width / 2

        let divider = UIView(frame: CGRect(x: half, y: 12, width: 1, height: height - 24))
        divider.backgroundColor = UIColor(white: 0.22, alpha: 1)
        card.addSubview(divider)

        addMeter(caption: "DOWNLOAD", value: inValue,
                 frame: CGRect(x: 0, y: 12, width: half, height: height - 24), in: card)
        addMeter(caption: "UPLOAD", value: outValue,
                 frame: CGRect(x: half, y: 12, width: half, height: height - 24), in: card)
        return y + height
    }

    private func addMeter(caption: String, value: UILabel, frame: CGRect, in card: UIView) {
        let title = UILabel(frame: CGRect(x: frame.minX, y: frame.minY,
                                          width: frame.width, height: 14))
        title.backgroundColor = UIColor.clear
        title.textAlignment = .center
        title.font = UIFont.boldSystemFont(ofSize: 10)
        title.textColor = UIColor(white: 0.45, alpha: 1)
        title.text = caption
        card.addSubview(title)

        value.frame = CGRect(x: frame.minX, y: frame.minY + 16,
                             width: frame.width, height: 22)
        value.backgroundColor = UIColor.clear
        value.textAlignment = .center
        value.font = UIFont(name: "Courier-Bold", size: 16)
        value.textColor = UIColor.white
        value.text = "—"
        card.addSubview(value)
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

    // MARK: - status

    private func setPhase(_ phase: Phase, detail: String) {
        stateDot.backgroundColor = phase.colour
        stateLabel.text = phase.headline
        detailLabel.text = detail
        showShield(phase == .connected)
    }

    /// A shield in the navigation bar while the tunnel is up, so "am I
    /// protected?" is answerable at a glance from anywhere in the app.
    ///
    /// The *system* status bar cannot be used for this: iOS only puts a VPN
    /// badge there for tunnels it owns via NetworkExtension, which is iOS 8+ and
    /// does not exist here, and no app may draw into the status bar itself.
    private func showShield(_ on: Bool) {
        guard on else {
            navigationItem.leftBarButtonItem = nil
            return
        }
        guard navigationItem.leftBarButtonItem == nil else { return }
        let iv = UIImageView(image: UIImage(named: "ShieldBar"))
        iv.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: iv)
    }

    /// openvpn reports a dozen states on the way up; they are all "connecting"
    /// to anyone who is not debugging, so the raw name goes in the detail line.
    private func phase(forOpenVPNState state: String) -> Phase {
        switch state {
        case "CONNECTED": return .connected
        case "EXITING":   return .stopping
        default:          return .connecting
        }
    }

    private func clearTraffic() {
        inValue.text = "—"
        outValue.text = "—"
    }

    // MARK: - openvpn process

    private func refreshToggleButton() {
        let title: String
        let colour: UIColor
        if stopping {
            title = "Disconnecting..."
            colour = UIColor(white: 0.18, alpha: 1)
        } else if ovpnPid != 0 {
            title = "Disconnect"
            colour = UIColor(red: 0.5, green: 0.14, blue: 0.14, alpha: 1)
        } else {
            title = "Connect"
            colour = UIColor(red: 0.11, green: 0.42, blue: 0.18, alpha: 1)
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
            setPhase(.failed, detail: "No .ovpn file — see Settings → Setup guide.")
            RunLog.line("[ovpn] no .ovpn file found. Put one in the app bundle,")
            RunLog.line("       ~/Documents, or /var/mobile/Documents.")
            return
        }
        RunLog.line("[ovpn] config: \(cfg)")
        let pid = ovpn_spawn(ovpnrootBin, openvpnBin, cfg, ovpndnsBin, logPath)
        if pid <= 0 {
            setPhase(.failed, detail: "spawn failed — run Settings → Fix permissions")
            RunLog.line("[ovpn] spawn failed: errno \(-pid) (\(String(cString: strerror(-pid))))")
            RunLog.line("       run Settings → Fix permissions first.")
            return
        }
        ovpnPid = pid
        logShown = 0   // ovpn_spawn re-creates the log with O_TRUNC
        RunLog.line("[ovpn] spawned pid \(pid); tailing log...")
        setPhase(.connecting, detail: "starting openvpn (pid \(pid))")
        clearTraffic()
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
        setPhase(.stopping, detail: "restoring routes and DNS")
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
        let wasStopping = stopping
        ovpnPid = 0
        stopping = false
        tailTimer?.invalidate()
        tailTimer = nil
        stopManagement()
        if wasStopping && code == 0 {
            setPhase(.idle, detail: "clean shutdown")
        } else if code == 3 || code == 4 {
            setPhase(.failed, detail: "no root — Settings → Fix permissions")
        } else {
            setPhase(.failed, detail: "openvpn exited (status \(code)) — see the log")
        }
        clearTraffic()
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
            guard let self = self, !self.stopping else { return }
            self.setPhase(self.phase(forOpenVPNState: state),
                          detail: detail.isEmpty ? state : "\(state)  \(detail)")
        }
        mgmt.onByteCount = { [weak self] bin, bout in
            self?.inValue.text = VPNViewController.human(bin)
            self?.outValue.text = VPNViewController.human(bout)
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
