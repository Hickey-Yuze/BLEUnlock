// 程序入口：手动构建（无 MainMenu.nib）时由本文件启动应用。
// 原 Xcode 工程使用 @NSApplicationMain + MainMenu.xib，本文件与其互斥；
// 使用 Xcode 构建时请移除本文件（或删除 AppDelegate 的 @NSApplicationMain 注释并删掉本文件）。
import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
