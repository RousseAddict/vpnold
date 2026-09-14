import UIKit

/// Where .ovpn files are looked for, and which one is currently selected.
///
/// The selection is remembered in NSUserDefaults so it survives a relaunch, but
/// it is validated against what is actually on disk every time it is read — a
/// config can be deleted over SSH/Filza between runs, and the app should fall
/// back to something that exists rather than fail to spawn.
enum ConfigStore {

    private static let key = "vpnold.selectedConfig"

    /// Bundle first (a config shipped with the build), then the two Documents
    /// directories, which can be filled over SSH/Filza without a rebuild.
    static var searchDirs: [String] {
        [Bundle.main.bundlePath,
         NSHomeDirectory() + "/Documents",
         "/var/mobile/Documents"]
    }

    /// Every .ovpn found, in search-dir order, de-duplicated by full path.
    static func available() -> [String] {
        var out = [String]()
        let fm = FileManager.default
        for dir in searchDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".ovpn") {
                let path = (dir as NSString).appendingPathComponent(name)
                if !out.contains(path) { out.append(path) }
            }
        }
        return out
    }

    /// The chosen config — or the first one found, when nothing has been chosen
    /// yet or the previous choice no longer exists.
    static var selected: String? {
        get {
            let all = available()
            if let saved = UserDefaults.standard.string(forKey: key),
               all.contains(saved) {
                return saved
            }
            return all.first
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
}

/// Modal list of the available .ovpn files, with the current one checkmarked.
final class ConfigPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView()
    private let paths: [String]
    private let onPick: (String) -> Void

    init(onPick: @escaping (String) -> Void) {
        self.paths = ConfigStore.available()
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Choose config"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)

        if paths.isEmpty {
            let label = UILabel(frame: view.bounds.insetBy(dx: 16, dy: 16))
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.numberOfLines = 0
            label.font = UIFont(name: "Courier", size: 12)
            label.textColor = UIColor(white: 0.8, alpha: 1)
            label.backgroundColor = UIColor.clear
            label.text = "No .ovpn files found.\n\nPut them in one of:\n\n"
                       + ConfigStore.searchDirs.joined(separator: "\n\n")
            view.addSubview(label)
        } else {
            table.frame = view.bounds
            table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            table.dataSource = self
            table.delegate = self
            table.backgroundColor = UIColor(white: 0.08, alpha: 1)
            table.separatorColor = UIColor(white: 0.25, alpha: 1)
            view.addSubview(table)
        }

        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - UITableViewDataSource / Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return paths.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "cfg"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)

        // (indexPath as NSIndexPath).row, not indexPath.row: the latter is a
        // Swift UIKit *overlay* accessor (mangled ...5UIKitE...) living in
        // libswiftUIKit.dylib, the same class of symbol that trapped in
        // dyld_stub_binder for UIAlertView's overlay init on the 5.1.5 runtime
        // we ship. NSIndexPath.row is a plain objc_msgSend from this binary.
        let path = paths[(indexPath as NSIndexPath).row]
        cell.textLabel?.text = (path as NSString).lastPathComponent
        cell.textLabel?.textColor = UIColor.white
        cell.textLabel?.font = UIFont.boldSystemFont(ofSize: 15)

        cell.detailTextLabel?.text = (path as NSString).deletingLastPathComponent
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.detailTextLabel?.font = UIFont(name: "Courier", size: 10)
        cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
        cell.detailTextLabel?.minimumScaleFactor = 0.6

        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.accessoryType = (path == ConfigStore.selected) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let path = paths[(indexPath as NSIndexPath).row]
        ConfigStore.selected = path
        tableView.reloadData()
        onPick(path)
        dismiss(animated: true, completion: nil)
    }

    /// Wraps itself in a navigation controller so the Cancel button has a bar.
    static func present(from vc: UIViewController, onPick: @escaping (String) -> Void) {
        let nav = UINavigationController(rootViewController: ConfigPickerVC(onPick: onPick))
        nav.navigationBar.barStyle = .black
        vc.present(nav, animated: true, completion: nil)
    }
}
