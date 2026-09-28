import Cocoa

private var aboutBox: AboutBox? = nil

// 纯代码实现（原版通过 AboutBox.xib 加载；手动构建无 ibtool，故重写；对外接口不变）。
class AboutBox: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "BLEUnlock"
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        window.contentView = content

        let icon = NSImageView(frame: NSRect(x: 120, y: 140, width: 80, height: 80))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.frame = NSRect(x: 40, y: 118, width: 240, height: 18)
        versionLabel.alignment = .center
        content.addSubview(versionLabel)

        let homepage = NSButton(title: "GitHub", target: nil, action: nil)
        homepage.bezelStyle = .rounded
        homepage.frame = NSRect(x: 90, y: 70, width: 140, height: 28)
        content.addSubview(homepage)

        let releases = NSButton(title: "Releases", target: nil, action: nil)
        releases.bezelStyle = .rounded
        releases.frame = NSRect(x: 90, y: 34, width: 140, height: 28)
        content.addSubview(releases)

        self.init(window: window)
        window.delegate = self
        homepage.target = self
        homepage.action = #selector(visitHomepage(_:))
        releases.target = self
        releases.action = #selector(checkReleases(_:))
    }

    @IBAction func visitHomepage(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock#readme")!)
    }

    @IBAction func checkReleases(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    static func showAboutBox() {
        if (aboutBox == nil) {
            aboutBox = AboutBox()
        }
        aboutBox?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
