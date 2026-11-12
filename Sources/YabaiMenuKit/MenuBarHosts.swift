// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：在菜单栏自己的原生槽位内，分别显示每块屏幕的 Spaces。
//
// 代码逻辑：
// 1. 复用每屏状态投影，按最长一屏内容申请统一的原生槽位。
// 2. 将每屏内容挂在对应的原生窗口，让系统处理移动与可见性。
// 3. 槽位不可用时卸载内容；点击继续由原生槽位的事件监视器处理。
//
// 必需输入：快照、设置、屏幕映射及本应用的原生槽位窗口。
// 预期输出：每屏独立内容；按现有刷新批量读取自有槽位状态，不增加 yabai 查询或周期计时器。
import AppKit

@MainActor
final class MenuBarHosts {
    struct Screen {
        let id: UInt32
        let index: Int
        let frame: NSRect
        static func connected(to snapshot: Snapshot) -> [Self] {
            NSScreen.screens.compactMap { screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                      let display = snapshot.displays.first(where: { $0.id == id }) else { return nil }
                return Self(id: id, index: display.index, frame: screen.frame)
            }
        }
    }

    final class SlotContent: NSView {
        // Leave hit testing to the native slot, including Command-drag to move the item.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Host {
        let content = SlotContent()
        let bar = WidgetBarView()
        var anchorNumber: Int?

        init() {
            content.clipsToBounds = true
            content.addSubview(bar)
        }

        var frameOnScreen: NSRect? {
            content.window.map { $0.convertToScreen(content.convert(content.bounds, to: nil)) }
        }
    }

    private(set) var hosts: [UInt32: Host] = [:]
    private let screens: (Snapshot) -> [Screen]
    private let anchors: @MainActor () -> [NSWindow]

    init(screens: @escaping (Snapshot) -> [Screen] = Screen.connected,
         anchors: @escaping @MainActor () -> [NSWindow] = { NSApp.windows.filter { $0.level == .statusBar } }) {
        self.screens = screens
        self.anchors = anchors
    }

    // One item is mirrored by macOS. Accept only one visible, correctly sized slot on each screen.
    static func anchorFrame(_ frame: NSRect, screen: NSRect, width: CGFloat? = nil, visible: Bool) -> NSRect? {
        guard visible, frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.height >= 20, frame.height <= 64,
              frame.minX >= screen.minX, frame.maxX <= screen.maxX,
              abs(frame.maxY - screen.maxY) <= 1 else { return nil }
        if let width, abs(frame.width - width) > 3 { return nil }
        return frame
    }

    static func anchorFrame(_ window: NSWindow, screen: NSRect, onscreen: Set<Int>) -> NSRect? {
        // Native status slots can report occlusion even while WindowServer keeps them on screen.
        anchorFrame(window.frame, screen: screen,
                    visible: window.isVisible && onscreen.contains(window.windowNumber))
    }

    static func contentFrame(in window: NSWindow) -> NSRect {
        // Native slots include chrome around the inset view that contains their mirrored button.
        guard let root = window.contentView else { return window.frame }
        let nativeViews = root.subviews.filter { !($0 is SlotContent) }
        guard nativeViews.count == 1, let content = nativeViews.first else { return window.frame }
        let frame = window.convertToScreen(content.convert(content.bounds, to: nil))
        guard frame.height >= 20, frame.width > 0, window.frame.contains(frame) else { return window.frame }
        return frame
    }

    struct Placement {
        let frame: NSRect
        let contentOrigin: NSPoint
        let appliesLayout: Bool
    }

    static func placement(in anchor: NSRect, requestedWidth: CGFloat, nextSize: NSSize, previousSize: NSSize?) -> Placement? {
        let ready = abs(anchor.width - requestedWidth) <= 3 && nextSize.width <= anchor.width
        guard let size = ready ? nextSize : previousSize else { return nil }
        let width = min(size.width, anchor.width)
        return Placement(frame: NSRect(x: anchor.maxX - width, y: anchor.minY, width: width, height: anchor.height),
                         contentOrigin: NSPoint(x: width - size.width, y: 0), appliesLayout: ready)
    }

