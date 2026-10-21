// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices

@MainActor
public final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var statusItem: NSStatusItem?
    private var client: YabaiClient?
    private var clientTransition: Task<Void, Never>?
    private var clientGeneration = 0
    private var quitting = false
    private var snapshot: Snapshot?
    private var status = ConnectionStatus()
    private var settings = AppSettings()
    private var settingsDefaults = UserDefaults.standard
    private var settingsWindow: SettingsWindowController?
    private var icons: [Int32: NSImage] = [:]
    private var monochromeIcons: [Int32: NSImage] = [:]
    private lazy var imageContext = CIContext()
    private(set) var widgetBar: WidgetBarView?
    private(set) var floatingBars = FloatingBars()
    private(set) var menuBarHosts = MenuBarHosts()
    private(set) var fullMenu = NSMenu()
    private var statusMouseMonitor: Any?
    private var nativeClick: (window: Int, target: BarTarget, bounds: NSRect)?
    private var menuAnchorObservers: [NSObjectProtocol] = []
    private var modifierMonitors: [Any] = []
    private var menuAnchorUpdateQueued = false
    private var screenObserver: NSObjectProtocol?
    private var menuTracking = false
    private var menuListChanged = false
    private var statusMenuItem: NSMenuItem?
    private var updatedMenuItem: NSMenuItem?
    var focusAction: ((Int?, Int?) -> Void)?

    public override init() { super.init() }
    init(settings: AppSettings, defaults: UserDefaults = .standard, menuBarHosts: MenuBarHosts? = nil) {
        self.settings = settings
        settingsDefaults = defaults
        if let menuBarHosts { self.menuBarHosts = menuBarHosts }
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()
        }
        guard !duplicate else { NSApp.terminate(nil); return }
        setupItem()
        connectClient()
    }

    private func connectClient() {
        clientGeneration += 1
        let generation = clientGeneration
        let previous = clientTransition
        clientTransition = Task {
            await previous?.value
            guard !quitting, generation == clientGeneration else { return }
            let old = client
            client = nil
            await old?.stop()
            guard !quitting, generation == clientGeneration else { return }
            guard let path = settings.resolvedPath else {
                update(nil, status: ConnectionStatus(mode: .disconnected,
                    detail: "yabai was not found. Install it, or choose its executable in Settings."))
                return
            }
            let next = YabaiClient(path: path)
            client = next
            focusAction = { [weak next] space, window in next?.focus(space: space, window: window) }
            next.onUpdate = { [weak self, weak next] snapshot, status in
                guard let self, self.client === next else { return }
                self.update(snapshot, status: status)
            }
            next.start()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        menuAnchorObservers.forEach(NotificationCenter.default.removeObserver)
        modifierMonitors.forEach(NSEvent.removeMonitor)
        if let statusMouseMonitor { NSEvent.removeMonitor(statusMouseMonitor) }
    }

    func setupItem() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.update(self.snapshot, status: self.status, force: true)
                }
            }
        }
        floatingBars.onDragFinished = { [weak self] in
            guard let self else { return }
            self.update(self.snapshot, status: self.status, force: true)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "YabaiMenu"
        item.button?.title = "Spaces …"
        fullMenu.delegate = self
        item.menu = fullMenu
        statusItem = item
        if statusMouseMonitor == nil {
            statusMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleStatusMouse(event)
            }
        }
        if menuAnchorObservers.isEmpty {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                menuAnchorObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let window = note.object as? NSWindow, window.level == .statusBar else { return }
                    Task { @MainActor in self?.scheduleMenuAnchorUpdate() }
                })
            }
            installModifierMonitors()
        }
    }

    private func installModifierMonitors() {
        modifierMonitors.forEach(NSEvent.removeMonitor)
        modifierMonitors.removeAll()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] _ in
            Task { @MainActor in self?.menuBarHosts.updateCommandState(NSEvent.modifierFlags.contains(.command)) }
        }) { modifierMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.menuBarHosts.updateCommandState(event.modifierFlags.contains(.command))
            return event
        }) { modifierMonitors.append(local) }
    }

    private func scheduleMenuAnchorUpdate() {
        guard settings.placement == .menuBar, settings.spaceScope == .focusedDisplay, !quitting, !menuAnchorUpdateQueued else { return }
        menuAnchorUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuAnchorUpdateQueued = false
            self.update(self.snapshot, status: self.status, force: true)
        }
    }

    func handleStatusMouse(_ event: NSEvent) -> NSEvent? {
        guard settings.placement == .menuBar, snapshot != nil, let window = event.window, window.level == .statusBar else { return event }
        guard !event.modifierFlags.contains(.command) else { nativeClick = nil; return event }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let hit: (target: BarTarget, bounds: NSRect)?
        if let bar = widgetBar, let button = statusItem?.button {
            // System replicas share the same columns, but do not share the primary view's hit testing.
            let x = event.locationInWindow.x - button.frame.minX - bar.frame.minX
            hit = bar.cell(at: NSPoint(x: x, y: bar.bounds.midY)).map {
                ($0.target, NSRect(x: window.frame.minX + button.frame.minX + bar.frame.minX + $0.frame.minX,
                                  y: window.frame.minY, width: $0.frame.width, height: window.frame.height))
            }
        } else if let host = menuBarHosts.hosts.values.first(where: { $0.panel.isVisible && $0.panel.frame.contains(point) }) {
            let local = host.bar.convert(host.panel.convertPoint(fromScreen: point), from: nil)
            hit = host.bar.cell(at: local).map { ($0.target, host.panel.convertToScreen(host.bar.convert($0.frame, to: nil))) }
        } else { hit = nil }
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            nativeClick = nil
            if let hit { barContextMenu(hit.target).popUp(positioning: nil, at: point, in: nil) }
            else { fullMenu.popUp(positioning: nil, at: point, in: nil) }
            return nil
        }
        switch event.type {
        case .leftMouseDown:
            nativeClick = hit.map { (window.windowNumber, $0.target, $0.bounds) }
        case .leftMouseUp:
            let click = nativeClick
            nativeClick = nil
            if let click, click.window == window.windowNumber, click.bounds.contains(point) { selectBarTarget(click.target) }
        default: return event
        }
        return nil
    }

    func update(_ snapshot: Snapshot?, status: ConnectionStatus, force: Bool = false) {
        let snapshotChanged = self.snapshot != snapshot
        let changed = snapshotChanged || self.status.needsAttention != status.needsAttention || self.status.mode != status.mode
        self.snapshot = snapshot
        self.status = status
        settingsWindow?.updateStatus(status, path: client?.path)
        if settings.effectivePlacement == .menuBar, statusItem?.isVisible == false { statusItem?.isVisible = true }
        let automaticMenu: NSMenu? = settings.placement == .menuBar && snapshot != nil ? nil : fullMenu
        if statusItem?.menu !== automaticMenu { statusItem?.menu = automaticMenu }
        if changed || force {
            if let snapshot {
                if settings.effectivePlacement != .menuBar {
                    menuBarHosts.close()
                    widgetBar?.removeFromSuperview(); widgetBar = nil
                    statusItem?.length = NSStatusItem.variableLength
                    statusItem?.button?.title = "Yabai"
                    floatingBars.update(snapshot, settings: settings, status: status, icon: icon,
                                        menu: { [weak self] in self?.barContextMenu($0) },
                                        select: { [weak self] in self?.selectBarTarget($0) })
                } else if settings.spaceScope == .focusedDisplay, let button = statusItem?.button {
                    floatingBars.close()
                    widgetBar?.removeFromSuperview(); widgetBar = nil
                    if !button.title.isEmpty { button.title = "" }
                    menuBarHosts.update(snapshot, settings: settings, status: status,
                                                   reserveWidth: { [weak self] width in
                                                       guard let self, self.statusItem?.length != width else { return }
                                                       self.statusItem?.length = width
                                                       self.scheduleMenuAnchorUpdate()
                                                   }, icon: icon,
                                                   menu: { [weak self] in self?.barContextMenu($0) },
                                                   select: { [weak self] in self?.selectBarTarget($0) })
                    if menuBarHosts.hosts.isEmpty {
                        button.title = "Yabai"
                        statusItem?.length = NSStatusItem.variableLength
                    }
                } else if let button = statusItem?.button {
                    floatingBars.close()
                    menuBarHosts.close()
                    let bar = widgetBar ?? WidgetBarView()
                    bar.onSelect = { [weak self] in self?.selectBarTarget($0) }
                    bar.contextMenu = { [weak self] in self?.barContextMenu($0) }
                    bar.menu = barContextMenu(.menu)
                    bar.configure(snapshot, settings: settings,
                                  enabled: status.mode == .live || status.mode == .limited, height: button.bounds.height, icon: icon)
                    button.title = ""
                    statusItem?.length = bar.frame.width
                    bar.frame.origin = NSPoint(x: 0, y: max(0, (button.bounds.height - bar.frame.height) / 2))
                    bar.autoresizingMask = [.minYMargin, .maxYMargin]
                    if widgetBar == nil { button.addSubview(bar); widgetBar = bar }
                }
                icons = icons.filter { pid, _ in snapshot.windows.contains { $0.pid == pid } }
                monochromeIcons = monochromeIcons.filter { icons[$0.key] != nil }
            } else {
                floatingBars.close()
                menuBarHosts.close()
                widgetBar?.removeFromSuperview(); widgetBar = nil
                statusItem?.length = NSStatusItem.variableLength
                statusItem?.button?.title = status.needsAttention ? "Yabai Menu" : "Spaces …"
            }
            if settingsWindow?.window?.isVisible == true {
                settingsWindow?.updatePreview(snapshot) { [weak self] in self?.icon(for: $0) }
            }
        }
        let showStatusItem = floatingBars.hosts.isEmpty
        if statusItem?.isVisible != showStatusItem { statusItem?.isVisible = showStatusItem }
        let current = snapshot?.focusedSpace.map { "Space \($0.index)" } ?? "No focused Space"
        let window = snapshot?.focusedWindow.map { "\($0.app), \($0.title), \($0.state)" } ?? "No focused window"
        statusItem?.button?.setAccessibilityLabel("\(current). \(window). \(status.title). Open menu to switch.")
        let tooltip = status.message ?? "\(current) · \(status.title). Click to switch Spaces or windows."
        if statusItem?.button?.toolTip != tooltip { statusItem?.button?.toolTip = tooltip }
        if menuTracking {
            // Keep action rows still while the pointer is choosing a target.
            menuListChanged = menuListChanged || snapshotChanged
            statusMenuItem?.title = status.isSwitching ? "Switching…" : status.title
            updatedMenuItem?.title = status.message.map { String($0.prefix(100)) }
                ?? (menuListChanged ? "State updated · Reopen the menu to refresh" : status.updatedDescription())
            updatedMenuItem?.toolTip = status.message
        }
    }

    private func icon(for window: Window) -> NSImage? {
        if settings.monochrome, let icon = monochromeIcons[window.pid] { return icon }
        if !settings.monochrome, let icon = icons[window.pid] { return icon }
        let image = NSRunningApplication(processIdentifier: window.pid)?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: window.app)
        let sized = (icons[window.pid] ?? image)?.copy() as? NSImage
        sized?.size = NSSize(width: 16, height: 16)
        icons[window.pid] = sized
        if settings.monochrome, let data = sized?.tiffRepresentation, let input = CIImage(data: data),
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(0, forKey: kCIInputSaturationKey)
            if let output = filter.outputImage, let cgImage = imageContext.createCGImage(output, from: output.extent) {
                let gray = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
                monochromeIcons[window.pid] = gray
                return gray
            }
        }
        return sized
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { if !menuTracking { rebuildMenu(menu) } }
    public func menuWillOpen(_ menu: NSMenu) { menuListChanged = false; menuTracking = true; client?.refresh() }
    public func menuDidClose(_ menu: NSMenu) { menuTracking = false }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        statusMenuItem = menu.addItem(withTitle: status.isSwitching ? "Switching…" : status.title, action: nil, keyEquivalent: "")
        updatedMenuItem = menu.addItem(withTitle: status.updatedDescription(), action: nil, keyEquivalent: "")
        if let message = status.message {
            let detail = menu.addItem(withTitle: String(message.prefix(120)), action: nil, keyEquivalent: "")
            detail.toolTip = message
            if status.actionError != nil { item(menu, "Dismiss Action Error", #selector(dismissError)) }
        }
        menu.addItem(.separator())
        if let snapshot {
            var shown = Set<Int>()
            if let focused = snapshot.focusedSpace {
                let windows = snapshot.windows.filter { $0.space == focused.index || ($0.focused && $0.sticky) }
                addSpace(focused, windows: windows, to: menu, heading: "Current Space")
                shown.formUnion(windows.map(\.id))
                menu.addItem(.separator())
            }
            for display in Set(snapshot.spaces.map(\.display)).sorted() {
                let spaces = snapshot.spaces.filter { $0.display == display && !$0.focused }
                guard !spaces.isEmpty else { continue }
                menu.addItem(withTitle: "Display \(display)", action: nil, keyEquivalent: "")
                for space in spaces {
                    let windows = snapshot.windows.filter { $0.space == space.index }
                    addSpace(space, windows: windows, to: menu)
                    shown.formUnion(windows.map(\.id))
                }
                menu.addItem(.separator())
            }
            let remaining = snapshot.windows.filter { !shown.contains($0.id) }
            if !remaining.isEmpty {
                menu.addItem(withTitle: "Other Windows", action: nil, keyEquivalent: "")
                for window in remaining { addWindow(window, spaceID: nil, to: menu) }
                menu.addItem(.separator())
            }
        }
        if let snapshot {
            let manage = NSMenu()
            for space in snapshot.spaces {
                let entry = manage.addItem(withTitle: "Space \(space.index) · \(space.name)", action: nil, keyEquivalent: "")
                entry.submenu = spaceMenu(space.id)
            }
            let entry = menu.addItem(withTitle: "Manage Spaces", action: nil, keyEquivalent: "")
            entry.submenu = manage
        }
        item(menu, "Refresh", #selector(refresh), key: "r")
        item(menu, "Check Connection", #selector(checkConnection))
        item(menu, "Settings…", #selector(openSettings), key: ",")
        item(menu, "Copy Diagnostics", #selector(copyDiagnostics))
        item(menu, "Copy Refresh Hook", #selector(copyRefreshHook))
        item(menu, "yabai Setup Guide", #selector(openSetupGuide))
        item(menu, "About Yabai Menu", #selector(aboutApp))
        menu.addItem(.separator())
        item(menu, "Quit Yabai Menu", #selector(quit), key: "q")
    }

    private func selectBarTarget(_ target: BarTarget) {
        guard target == .menu || status.mode == .live || status.mode == .limited else { return }
        switch target {
        case .space(let id):
            let sender = NSMenuItem(); sender.representedObject = id; selectSpace(sender)
        case .window(let id, let space):
            let sender = NSMenuItem(); sender.tag = id; sender.representedObject = space; selectWindow(sender)
        case .create(let id): client?.perform(.create(anchorID: id))
        case .menu:
            fullMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func barContextMenu(_ target: BarTarget) -> NSMenu {
        let menu: NSMenu
        switch target {
        case .space(let id), .window(_, let id?): menu = spaceMenu(id) ?? NSMenu()
        default: menu = NSMenu()
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if settings.placement == .floating {
            let lock = menu.addItem(withTitle: "Lock Floating Bar Position", action: #selector(toggleFloatingLock), keyEquivalent: "")
            lock.target = self
            lock.state = settings.floatingLocked ? .on : .off
            menu.addItem(.separator())
        }
        item(menu, "Open Full Menu", #selector(openFullMenu))
        item(menu, "Settings…", #selector(openSettings))
        item(menu, "Quit Yabai Menu", #selector(quit))
        return menu
    }

    @objc private func openFullMenu() { selectBarTarget(.menu) }

    @objc private func toggleFloatingLock() {
        guard settings.placement == .floating else { return }
        settings.floatingLocked.toggle()
        settings.save(to: settingsDefaults)
        settingsWindow?.syncFloatingLocked(settings.floatingLocked)
        update(snapshot, status: status, force: true)
    }

    private func spaceMenu(_ id: Int) -> NSMenu? {
        guard let snapshot, let space = snapshot.spaces.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let enabled = status.mode == .live || status.mode == .limited
        func add(_ title: String, _ action: YabaiAction, allowed: Bool = true) {
            let item = menu.addItem(withTitle: title, action: #selector(spaceAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action; item.isEnabled = enabled && allowed
        }
        add("Focus", .focus(spaceID: id, window: nil))
        add("Rename…", .rename(spaceID: id, label: space.label))
        menu.addItem(.separator())
        add("Move Left", .move(spaceID: id, offset: -1), allowed: snapshot.spaces.first?.id != id)
        add("Move Right", .move(spaceID: id, offset: 1), allowed: snapshot.spaces.last?.id != id)
        menu.addItem(.separator())
        add("Create on Display \(space.display)", .create(anchorID: id))
        add("Delete Space", .remove(spaceID: id))
        return menu
    }

    @objc private func spaceAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? YabaiAction else { return }
        if case .rename(let id, let label) = action {
            let alert = NSAlert()
            alert.messageText = "Rename Space"
            alert.informativeText = "Leave the label empty to show its number."
            let field = NSTextField(string: label)
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn { client?.perform(.rename(spaceID: id, label: field.stringValue)) }
        } else { client?.perform(action) }
    }

    private func addSpace(_ space: Space, windows: [Window], to menu: NSMenu, heading: String? = nil) {
        if let heading { menu.addItem(withTitle: heading, action: nil, keyEquivalent: "") }
        let name = space.label.isEmpty ? "Space \(space.index)" : "\(space.index) · \(space.label)"
        let entry = menu.addItem(withTitle: "\(name)  (\(space.type))", action: #selector(selectSpace(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = space.index
        entry.representedObject = space.id
        entry.state = space.focused ? .on : (space.visible ? .mixed : .off)
        let ordered = windows.sorted { a, b in a.focused != b.focused ? a.focused : (a.app == b.app ? a.id < b.id : a.app < b.app) }
        for window in ordered { addWindow(window, spaceID: space.id, to: menu) }
    }

    private func addWindow(_ window: Window, spaceID: Int?, to menu: NSMenu) {
        let suffix = window.minimized ? " · minimized" : (window.hidden ? " · hidden" : "")
        let text = window.title.isEmpty ? window.app : "\(window.app) — \(window.title)"
        let short = text.count > 65 ? String(text.prefix(64)) + "…" : text
        let item = menu.addItem(withTitle: short + suffix, action: #selector(selectWindow(_:)), keyEquivalent: "")
        item.indentationLevel = 1
        item.target = self
        item.tag = window.id
        item.representedObject = spaceID
        item.toolTip = text + " · " + window.state
        item.image = icon(for: window)
        item.state = window.focused ? .on : .off
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    @objc private func selectSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let space = snapshot?.spaces.first(where: { $0.id == id }) else {
            selectionError("That Space is no longer available. Reopen the menu and choose again."); return
        }
        focusAction?(space.index, nil)
    }
    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let window = snapshot?.windows.first(where: { $0.id == sender.tag }) else {
            selectionError("That window is no longer available. Reopen the menu and choose again."); return
        }
        let preferredID = sender.representedObject as? Int
        let space = window.sticky
            ? snapshot?.spaces.first(where: { $0.id == preferredID })
            : snapshot?.spaces.first(where: { $0.index == window.space })
        focusAction?(space?.index, window.id)
    }
    private func selectionError(_ message: String) {
        if let client { client.reportActionError(message) }
        else { var next = status; next.actionError = message; update(snapshot, status: next) }
    }
    @objc private func refresh() { client?.refresh() }
    @objc private func dismissError() { client?.dismissActionError() }
    @objc private func checkConnection() {
        // The first launch may precede Accessibility permission for global modifier events.
        installModifierMonitors()
        connectClient()
    }
    @objc private func aboutApp() { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func openSetupGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/asmvik/yabai/wiki")!) }
    @objc private func quit() { NSApp.terminate(nil) }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectSpace(_:)) || menuItem.action == #selector(selectWindow(_:)) {
            return status.mode == .live || status.mode == .limited
        }
        return true
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onChange = { [weak self] settings in
                guard let self else { return }
                let pathChanged = self.settings.yabaiPath != settings.yabaiPath
                self.settings = settings
                settings.save(to: self.settingsDefaults)
                self.update(self.snapshot, status: self.status, force: true)
                if pathChanged { self.connectClient() }
            }
            controller.onReconnect = { [weak self] in self?.checkConnection() }
            controller.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
            controller.onEnableWindowObservation = { [weak self] in self?.client?.requestWindowObservationAccess() }
            settingsWindow = controller
        }
        settingsWindow?.updateStatus(status, path: client?.path)
        settingsWindow?.updatePreview(snapshot) { [weak self] in self?.icon(for: $0) }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func diagnostics(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let executable = (client?.path ?? "not found").replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let connection = client?.diagnosticLines ?? [
            "Accessibility: \(AXIsProcessTrusted() ? "granted" : "denied")",
            "Native window subscriptions: not started",
            "Errors: \(status.message == nil ? "none" : "connection/action error; client unavailable")"]
        return (["Yabai Menu \(version) (build \(build))", "Process architecture: \(architecture)",
                 "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)", "yabai: \(executable)",
                 "Connection: \(status.mode.rawValue)", status.updatedDescription(),
                 "Spaces: \(snapshot?.spaces.count ?? 0), windows: \(snapshot?.windows.count ?? 0)"]
                + connection + ["Periodic polling: disabled"]).joined(separator: "\n") + "\n"
    }

    @objc private func copyDiagnostics() {
        let text = diagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyRefreshHook() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("/usr/bin/notifyutil -p '\(YabaiClient.refreshName)'", forType: .string)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        floatingBars.close()
        menuBarHosts.close()
        clientGeneration += 1
        Task {
            await clientTransition?.value
            await client?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
