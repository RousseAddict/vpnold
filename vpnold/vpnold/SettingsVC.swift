import UIKit

/// Everything that is not "connect / disconnect".
///
/// The VPN screen is for using the VPN; this is for the things around it — the
/// one-off root chore after a reinstall, the setup guide, the log, and the
/// temporary network checklist. None of them are needed once a tunnel is
/// working, so they do not belong on the main screen.
final class SettingsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView()

    private let rows: [(title: String, detail: String, action: Selector)] = [
        ("Fix permissions", "chown root + chmod 4755 on openvpn and ovpnroot",
         #selector(fixPermissions)),
        ("Setup guide", "root access and where to put the .ovpn file",
         #selector(showOnboarding)),
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

    @objc private func showOnboarding() {
        present(OnboardingVC(), animated: true, completion: nil)
    }

    /// TEMPORARY. Output lands in the run log, so open it to watch the steps
    /// arrive rather than leaving the user on a screen that does nothing.
    @objc private func netCheck() {
        NetDiagnostics.run(emit: { RunLog.append($0) }, finished: { })
        showLog()
    }

    @objc private func fixPermissions() {
        RootFix.prompt(from: self) { [weak self] rc in self?.showResult(rc) }
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
}
