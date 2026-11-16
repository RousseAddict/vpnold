import UIKit

/// The one-off root chore: make `openvpn` and `ovpnroot` setuid-root.
///
/// openvpn has to create the utun interface and rewrite the route table, which
/// needs root, and iOS gives an app no way to ask for it. On a jailbroken device
/// the answer is a setuid-root helper — but installing the app resets the
/// ownership and permissions of everything in the bundle, so this has to be
/// redone after every install. Hence both the onboarding page and the Settings
/// row, which is why it lives here and not in either of them.
final class RootFix: NSObject, UIAlertViewDelegate {

    /// `su` under a pty must not run on the main thread. (.global() is iOS 8+.)
    private static let queue = DispatchQueue(label: "vpnold.root")

    /// Retained for the lifetime of the app: UIAlertView's delegate is unowned,
    /// and the alert outlives the call that showed it.
    private static let shared = RootFix()

    private var onFinish: ((Int32) -> Void)?

    /// Asks for the root password, then applies the ownership and mode.
    /// `onFinish` is called on the main thread with su's exit code.
    static func prompt(from vc: UIViewController, onFinish: ((Int32) -> Void)? = nil) {
        CrashReport.stage("fix-perms: tapped")
        shared.onFinish = onFinish
        // Built property-by-property on purpose. The convenience initializer
        // UIAlertView(title:message:delegate:cancelButtonTitle:otherButtonTitles:)
        // lives in the Swift UIKit *overlay* (libswiftUIKit.dylib); calling it
        // traps in dyld_stub_binder on the 5.1.5 runtime we ship, because a
        // symbol it binds lazily is not there. Everything below is a plain
        // objc_msgSend from this binary, so no overlay code is involved.
        let alert = UIAlertView()
        alert.title = "Root password"
        alert.message = "su root — make openvpn and ovpnroot setuid-root.\n"
                      + "On a stock jailbreak this is \"alpine\"."
        alert.delegate = shared
        alert.alertViewStyle = .secureTextInput
        alert.addButton(withTitle: "Cancel")
        alert.cancelButtonIndex = 0
        alert.addButton(withTitle: "Run")
        CrashReport.stage("fix-perms: alert built")
        alert.show()
        CrashReport.stage("fix-perms: alert shown")
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        CrashReport.stage("fix-perms: alert button \(buttonIndex)")
        guard buttonIndex != alertView.cancelButtonIndex,
              let pw = alertView.textField(at: 0)?.text, !pw.isEmpty else {
            onFinish = nil
            return
        }
        apply(password: pw)
    }

    private func apply(password: String) {
        // bundlePath is /var/mobile/Applications/<UUID>/vpnold.app — no spaces
        // or quotes, and it comes from the OS, not from user input.
        let app = Bundle.main.bundlePath
        // ovpndns needs no setuid (openvpn runs it as root already) but it does
        // need its execute bit, and `ipainstaller` installs every bundle file
        // except the main executable as 0644. openvpn treats a --up script it
        // cannot run as fatal, so without this no connection gets anywhere.
        let cmd = "chown root:wheel '\(app)/openvpn' '\(app)/ovpnroot'"
                + " && chmod 4755 '\(app)/openvpn' '\(app)/ovpnroot'"
                + " && chmod 755 '\(app)/ovpndns'"
                + " && ls -l '\(app)/openvpn' '\(app)/ovpnroot' '\(app)/ovpndns'"
        RunLog.line("[perm] su root: chown root:wheel + chmod 4755, chmod 755 ovpndns")

        RootFix.queue.async {
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
                let done = self.onFinish
                self.onFinish = nil
                done?(rc)
            }
        }
    }

    /// Whether the helpers are already setuid-root, so onboarding and Settings
    /// can say where they stand instead of asking blind. Reading the mode is
    /// enough — if the bit is set, a previous run of `prompt` succeeded.
    static var helpersAreSetuid: Bool {
        let fm = FileManager.default
        for name in ["openvpn", "ovpnroot"] {
            let path = Bundle.main.bundlePath + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mode = attrs[.posixPermissions] as? NSNumber,
                  let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
            if owner.intValue != 0 { return false }
            if mode.uint16Value & 0o4000 == 0 { return false }
        }
        // Not setuid, but it must be executable, and some installers drop the
        // bit (see apply). Fix permissions restores it with the rest.
        guard let attrs = try? fm.attributesOfItem(atPath: Bundle.main.bundlePath + "/ovpndns"),
              let mode = attrs[.posixPermissions] as? NSNumber,
              mode.uint16Value & 0o111 != 0 else { return false }
        return true
    }
}
