// 程序入口：手动构建（无 MainMenu.nib）时由本文件启动应用。
// 原 Xcode 工程使用 @NSApplicationMain + MainMenu.xib，本文件与其互斥；
// 使用 Xcode 构建时请移除本文件（或删除 AppDelegate 的 @NSApplicationMain 注释并删掉本文件）。
import Cocoa

// 冒烟/调试时 stdout 常被重定向到文件，C 层全缓冲会让 print 内容滞留缓冲区，
// 进程被信号终止时丢失。改为无缓冲，print 立即落盘。
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
