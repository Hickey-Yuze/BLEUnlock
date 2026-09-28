import Cocoa
import WebKit
import AVFoundation

// 过渡动画控制器：锁定/解锁时在全屏 WebView 中播放 transition 动画并播放音效。
//
// 时序约定（与 bundle 内 lock.html / unlock.html 的动画时间轴对应）：
//   lock.html   : 动画总长 6.5s（头像 → 粒子离子化 → 飞散），结束时刻由 JS 发
//                 postMessage('lock-finish') 精确回调宿主执行真正的系统锁屏；
//                 9s Timer 仅作 JS 失联兜底，避免动画与锁屏之间出现空档
//   unlock.html : 动画 3.4s + 0.6s 淡出，4.0s 时 JS 发 postMessage('unlock-finish') 通知关窗
//
// 多屏：为每个 NSScreen 各预热一个 WKWebView，播放时先重载页面再统一显示，
// 所有屏幕的动画同帧开始。
//
// 锁定动画期间若 BLE 设备折返（presence 恢复），AppDelegate 会调用 cancelLockTransition()
// 取消挂起的锁屏动作，窗口关闭、不出声继续。
final class TransitionController: NSObject {
    static let shared = TransitionController()

    private enum Kind {
        case lock
        case unlock
    }

    /// WKScriptMessageHandler 的弱引用包装，避免 userContentController 强持有控制器造成保留环。
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?
        init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - 状态

    /// 锁定动画挂起中（尚未执行真正的锁屏）。动画期间设备折返可取消。
    private(set) var lockPending = false

    private var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    private var player: AVAudioPlayer?
    private var finishLockWork: (() -> Void)?
    private var closeTimer: Timer?

    // 预热的 WebView（每屏一个，进程热身，显示时重载重播动画）
    private var warmWebViews: [Kind: [WKWebView]] = [:]

    // MARK: - 偏好

