import Cocoa
import WebKit
import AVFoundation

// 过渡动画控制器：锁定/解锁时在全屏 WebView 中播放 transition 动画并播放音效。
//
// 时序约定（与 bundle 内 lock.html / unlock.html 的动画时间轴对应）：
//   lock.html   : 动画总长 6.5s（头像 → 粒子离子化 → 飞散），播完后由 finish 回调执行真正的系统锁屏
//   unlock.html : 动画总长 3.4s + 0.6s 淡出，播完后自动关窗
//
// 锁定动画期间若 BLE 设备折返（presence 恢复），AppDelegate 会调用 cancelLockTransition()
// 取消挂起的锁屏动作，窗口关闭、不出声继续。
final class TransitionController: NSObject {
    static let shared = TransitionController()

    private enum Kind {
        case lock
        case unlock
    }

    // MARK: - 状态

    /// 锁定动画挂起中（尚未执行真正的锁屏）。动画期间设备折返可取消。
    private(set) var lockPending = false

    private var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    private var player: AVAudioPlayer?
    private var finishLockWork: (() -> Void)?
    private var closeTimer: Timer?

    // 预热的 WebView（进程热身，显示时 reload 重播动画）
    private var warmWebViews: [Kind: WKWebView] = [:]

    // MARK: - 偏好

    /// 过渡动画开关，默认开启（未写入过 UserDefaults 时视为开）。
    var enabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "transition") == nil { return true }
        return d.bool(forKey: "transition")
    }

    // MARK: - 对外接口

    /// app 启动后预热 WKWebView 进程与页面，锁定/解锁时几乎零延迟。
    /// 环境变量 BLEUnlockPreview=lock|unlock 时直接播放对应动画（不执行真实锁屏/关窗逻辑），用于安全预览。
    func warmUp() {
        if let preview = ProcessInfo.processInfo.environment["BLEUnlockPreview"] {
            if preview == "lock" {
                beginLockTransition { }
                return
            } else if preview == "unlock" {
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

    /// 锁定：全屏播放锁屏动画，动画播完后执行 onFinish（真正的系统锁屏）。
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
        // lock.html 动画 6.5s + 0.5s 余量
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            guard let self = self, self.lockPending else { return }
            self.lockPending = false
            let work = self.finishLockWork
            self.finishLockWork = nil
            self.closeAll()
            work?()
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

    /// 解锁：播放解锁动画（约 4s 后自动关窗）。在系统完成解锁后调用。
    func playUnlockTransition() {
        guard enabled else { return }
        guard play(.unlock) else { return }
        // unlock.html 动画 3.4s + 0.6s 淡出 + 余量
        scheduleClose(4.8)
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

    /// 取出预热的 WebView；没有则现建。
    private func takeWarmWebView(_ kind: Kind) -> WKWebView {
        if let wv = warmWebViews[kind] {
            warmWebViews[kind] = nil
            return wv
        }
        return makeWebView()
    }

    private func makeWebView() -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: conf)
        // 加载期间透明背景，避免黑底窗口上闪白
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    /// 重建某个预热 WebView。
    private func rewarm(_ kind: Kind) {
        guard warmWebViews[kind] == nil, enabled, let url = htmlURL(kind) else { return }
        let wv = makeWebView()
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        warmWebViews[kind] = wv
    }

    private func play(_ kind: Kind) -> Bool {
        guard let url = htmlURL(kind) else { return false }

        playSfx(sfxName(kind))

        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false,
                               screen: screen)
            win.level = .screenSaver
            win.isOpaque = true
            win.backgroundColor = .black
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            // 拦截鼠标点击，动画期间不误触下层应用

            let wv = takeWarmWebView(kind)
            wv.frame = NSRect(origin: .zero, size: screen.frame.size)
            wv.autoresizingMask = [.width, .height]
            win.contentView = wv
            win.orderFrontRegardless()
            // reload 让动画从头播放（预热页面动画时间轴早已走完）
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

            windows.append(win)
            webViews.append(wv)
        }
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

    private func closeAll() {
        closeTimer?.invalidate()
        closeTimer = nil
        for win in windows { win.orderOut(nil) }
        windows.removeAll()
        webViews.removeAll()
        player?.stop()
        player = nil
        // 动画结束后重新预热，供下次使用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.rewarm(.lock)
            self.rewarm(.unlock)
        }
    }
}
