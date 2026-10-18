// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：在 macOS 原生菜单栏展示 yabai Space 和窗口状态。
//
// 代码逻辑：
// 1. 创建不出现在 Dock 的 AppKit 应用。
// 2. 监听 yabai 状态并更新菜单栏及切换菜单。
// 3. 退出时清理本程序注册的事件。
//
// 必需输入：
// - 已运行的 yabai。
//
// 预期输出：
// - 原生菜单栏中的 Space 编号、窗口图标和状态。
import AppKit
import YabaiMenuKit

@main
struct YabaiMenuApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarController()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