    /// 过渡动画开关，默认开启（未写入过 UserDefaults 时视为开）。
    var enabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "transition") == nil { return true }
        return d.bool(forKey: "transition")
    }

    // MARK: - 对外接口

    /// app 启动后预热 WKWebView 进程与页面（每屏各一），锁定/解锁时几乎零延迟。
    /// 环境变量 BLEUnlockPreview=lock|unlock 时直接播放对应动画（不执行真实锁屏/关窗逻辑），用于安全预览。
    func warmUp() {
        if let preview = ProcessInfo.processInfo.environment["BLEUnlockPreview"] {
            if preview == "lock" {
                print("[transition] preview lock begin")
                beginLockTransition { }
                return
            } else if preview == "unlock" {
                print("[transition] preview unlock begin")
                playUnlockTransition()
                return
            }
        }
        guard enabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.rewarm(.lock)
            self?.rewarm(.unlock)
        }
    }

    /// 锁定：全屏播放锁屏动画，动画播完（JS 回调）后执行 onFinish（真正的系统锁屏）。
    /// 返回 false 表示无法播放动画（资源缺失等），调用方应立即直接锁屏。
    func beginLockTransition(onFinish: @escaping () -> Void) {
        lockPending = true
        finishLockWork = onFinish
        guard play(.lock) else {
            lockPending = false
            finishLockWork = nil
            onFinish()
            return
        }
        // lock.html JS 在动画结束时刻发 'lock-finish'；此 Timer 仅兜底 JS 失联
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 9.0, repeats: false) { [weak self] _ in
            print("[transition] lock finish (timer fallback)")
            self?.finishLockNow()
        }
    }

    /// 取消挂起的锁定动画（设备折返时调用）。
    func cancelLockTransition() {
        guard lockPending else { return }
        lockPending = false
        finishLockWork = nil
        closeTimer?.invalidate()
        closeTimer = nil
        closeAll()
    }

    /// 解锁：播放解锁动画（JS 于 4.0s 通知关窗）。在系统完成解锁后调用。
    func playUnlockTransition() {
        guard enabled else { return }
        guard play(.unlock) else { return }
        // unlock.html JS 于 4.0s 发 'unlock-finish'；此 Timer 仅兜底 JS 失联
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 6.5, repeats: false) { [weak self] _ in
            print("[transition] unlock close (timer fallback)")
            self?.closeAll()
        }
    }

    // MARK: - 内部实现

    private func htmlURL(_ kind: Kind) -> URL? {
        switch kind {
        case .lock:   return Bundle.main.url(forResource: "lock", withExtension: "html")
        case .unlock: return Bundle.main.url(forResource: "unlock", withExtension: "html")
        }
    }

    private func sfxName(_ kind: Kind) -> String {
        kind == .lock ? "lock" : "unlock"
    }

    private func makeConfig() -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.userContentController.add(WeakScriptMessageHandler(self), name: "transition")
        return conf
    }

    private func makeWebView(kind: Kind) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: makeConfig())
        // 加载期间透明背景，避免黑底窗口上闪白
        wv.setValue(false, forKey: "drawsBackground")
        if let url = htmlURL(kind) {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    /// 取出预热的 WebView（每屏一个）；数量不足（屏数变化）则现建补齐。
    private func takeWarmWebViews(_ kind: Kind, count: Int) -> [WKWebView] {
        var taken = warmWebViews[kind] ?? []
        warmWebViews[kind] = nil
        while taken.count < count {
            taken.append(makeWebView(kind: kind))
        }
        return Array(taken.prefix(count))
    }

    /// 按当前屏幕数量重建预热 WebView（每屏一个）。
    private func rewarm(_ kind: Kind) {
        guard enabled, warmWebViews[kind] == nil, htmlURL(kind) != nil else { return }
        warmWebViews[kind] = NSScreen.screens.map { _ in makeWebView(kind: kind) }
    }

    private func play(_ kind: Kind) -> Bool {
        guard let url = htmlURL(kind) else { return false }

        playSfx(sfxName(kind))

        let screens = NSScreen.screens
        let views = takeWarmWebViews(kind, count: screens.count)

        var newWindows: [NSWindow] = []
        var newViews: [WKWebView] = []
        for (index, screen) in screens.enumerated() {
            let win = NSWindow(contentRect: screen.frame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false,
                               screen: screen)
            win.level = .screenSaver
            win.isOpaque = true
            win.backgroundColor = .black
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

            let wv = views[index]
            wv.frame = NSRect(origin: .zero, size: screen.frame.size)
            wv.autoresizingMask = [.width, .height]
            win.contentView = wv
            newWindows.append(win)
            newViews.append(wv)
        }

        // 页面重载（动画从头播放）后统一显示，保证各屏动画同帧开始、互不露黑
        for wv in newViews {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        for win in newWindows {
            win.orderFrontRegardless()
        }

        windows.append(contentsOf: newWindows)
        webViews.append(contentsOf: newViews)
        return true
    }

    private func playSfx(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }

    private func scheduleClose(_ delay: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.closeAll()
        }
    }

    /// JS 报告锁屏动画结束：立即关窗并执行真正的锁屏。
    private func finishLockNow() {
        guard lockPending else { return }
        lockPending = false
        let work = finishLockWork
        finishLockWork = nil
        closeAll()
        work?()
    }

    private func closeAll() {
        closeTimer?.invalidate()
        closeTimer = nil
        for win in windows { win.orderOut(nil) }
        windows.removeAll()
        webViews.removeAll()
        player?.stop()
        player = nil
        // 动画结束后按当前屏幕数重新预热，供下次使用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.rewarm(.lock)
            self.rewarm(.unlock)
        }
    }
}

extension TransitionController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "transition" else { return }
        let body = message.body as? String
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if body == "lock-finish" {
                print("[transition] lock finish (js)")
                self.finishLockNow()
            } else if body == "unlock-finish" {
                print("[transition] unlock close (js)")
                self.closeAll()
            }
        }
    }
}
