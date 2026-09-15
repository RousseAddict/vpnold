import UIKit

/// Everything that is not "connect / disconnect".
///
/// The VPN screen is for using the VPN; this is for the things around it — the
/// one-off root chore after a reinstall, the setup guide, the log, and the
/// temporary network checklist. None of them are needed once a tunnel is
/// working, so they do not belong on the main screen.
final class SettingsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView()
    private let rootDot = UIView()
    private let rootStatus = UILabel()

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
        refreshRootStatus()
    }

    /// Fixing the permissions, or coming back from the setup guide, changes what
    /// the header says.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRootStatus()
    }

    /// The app directory plus the one fact that makes it worth showing: whether
    /// the helpers in it are still setuid-root. Both change together — every
    /// install moves the directory and strips the setuid bit — so they belong in
    /// one card rather than as a note the user has to interpret.
    private func makeHeader() -> UIView {
        let width = view.bounds.width
        let header = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 116))
        header.backgroundColor = UIColor.clear

        let card = UIView(frame: CGRect(x: 12, y: 12, width: width - 24, height: 92))
        card.autoresizingMask = [.flexibleWidth]
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 8
        header.addSubview(card)

        let inner = card.bounds.width - 28

        let caption = UILabel(frame: CGRect(x: 14, y: 10, width: inner, height: 12))
        caption.autoresizingMask = [.flexibleWidth]
        caption.backgroundColor = UIColor.clear
        caption.font = UIFont.boldSystemFont(ofSize: 10)
        caption.textColor = UIColor(white: 0.45, alpha: 1)
        caption.text = "APP DIRECTORY — NEW ON EVERY REINSTALL"
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.7
        card.addSubview(caption)

        let uuid = UILabel(frame: CGRect(x: 14, y: 26, width: inner, height: 28))
        uuid.autoresizingMask = [.flexibleWidth]
        uuid.backgroundColor = UIColor.clear
        uuid.numberOfLines = 2
        uuid.font = UIFont(name: "Courier", size: 11)
        uuid.textColor = UIColor(white: 0.85, alpha: 1)
        uuid.adjustsFontSizeToFitWidth = true
        uuid.minimumScaleFactor = 0.6
        uuid.text = appUUID
        card.addSubview(uuid)

        let divider = UIView(frame: CGRect(x: 14, y: 60, width: inner, height: 1))
        divider.autoresizingMask = [.flexibleWidth]
        divider.backgroundColor = UIColor(white: 0.22, alpha: 1)
        card.addSubview(divider)

        rootDot.frame = CGRect(x: 14, y: 73, width: 8, height: 8)
        rootDot.layer.cornerRadius = 4
        card.addSubview(rootDot)

        rootStatus.frame = CGRect(x: 30, y: 67, width: inner - 16, height: 20)
        rootStatus.autoresizingMask = [.flexibleWidth]
        rootStatus.backgroundColor = UIColor.clear
        rootStatus.font = UIFont.systemFont(ofSize: 12)
        rootStatus.adjustsFontSizeToFitWidth = true
        rootStatus.minimumScaleFactor = 0.8
        card.addSubview(rootStatus)

        return header
    }

    private func refreshRootStatus() {
        let ok = RootFix.helpersAreSetuid
        rootDot.backgroundColor = ok ? UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
                                     : UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1)
        rootStatus.text = ok ? "openvpn and ovpnroot are setuid-root"
                             : "Not setuid-root yet — tap Fix permissions"
        rootStatus.textColor = ok ? UIColor(white: 0.75, alpha: 1)
                                  : UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1)
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
        RootFix.prompt(from: self) { [weak self] rc in
            self?.refreshRootStatus()
            self?.showResult(rc)
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
}