    func hit(at location: NSPoint, in slot: NSWindow) -> (target: BarTarget, bounds: NSRect)? {
        guard let host = hosts.values.first(where: { $0.content.window === slot }),
              let frame = host.frameOnScreen, frame.contains(slot.convertPoint(toScreen: location)),
              let cell = host.bar.cell(at: host.bar.convert(location, from: nil)) else { return nil }
        let bounds = slot.convertToScreen(host.bar.convert(cell.frame, to: nil))
        return (cell.target, bounds.intersection(frame))
    }

    @discardableResult
    func update(_ snapshot: Snapshot, settings: AppSettings, status: ConnectionStatus,
                reserveWidth: (CGFloat) -> Void = { _ in },
                icon: (Window) -> NSImage?, menu: @escaping (BarTarget) -> NSMenu?, select: @escaping (BarTarget) -> Void) -> CGFloat {
        let connected = screens(snapshot), ids = Set(connected.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) { hosts.removeValue(forKey: id)?.content.removeFromSuperview() }
        let initialSlots = anchors()
        var layouts = [UInt32: WidgetBarView.Layout]()
        for screen in connected {
            let host = hosts[screen.id] ?? Host()
            hosts[screen.id] = host
            var local = settings
            local.spaceScope = .focusedDisplay
            // A notched screen and an external screen can have different menu-bar heights.
            let localSlots = initialSlots.filter { Self.anchorFrame($0.frame, screen: screen.frame, visible: true) != nil }
            let height = localSlots.count == 1 ? Self.contentFrame(in: localSlots[0]).height : NSStatusBar.system.thickness
            host.bar.onSelect = select
            host.bar.contextMenu = menu
            if host.bar.menu == nil { host.bar.menu = menu(.menu) }
            layouts[screen.id] = host.bar.prepare(snapshot, settings: local,
                                                enabled: status.mode == .live || status.mode == .limited,
                                                height: min(64, max(20, height)), display: screen.index)
        }
        let width = hosts.map { layouts[$0.key]?.size.width ?? $0.value.bar.frame.width }.max() ?? 0
        if width > 0 { reserveWidth(width) }
        let slots = anchors()
        let ownNumbers = Set(slots.map(\.windowNumber))
        let onscreen = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row -> Int? in
            guard let number = row[kCGWindowNumber as String] as? Int, ownNumbers.contains(number) else { return nil }
            return number
        })
        for screen in connected {
            guard let host = hosts[screen.id] else { continue }
            let candidates = slots.filter { slot in
                Self.anchorFrame(slot, screen: screen.frame, onscreen: onscreen) != nil
            }
            guard status.mode != .suspended, candidates.count == 1,
                  let slot = candidates.first, let root = slot.contentView else {
                host.content.removeFromSuperview()
                continue
            }
            let previousSize = host.anchorNumber == slot.windowNumber && !host.bar.cells.isEmpty ? host.bar.frame.size : nil
            guard let placement = Self.placement(in: Self.contentFrame(in: slot), requestedWidth: width,
                                                nextSize: layouts[screen.id]?.size ?? host.bar.frame.size, previousSize: previousSize) else {
                host.content.removeFromSuperview()
                continue
            }
            if placement.appliesLayout {
                if let layout = layouts[screen.id] { host.bar.apply(layout, icon: icon) }
                host.anchorNumber = slot.windowNumber
            }
            // Mount outside the primary button whose image AppKit mirrors onto other displays.
            if host.content.superview !== root {
                host.content.removeFromSuperview()
                root.addSubview(host.content, positioned: .above, relativeTo: nil)
            }
            // Keep the previous content clipped to its slot until the new width is ready.
            let frame = root.convert(slot.convertFromScreen(placement.frame), from: nil)
            if host.content.frame != frame { host.content.frame = frame }
            if host.bar.frame.origin != placement.contentOrigin { host.bar.frame.origin = placement.contentOrigin }
        }
        return width
    }

    func close() {
        for host in hosts.values { host.content.removeFromSuperview() }
        hosts.removeAll()
    }
}
