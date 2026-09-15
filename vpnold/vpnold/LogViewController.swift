import UIKit

/// Everything openvpn printed this session, plus the app's own [ovpn]/[mgmt]
/// lines.
///
/// It lives here rather than inside a view controller because the screen that
/// produces it (the VPN screen) is not the screen that shows it (Settings →
/// Log), and it has to survive that screen being closed. Keeping it out of a
/// UITextView except while actually on display also means openvpn's output no
/// longer re-lays-out a text view once a second — which is what used to freeze
/// the UI during a long run.
enum RunLog {

    private(set) static var text = ""

    /// Set by the log view while it is on screen, so it can follow new output
    /// instead of re-assigning the whole string.
    static var onAppend: ((String) -> Void)?

    /// `s` is appended verbatim; it is expected to already end in a newline.
    static func append(_ s: String) {
        guard !s.isEmpty else { return }
        text += s
        onAppend?(s)
    }

    static func line(_ s: String) { append(s + "\n") }
}

// Plain text dump of a log, with a Copy button. Exists so a crash or a failed
// run can be diagnosed from the device alone — there is no Xcode attached to
// this thing. Ported from tvold.
final class LogViewController: UIViewController {

    private let text: String
    private let banner: String?
    /// Follow RunLog live. Also selects which log this is: the run log, or a
    /// fixed snapshot of a crash report.
    private let follow: Bool
    private let textView = UITextView()

    // `banner` is the line shown above the log; nil for a routine view.
    init(text: String, banner: String?, follow: Bool = false) {
        // A UITextView on an A5 struggles well before the log gets large, so
        // only the tail is shown — the part that matters when a run died.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        self.text = lines.suffix(400).joined(separator: "\n")
        self.banner = banner
        self.follow = follow
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    deinit { if follow { RunLog.onAppend = nil } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = follow ? "Log" : "Crash log"
        view.backgroundColor = UIColor.black

        var top: CGFloat = 0
        if let banner = banner {
            let label = UILabel(frame: CGRect(x: 8, y: 8, width: view.bounds.width - 16, height: 44))
            label.autoresizingMask = [.flexibleWidth]
            label.numberOfLines = 2
            label.font = UIFont.boldSystemFont(ofSize: 13)
            label.textColor = UIColor.orange
            label.backgroundColor = UIColor.clear
            label.text = banner
            view.addSubview(label)
            top = 56
        }

        textView.frame = CGRect(x: 0, y: top, width: view.bounds.width,
                                height: view.bounds.height - top)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        textView.textColor = UIColor.green
        textView.font = UIFont(name: "Courier", size: 9)
        textView.text = text
        view.addSubview(textView)

        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyLog))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToEnd()
        guard follow else { return }
        RunLog.onAppend = { [weak self] chunk in
            guard let self = self else { return }
            self.textView.text = self.textView.text + chunk
            self.scrollToEnd()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if follow { RunLog.onAppend = nil }
    }

    private func scrollToEnd() {
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    @objc private func copyLog() {
        // The whole log, not the truncated on-screen tail: copying is for
        // pasting the run somewhere else, where the earlier lines still matter.
        UIPasteboard.general.string = follow ? RunLog.text : text
        navigationItem.rightBarButtonItem?.title = "Copied"
    }

    // Wraps itself in a navigation controller so the buttons have a bar.
    static func present(from vc: UIViewController, text: String, banner: String?,
                        follow: Bool = false) {
        let nav = UINavigationController(rootViewController:
            LogViewController(text: text, banner: banner, follow: follow))
        nav.navigationBar.barStyle = .black
        vc.present(nav, animated: true, completion: nil)
    }
}
