import UIKit

/// Everything that is not "connect / disconnect".
///
/// The VPN screen is for using the VPN; this is for the things around it — the
/// one-off root chore after a reinstall, the log, and the temporary network
/// checklist. None of them are needed once a tunnel is working, so they do not
/// belong on the main screen.
final class SettingsVC: UIViewController, UITableViewDataSource, UITableViewDelegate,
                        UIAlertViewDelegate {

    /// `su` under a pty must not run on the main thread. (.global() is iOS 8+.)
    private static let rootQueue = DispatchQueue(label: "vpnold.root")

    private let table = UITableView()

    private let rows: [(title: String, detail: String, action: Selector)] = [
        ("Fix permissions", "chown root + chmod 4755 on openvpn and ovpnroot",
         #selector(fixPermissions)),
        ("Log", "openvpn output and the app's own messages",
         #selector(showLog)),
        // TEMPORARY, together with NetDiagnostics.swift and netdiag.c.
        ("Net check", "routes, tunnel egress, DNS — results go to the log",
         #selector(netCheck)),
    ]

    /// The `/var/mobile/Applications/<UUID>/` directory name. Changes on every
    /// reinstall, and both helper binaries must be setuid-root again after each
    /// one — so show it here rather than making the user hunt for it.
    private var appUUID: String {
        ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)

        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = UIColor(white: 0.08, alpha: 1)
        table.separatorColor = UIColor(white: 0.25, alpha: 1)
        table.tableHeaderView = makeHeader()
        view.addSubview(table)
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 64))
        header.backgroundColor = UIColor.clear
        let label = UILabel(frame: header.bounds.insetBy(dx: 12, dy: 8))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.backgroundColor = UIColor.clear
        label.numberOfLines = 3
        label.font = UIFont(name: "Courier", size: 10)
        label.textColor = UIColor(white: 0.6, alpha: 1)
        label.text = "app dir:\n\(appUUID)\n"
                   + "(changes on every reinstall — re-run Fix permissions)"
        header.addSubview(label)
        return header
    }

    // MARK: - actions

    @objc private func showLog() {
        LogViewController.present(from: self, text: RunLog.text, banner: nil, follow: true)
    }

    /// TEMPORARY. Output lands in the run log, so open it to watch the steps
    /// arrive rather than leaving the user on a screen that does nothing.
    @objc private func netCheck() {
        NetDiagnostics.run(emit: { RunLog.append($0) }, finished: { })
        showLog()
    }

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
        RunLog.line("[perm] su root: chown root:wheel + chmod 4755")

        SettingsVC.rootQueue.async {
            var out = [CChar](repeating: 0, count: 4096)
            CrashReport.stage("fix-perms: forkpty su")
            // The password goes to su over a pty, never on the command line.
            let rc = run_as_root(password, cmd, &out, 4096)
            CrashReport.stage("fix-perms: su returned \(rc)")
            let text = String(cString: out)
            DispatchQueue.main.async {
                for line in text.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { RunLog.line("[perm] " + t) }
                }
                switch rc {
                case 0:   RunLog.line("[perm] OK — expect -rwsr-xr-x root wheel above.")
                case 127: RunLog.line("[perm] no `su` at /usr/bin/su or /bin/su.")
                default:  RunLog.line("[perm] failed (rc \(rc)) — wrong password?")
                }
                self.showResult(rc)
            }
        }
    }

    /// The log is a screen away now, so say how it went here too.
    private func showResult(_ rc: Int32) {
        let alert = UIAlertView()
        alert.title = rc == 0 ? "Permissions set" : "Failed"
        alert.message = rc == 0 ? "openvpn and ovpnroot are setuid-root."
                                : "su returned \(rc). See the log."
        alert.addButton(withTitle: "OK")
        alert.show()
    }

    // MARK: - UITableViewDataSource / Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "setting"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)

        // (indexPath as NSIndexPath).row, not indexPath.row: the latter is a
        // Swift UIKit *overlay* accessor (mangled ...5UIKitE...) living in
        // libswiftUIKit.dylib, which can trap in dyld_stub_binder on the 5.1.5
        // runtime we ship.
        let row = rows[(indexPath as NSIndexPath).row]
        cell.textLabel?.text = row.title
        cell.textLabel?.textColor = UIColor.white
        cell.textLabel?.font = UIFont.boldSystemFont(ofSize: 15)

        cell.detailTextLabel?.text = row.detail
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
        cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
        cell.detailTextLabel?.minimumScaleFactor = 0.7

        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[(indexPath as NSIndexPath).row]
        perform(row.action)
    }

    // MARK: - UIAlertViewDelegate

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        CrashReport.stage("fix-perms: alert button \(buttonIndex)")
        guard buttonIndex != alertView.cancelButtonIndex,
              let pw = alertView.textField(at: 0)?.text, !pw.isEmpty else { return }
        applyPermissions(password: pw)
    }
}
