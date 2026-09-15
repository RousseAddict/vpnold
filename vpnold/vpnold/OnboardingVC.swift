import UIKit

/// The two things that must be done by hand after every install, explained once.
///
/// Neither is discoverable: the app cannot make its own helpers setuid-root, and
/// it deliberately ships no credentials, so a fresh install always starts unable
/// to connect. Installing resets both, which is why this is keyed off a
/// NSUserDefaults flag — the defaults live in the app container, so a reinstall
/// wipes it and the guide comes back exactly when it is needed again.
final class OnboardingVC: UIViewController, UIScrollViewDelegate {

    private static let seenKey = "vpnold.onboardingSeen"

    static var shouldShow: Bool {
        return !UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
        UserDefaults.standard.synchronize()
    }

    private let scroll = UIScrollView()
    private let pageControl = UIPageControl()
    private let actionButton = UIButton(type: .custom)
    private let permStatus = UILabel()
    private let configStatus = UILabel()

    private var page = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        let b = view.bounds
        let bottom: CGFloat = 104

        scroll.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height - bottom)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = self
        scroll.contentSize = CGSize(width: b.width * 2, height: scroll.bounds.height)
        view.addSubview(scroll)

        buildPermissionsPage(at: 0)
        buildConfigPage(at: 1)

        pageControl.frame = CGRect(x: 0, y: b.height - bottom + 8, width: b.width, height: 20)
        pageControl.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        pageControl.numberOfPages = 2
        pageControl.currentPage = 0
        pageControl.addTarget(self, action: #selector(pageControlChanged), for: .valueChanged)
        view.addSubview(pageControl)

        actionButton.frame = CGRect(x: 20, y: b.height - 64, width: b.width - 40, height: 48)
        actionButton.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        actionButton.backgroundColor = UIColor(red: 0.12, green: 0.38, blue: 0.16, alpha: 1)
        actionButton.setTitleColor(UIColor.white, for: .normal)
        actionButton.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        actionButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        actionButton.layer.cornerRadius = 6
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        view.addSubview(actionButton)

        let skip = UIButton(type: .custom)
        skip.frame = CGRect(x: b.width - 76, y: 16, width: 60, height: 32)
        skip.autoresizingMask = [.flexibleLeftMargin]
        skip.setTitle("Skip", for: .normal)
        skip.setTitleColor(UIColor(white: 0.55, alpha: 1), for: .normal)
        skip.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        skip.addTarget(self, action: #selector(finish), for: .touchUpInside)
        view.addSubview(skip)

        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refresh()
    }

    // MARK: - pages

    private func buildPermissionsPage(at index: Int) {
        let canvas = pageView(at: index)
        var y: CGFloat = 40
        y = addTitle("Give openvpn root", to: canvas, y: y)
        y = addBody("Creating the tunnel interface and rewriting the route table "
                  + "need root, and iOS will not grant it to an app. The jailbreak "
                  + "will: the two bundled helpers are made setuid-root once, with "
                  + "your root password.\n\n"
                  + "Installing the app resets this, so it has to be redone after "
                  + "every install. It is also in Settings.",
                    to: canvas, y: y)
        y = addMono("chown root:wheel openvpn ovpnroot\nchmod 4755 openvpn ovpnroot",
                    to: canvas, y: y + 4)
        permStatus.frame = CGRect(x: 24, y: y + 16, width: canvas.bounds.width - 48, height: 40)
        permStatus.autoresizingMask = [.flexibleWidth]
        permStatus.numberOfLines = 2
        permStatus.backgroundColor = UIColor.clear
        permStatus.font = UIFont.boldSystemFont(ofSize: 14)
        canvas.addSubview(permStatus)
    }

    private func buildConfigPage(at index: Int) {
        let canvas = pageView(at: index)
        var y: CGFloat = 40
        y = addTitle("Add a .ovpn profile", to: canvas, y: y)
        y = addBody("vpnold ships no credentials of its own, so bring your own "
                  + "OpenVPN profile. Copy the .ovpn file onto the device with "
                  + "Filza or scp, into any one of these folders, then pick it "
                  + "with the Config button on the main screen.",
                    to: canvas, y: y)
        y = addMono(ConfigStore.searchDirs.joined(separator: "\n"), to: canvas, y: y + 4)
        configStatus.frame = CGRect(x: 24, y: y + 16, width: canvas.bounds.width - 48, height: 40)
        configStatus.autoresizingMask = [.flexibleWidth]
        configStatus.numberOfLines = 2
        configStatus.backgroundColor = UIColor.clear
        configStatus.font = UIFont.boldSystemFont(ofSize: 14)
        canvas.addSubview(configStatus)
    }

    private func pageView(at index: Int) -> UIView {
        let v = UIView(frame: CGRect(x: CGFloat(index) * scroll.bounds.width, y: 0,
                                     width: scroll.bounds.width,
                                     height: scroll.bounds.height))
        v.backgroundColor = UIColor.clear
        scroll.addSubview(v)
        return v
    }

    /// Each of these lays out one block and hands back the y to continue at, so
    /// the pages read top to bottom instead of as a pile of magic offsets.
    private func addTitle(_ text: String, to canvas: UIView, y: CGFloat) -> CGFloat {
        let label = UILabel(frame: CGRect(x: 24, y: y, width: canvas.bounds.width - 48, height: 30))
        label.autoresizingMask = [.flexibleWidth]
        label.backgroundColor = UIColor.clear
        label.font = UIFont.boldSystemFont(ofSize: 22)
        label.textColor = UIColor.white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.text = text
        canvas.addSubview(label)
        return y + 38
    }

    private func addBody(_ text: String, to canvas: UIView, y: CGFloat) -> CGFloat {
        let width = canvas.bounds.width - 48
        let label = UILabel(frame: CGRect(x: 24, y: y, width: width, height: 0))
        label.autoresizingMask = [.flexibleWidth]
        label.backgroundColor = UIColor.clear
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = UIColor(white: 0.72, alpha: 1)
        label.text = text
        label.sizeToFit()
        label.frame = CGRect(x: 24, y: y, width: width, height: label.frame.height)
        canvas.addSubview(label)
        return y + label.frame.height + 14
    }

    private func addMono(_ text: String, to canvas: UIView, y: CGFloat) -> CGFloat {
        let width = canvas.bounds.width - 48
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: width - 20, height: 0))
        label.backgroundColor = UIColor.clear
        label.numberOfLines = 0
        label.font = UIFont(name: "Courier", size: 11)
        label.textColor = UIColor(red: 0.5, green: 0.85, blue: 0.6, alpha: 1)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.text = text
        label.sizeToFit()

        let box = UIView(frame: CGRect(x: 24, y: y, width: width,
                                       height: label.frame.height + 20))
        box.autoresizingMask = [.flexibleWidth]
        box.backgroundColor = UIColor(white: 0.12, alpha: 1)
        box.layer.cornerRadius = 5
        label.frame = CGRect(x: 10, y: 10, width: width - 20, height: label.frame.height)
        box.addSubview(label)
        canvas.addSubview(box)
        return y + box.frame.height
    }

    // MARK: - state

    private func refresh() {
        let rooted = RootFix.helpersAreSetuid
        permStatus.text = rooted ? "Done — the helpers are setuid-root."
                                 : "Not done yet."
        permStatus.textColor = rooted ? UIColor(red: 0.4, green: 0.85, blue: 0.45, alpha: 1)
                                      : UIColor(red: 0.95, green: 0.65, blue: 0.3, alpha: 1)

        let count = ConfigStore.available().count
        configStatus.text = count == 0 ? "No .ovpn file found yet."
                                       : "Found \(count) .ovpn file\(count == 1 ? "" : "s")."
        configStatus.textColor = count == 0 ? UIColor(red: 0.95, green: 0.65, blue: 0.3, alpha: 1)
                                            : UIColor(red: 0.4, green: 0.85, blue: 0.45, alpha: 1)
        refreshButton()
    }

    private func refreshButton() {
        if page == 0 {
            actionButton.setTitle(RootFix.helpersAreSetuid ? "Next" : "Fix permissions",
                                  for: .normal)
        } else {
            actionButton.setTitle("Done", for: .normal)
        }
    }

    @objc private func actionTapped() {
        if page == 0 && !RootFix.helpersAreSetuid {
            RootFix.prompt(from: self) { [weak self] rc in
                guard let self = self else { return }
                self.refresh()
                if rc == 0 { self.go(to: 1) }
            }
            return
        }
        if page == 0 { go(to: 1) } else { finish() }
    }

    private func go(to index: Int) {
        scroll.setContentOffset(CGPoint(x: CGFloat(index) * scroll.bounds.width, y: 0),
                                animated: true)
        page = index
        pageControl.currentPage = index
        refreshButton()
    }

    @objc private func pageControlChanged() {
        go(to: pageControl.currentPage)
    }

    @objc private func finish() {
        OnboardingVC.markSeen()
        dismiss(animated: true, completion: nil)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let w = scrollView.bounds.width
        guard w > 0 else { return }
        page = Int((scrollView.contentOffset.x + w / 2) / w)
        pageControl.currentPage = page
        refreshButton()
    }
}
