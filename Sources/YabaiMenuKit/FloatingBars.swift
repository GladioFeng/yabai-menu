// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：在各显示器上承载独立、可停靠或拖动的状态条。
//
// 代码逻辑：
// 1. 用稳定屏幕 ID 对应 yabai 的显示器序号，共享同一份快照。
// 2. 复用原生按钮视图，不因数据刷新重建窗口。
// 3. 拖动结束后保存每屏位置，屏幕变化时校正边界。
//
// 必需输入：快照、外观设置及操作回调。
// 预期输出：每屏一个非激活窗口，不增加周期查询或抢占键盘焦点。
import AppKit

struct BarScreen: Equatable {
    let id: UInt32
    let index: Int
    let key: String
    let visibleFrame: NSRect
    let screenFrame: NSRect

    static func connected(to snapshot: Snapshot) -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = snapshot.displays.first(where: { $0.id == id }) else { return nil }
            return Self(id: id, index: display.index, key: display.uuid ?? String(id), visibleFrame: screen.visibleFrame, screenFrame: screen.frame)
        }
    }

    private func bounds(includingMenuBar: Bool) -> NSRect {
        var bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        if includingMenuBar { bounds.size.height = screenFrame.maxY - bounds.minY }
        return bounds
    }

    func frame(size: NSSize, position: NSPoint, includingMenuBar: Bool = false) -> NSRect {
        let bounds = bounds(includingMenuBar: includingMenuBar)
        let width = min(size.width, max(1, bounds.width)), height = min(size.height, max(1, bounds.height))
        let x = position.x.isFinite ? min(1, max(0, position.x)) : 0.5
        let y = position.y.isFinite ? min(1, max(0, position.y)) : 1
        return NSRect(x: bounds.minX + (bounds.width - width) * x,
                      y: bounds.minY + (bounds.height - height) * y, width: width, height: height)
    }

    func position(for frame: NSRect, includingMenuBar: Bool = false) -> NSPoint {
        let bounds = bounds(includingMenuBar: includingMenuBar)
        let x = bounds.width > frame.width ? (frame.minX - bounds.minX) / (bounds.width - frame.width) : 0.5
        let y = bounds.height > frame.height ? (frame.minY - bounds.minY) / (bounds.height - frame.height) : 1
        return NSPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

@MainActor
final class FloatingBars {
    @MainActor final class Host {
        let panel: FloatingBarPanel
        let bar = WidgetBarView()
        let handle = BarDragHandle()
        let backdrop = BarBackdropView()
        var screen: BarScreen
        var position = NSPoint(x: 0.5, y: 1)
        var includesMenuBar = false
        func updateLevel(floating: Bool) {
            let menuBottom = min(screen.visibleFrame.maxY, screen.screenFrame.maxY - NSStatusBar.system.thickness)
            let level: NSWindow.Level = floating && panel.frame.maxY > menuBottom ? .init(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
            if panel.level != level { panel.level = level }
        }
        init(screen: BarScreen) {
            self.screen = screen
            panel = FloatingBarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.isMovableByWindowBackground = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.isExcludedFromWindowsMenu = true
            panel.title = "Yabai Menu · Display \(screen.index)"
            panel.contentView?.addSubview(backdrop)
            panel.contentView?.addSubview(handle)
            panel.contentView?.addSubview(bar)
        }
    }
    private(set) var hosts: [UInt32: Host] = [:]
    var onDragFinished: (() -> Void)?
    private let defaults: UserDefaults
    private let screens: (Snapshot) -> [BarScreen]

    init(defaults: UserDefaults = .standard, screens: @escaping (Snapshot) -> [BarScreen] = BarScreen.connected) {
        self.defaults = defaults
        self.screens = screens
    }

    func update(_ snapshot: Snapshot, settings: AppSettings, status: ConnectionStatus,
                icon: (Window) -> NSImage?, menu: @escaping (BarTarget) -> NSMenu?, select: @escaping (BarTarget) -> Void) {
        guard settings.effectivePlacement != .menuBar else { close(); return }
        let connected = screens(snapshot)
        let ids = Set(connected.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) { hosts.removeValue(forKey: id)?.panel.close() }
        for screen in connected {
            let host: Host
            if let existing = hosts[screen.id] { host = existing; host.screen = screen }
            else {
                host = Host(screen: screen)
                if let saved = defaults.dictionary(forKey: "floatingPositions")?[screen.key] as? [String: Double],
                   let x = saved["x"], let y = saved["y"], x.isFinite, y.isFinite {
                    host.position = NSPoint(x: x, y: y)
                    host.includesMenuBar = saved["boundsVersion"] == 2
                }
                hosts[screen.id] = host
            }
            if host.handle.isDragging { continue }
            host.bar.onSelect = select
            host.bar.contextMenu = menu
            let handleWidth: CGFloat = settings.effectivePlacement == .floating ? 18 : 0
            let horizontal = CGFloat(settings.barHorizontalPadding), vertical = CGFloat(settings.barVerticalPadding)
            host.panel.appearance = settings.colorPreset.appearance
            host.backdrop.configure(settings)
            host.panel.hasShadow = settings.barShadow && settings.barBackdrop != .none
            var bounded = settings
            bounded.density = .custom
            bounded.customWidth = Int(min(settings.width, max(40, screen.visibleFrame.width - 16 - handleWidth - horizontal * 2)))
            host.bar.configure(snapshot, settings: bounded,
                               enabled: status.mode == .live || status.mode == .limited,
                               height: CGFloat(settings.floatingHeight), display: screen.index, icon: icon)
            host.handle.isHidden = handleWidth == 0
            host.handle.locked = settings.floatingLocked
            host.handle.menu = menu(.menu)
            host.bar.menu = menu(.menu)
            host.panel.contentView?.menu = menu(.menu)
            host.handle.didMove = { [weak host] in host?.updateLevel(floating: true) }
            host.handle.didDrag = { [weak self, weak host] in
                guard let self, let host else { return }
                // Keep old normalized positions unchanged until the user actually moves the bar.
                host.includesMenuBar = true
                host.position = host.screen.position(for: host.panel.frame, includingMenuBar: true)
                host.panel.setFrame(host.screen.frame(size: host.panel.frame.size, position: host.position, includingMenuBar: true), display: true)
                host.updateLevel(floating: true)
                var positions = defaults.dictionary(forKey: "floatingPositions") ?? [:]
                positions[host.screen.key] = ["x": host.position.x, "y": host.position.y, "boundsVersion": 2]
                defaults.set(positions, forKey: "floatingPositions")
            }
            host.handle.didEndInteraction = { [weak self] in self?.onDragFinished?() }
            host.panel.alphaValue = CGFloat(settings.floatingOpacity) / 100
            host.panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if settings.floatingAboveFullscreen { host.panel.collectionBehavior.insert(.fullScreenAuxiliary) }
            let size = NSSize(width: host.bar.frame.width + handleWidth + horizontal * 2, height: host.bar.frame.height + vertical * 2)
            let position = settings.effectivePlacement == .docked ? NSPoint(x: 0.5, y: 1) : host.position
            let frame = screen.frame(size: size, position: position, includingMenuBar: settings.placement == .floating && host.includesMenuBar)
            if host.panel.frame != frame { host.panel.setFrame(frame, display: true) }
            host.updateLevel(floating: settings.placement == .floating)
            host.backdrop.frame = NSRect(origin: .zero, size: frame.size)
            host.handle.frame = NSRect(x: horizontal, y: vertical, width: handleWidth, height: host.bar.frame.height)
            host.bar.frame.origin = NSPoint(x: horizontal + handleWidth, y: vertical)
            if status.mode == .suspended { host.panel.orderOut(nil) }
            else if !host.panel.isVisible { host.panel.orderFrontRegardless() }
        }
    }

    func close() {
        for host in hosts.values { host.panel.close() }
        hosts.removeAll()
    }
}

@MainActor
final class FloatingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // These panels use explicit screen/slot bounds; AppKit otherwise excludes the menu strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class BarDragHandle: NSView {
    var locked = false {
        didSet {
            if locked != oldValue { window?.invalidateCursorRects(for: self); needsDisplay = true }
        }
    }
    var didDrag: (() -> Void)?
    var didMove: (() -> Void)?
    var didEndInteraction: (() -> Void)?
    var isDragging: Bool { start != nil }
    private var moved = false
    private var start: (pointer: NSPoint, origin: NSPoint)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { if !locked { addCursorRect(bounds, cursor: .openHand) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for offset in [-4.0, 0, 4] {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1, y: bounds.midY + offset - 1, width: 2, height: 2)).fill()
        }
        setAccessibilityLabel(locked ? "Floating bar position locked" : "Drag floating bar")
    }
    func beginDrag(at point: NSPoint) {
        guard !locked, let window else { return }
        moved = false
        start = (point, window.frame.origin)
    }
    func drag(to point: NSPoint) {
        guard let start, let window else { return }
        let dx = point.x - start.pointer.x, dy = point.y - start.pointer.y
        guard moved || hypot(dx, dy) >= 3 else { return }
        moved = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
        didMove?()
    }
    func endDrag() {
        guard start != nil else { return }
        start = nil
        let didMove = moved
        moved = false
        if didMove { didDrag?() }
        didEndInteraction?()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        beginDrag(at: window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        drag(to: window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) {
        if let window { drag(to: window.convertPoint(toScreen: event.locationInWindow)) }
        endDrag()
    }
}
