// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
import notify
@testable import YabaiMenuKit

final class MenuTests: XCTestCase {
    private func space(_ index: Int, focus: Bool = false) -> [String: Any] {
        ["id": index + 10, "index": index, "label": "", "display": index < 4 ? 1 : 2,
         "type": "bsp", "has-focus": focus, "is-visible": focus]
    }
    private func window(_ id: Int, space: Int = 1, focus: Bool = false, floating: Bool = false,
                        sticky: Bool = false, hidden: Bool = false, minimized: Bool = false,
                        stack: Int = 0, x: Double = 0) -> [String: Any] {
        ["id": id, "pid": 0, "app": "App \(id)", "title": "Window \(id)", "space": space,
         "has-focus": focus, "is-floating": floating, "is-sticky": sticky,
         "is-hidden": hidden, "is-minimized": minimized, "stack-index": stack, "frame": ["x": x]]
    }
    private func snapshot(_ windows: [[String: Any]], spaces: [[String: Any]]? = nil) throws -> Snapshot {
        try Snapshot(spaces: JSONSerialization.data(withJSONObject: spaces ?? [space(1, focus: true), space(2)]),
                     windows: JSONSerialization.data(withJSONObject: windows))
    }

    func testWindowLayoutAndStickyAreIndependent() throws {
        let s = try snapshot([window(1, focus: true, floating: true, sticky: true, stack: 4), window(2, stack: 1), window(3)])
        XCTAssertEqual(s.windows.map(\.layout), ["float", "stack", "bsp"])
        XCTAssertEqual(s.focusedWindow?.state, "float · sticky")
        XCTAssertEqual(s.focusedSpace?.type, "bsp")
    }

    func testFilteringStableOrderAndFocusedStickyFromOtherSpace() throws {
        let s = try snapshot([window(1, x: 20), window(2, x: 10), window(3, x: 10),
                              window(4, space: 2, focus: true, sticky: true, x: 30),
                              window(5, space: 2), window(6, hidden: true), window(7, minimized: true)])
        XCTAssertEqual(s.currentWindows.map(\.id), [2, 3, 1, 4])
    }

    @MainActor
    func testSingleLineRespectsWidthKeepsFocusAndLoadsOnlyVisibleIcons() throws {
        _ = NSApplication.shared
        for count in [10, 100, 500] {
            let state = try snapshot((1...count).map { window($0, space: $0 == count ? 80 : 1, focus: $0 == count) },
                                     spaces: (1...80).map { space($0, focus: $0 == 80) })
            for width in [120, 280, 1000] {
                for height in [CGFloat(24), 37] {
                    var settings = AppSettings()
                    settings.density = .custom; settings.customWidth = width
                    settings.iconSize = 32; settings.layoutIconSize = 32; settings.fontSize = 24
                    settings.groupSpacing = 24; settings.spaceIconGap = 16
                    let bar = WidgetBarView()
                    var requested: [Int] = []
                    let start = ProcessInfo.processInfo.systemUptime
                    bar.configure(state, settings: settings, height: height) { requested.append($0.id); return nil }
                    XCTAssertLessThanOrEqual(bar.frame.width, Double(width))
                    XCTAssertTrue(bar.cells.contains { $0.target == .space(90) })
                    XCTAssertTrue(bar.cells.contains { $0.window?.id == count })
                    XCTAssertTrue(bar.cells.contains { $0.target == .create(90) })
                    XCTAssertEqual(requested.count, bar.cells.filter { $0.window != nil }.count)
                    XCTAssertEqual(requested.count, Set(requested).count)
                    XCTAssertFalse(bar.cells.contains { $0.text.contains("⌄") || $0.text.contains("•") })
                    XCTAssertTrue(bar.cells.contains { $0.group == "overflow" })
                    for pair in zip(bar.subviews, bar.subviews.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX) }
                    print("BAR_BENCH windows=\(count) width=\(width) height=\(height) elapsed_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000) icon_calls=\(requested.count)")
                }
            }
        }
    }

    @MainActor
    func testSpaceGlyphsAndAppIconsShareVerticalCenter() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .all; settings.windowScope = .hidden
        settings.spaceName = .label; settings.focusStyle = .bold
        settings.showSpaceIcons = true; settings.showCreateSpace = false
        settings.spaceWindowLayout = .off
        settings.fontSize = 14; settings.iconSize = 18
        settings.backgroundOpacity = 0; settings.unfocusedBackgroundOpacity = 0
        settings.showBorder = false; settings.unfocusedBrightness = 100
        settings.focusedSpaceNameColor = "#ff0000"
        settings.visibleSpaceNameColor = "#ff0000"
        settings.inactiveSpaceNameColor = "#ff0000"
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        for height in [CGFloat(24), 37] {
            for focused in [false, true] {
                for label in ["1", "2", "3", "gyp", "中文", "🙂", "1🙂", "Longname gyp"] {
                    var item = space(1, focus: focused); item["label"] = label
                    let state = try snapshot([window(1)], spaces: [item])
                    let bar = WidgetBarView()
                    bar.configure(state, settings: settings, height: height) { _ in icon }
                    func render() throws -> NSBitmapImageRep {
                        if label == "Longname gyp" {
                            bar.subviews[0].setFrameSize(NSSize(width: 24, height: height - 2))
                        }
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                            pixelsWide: Int(bar.bounds.width * 2), pixelsHigh: Int(height * 2),
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                        bitmap.size = bar.bounds.size
                        bar.cacheDisplay(in: bar.bounds, to: bitmap)
                        return bitmap
                    }
                    let bitmap = try render()
                    if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: directory).appendingPathComponent("alignment-\(Int(height))-\(focused)-\(label).png"))
                    }
                    var textRows: [Int] = [], iconRows: [Int] = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            guard color.alphaComponent > 0.2 else { continue }
                            if CGFloat(x) < bar.subviews[1].frame.minX * 2 {
                                XCTAssertLessThan(CGFloat(x), bar.subviews[0].frame.maxX * 2, "Text must stay inside its button")
                                textRows.append(y)
                            }
                            else if color.blueComponent > 0.8 && color.redComponent < 0.2 { iconRows.append(y) }
                        }
                    }
                    let textRange = try XCTUnwrap(textRows.min())...XCTUnwrap(textRows.max())
                    let textCenter = Double(textRange.lowerBound + textRange.upperBound) / 2
                    let iconCenter = Double(try XCTUnwrap(iconRows.min()) + XCTUnwrap(iconRows.max())) / 2
                    XCTAssertEqual(textCenter, iconCenter, accuracy: 1,
                                   "Visible glyphs must align with icons within one Retina pixel: \(label), height \(height), focused \(focused)")
                    if focused {
                        settings.focusStyle = .underline
                        bar.configure(state, settings: settings, height: height) { _ in icon }
                        let underlined = try render()
                        var addedInk = 0
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                let before = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                                let after = try XCTUnwrap(underlined.colorAt(x: x, y: y))
                                if textRange.contains(y) {
                                    XCTAssertEqual(before, after, "The underline must not move or overlap glyphs")
                                } else if after.alphaComponent > before.alphaComponent + 0.2 { addedInk += 1 }
                            }
                        }
                        XCTAssertGreaterThan(addedInk, 0, "The focus underline remains visible")
                        settings.focusStyle = .bold
                    }
                }
            }
        }
    }

    @MainActor
    func testSpaceFocusPreparesWithoutPaintingAndReusesStableButtons() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.density = .custom; settings.customWidth = 1000
        settings.spaceName = .label; settings.showSpaceIcons = false; settings.showCreateSpace = false
        settings.windowScope = .hidden
        func state(_ focused: Int) throws -> Snapshot {
            var first = space(1, focus: focused == 1), second = space(2, focus: focused == 2)
            first["label"] = "i"; second["label"] = "[Wide WWW]"
            return try snapshot([], spaces: [first, second])
        }
        for style in AppSettings.FocusStyle.allCases {
            settings.focusStyle = style
            let bar = WidgetBarView()
            bar.configure(try state(1), settings: settings) { _ in nil }
            let buttons = bar.subviews, frames = buttons.map(\.frame), size = bar.frame.size, cells = bar.cells
            let pending = try XCTUnwrap(bar.prepare(try state(2), settings: settings))
            XCTAssertEqual(bar.cells, cells)
            XCTAssertEqual(bar.frame.size, size)
            XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), buttons.map(ObjectIdentifier.init))
            XCTAssertNotNil(bar.prepare(try state(2), settings: settings), "Preparing must not mark unapplied content as rendered")
            bar.apply(pending) { _ in nil }
            XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), buttons.map(ObjectIdentifier.init))
            XCTAssertEqual(bar.subviews.map(\.frame), frames)
            XCTAssertEqual(bar.frame.size, size)
            XCTAssertEqual(bar.cells.filter(\.currentSpace).map(\.target), [.space(12)])
            XCTAssertTrue(bar.subviews[1].toolTip?.contains("Current Space 2") == true)
            XCTAssertNil(bar.prepare(try state(2), settings: settings))
            for (index, button) in bar.subviews.enumerated() {
                XCTAssertEqual(bar.cell(at: NSPoint(x: button.frame.midX, y: button.frame.midY))?.target, bar.cells[index].target)
            }
            bar.configure(try state(1), settings: settings, enabled: false) { _ in nil }
            XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), buttons.map(ObjectIdentifier.init))
            XCTAssertTrue(bar.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled })
            bar.configure(try snapshot([], spaces: [space(3, focus: true)]), settings: settings) { _ in nil }
            XCTAssertFalse(bar.subviews.contains { view in buttons.contains { $0 === view } }, "Changed targets must not repurpose a tracked button")
        }
    }

    @MainActor
    func testProcessTitleIsInlineAndRespectsVisibilitySettings() throws {
        _ = NSApplication.shared
        let state = try snapshot([window(1, focus: true)])
        var settings = AppSettings()
        settings.spaceScope = .hidden; settings.windowScope = .focused
        settings.showLayout = false; settings.spaceLayout = .off
        settings.density = .custom; settings.customWidth = 1000
        let bar = WidgetBarView()
        bar.configure(state, settings: settings) { _ in nil }
        XCTAssertEqual(try XCTUnwrap(bar.cells.first { $0.isProcess }).text, "App 1 Window 1")
        settings.showWindowTitle = false
        bar.configure(state, settings: settings) { _ in nil }
        let withoutTitle = try XCTUnwrap(bar.cells.first { $0.isProcess })
        XCTAssertEqual(withoutTitle.text, "App 1")
        XCTAssertTrue(withoutTitle.tooltip.contains("Window 1"))
        settings.showWindowTitle = true; settings.processOnlyIcon = true
        bar.configure(state, settings: settings) { _ in nil }
        XCTAssertEqual(try XCTUnwrap(bar.cells.first { $0.isProcess }).text, "")
    }

    @MainActor
    func testNarrowSpaceLabelFallbackUpdatesReservedName() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.density = .custom; settings.customWidth = 120; settings.fontSize = 24
        settings.spaceName = .numberAndLabel; settings.showSpaceIcons = false; settings.showCreateSpace = false
        settings.windowScope = .hidden
        var first = space(1, focus: true), second = space(4)
        first["label"] = "Very long label"; second["label"] = "Another long label"; second["is-visible"] = true
        let bar = WidgetBarView()
        for focus in [1, 4, 1] {
            first["has-focus"] = focus == 1; second["has-focus"] = focus == 4
            bar.configure(try snapshot([], spaces: [first, second]), settings: settings) { _ in nil }
            XCTAssertLessThanOrEqual(bar.frame.width, 120)
            XCTAssertEqual(bar.cells.map(\.spaceName), ["1", "4"])
            XCTAssertEqual(bar.cells.map(\.text), ["[1]", "[4]"])
        }
    }

    @MainActor
    func testContextMenuUsesNewHiddenSpaceWithoutRepaintingTheBar() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.hideEmptySpaces = true
        settings.showCreateSpace = false; settings.showSpaceIcons = false
        let controller = MenuBarController(settings: settings), bar = WidgetBarView()
        bar.contextMenu = { [weak controller] in controller?.barContextMenu($0) }
        let before = try snapshot([], spaces: [space(1, focus: true)])
        controller.update(before, status: ConnectionStatus(mode: .live))
        bar.configure(before, settings: settings, display: 1) { _ in nil }
        let button = try XCTUnwrap(bar.subviews.first)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let oldMenu = try XCTUnwrap(button.menu(for: event))
        XCTAssertFalse(try XCTUnwrap(oldMenu.items.first { $0.title == "Move Right" }).isEnabled)
        let after = try snapshot([], spaces: [space(1, focus: true), space(2)])
        controller.update(after, status: ConnectionStatus(mode: .live))
        XCTAssertNil(bar.prepare(after, settings: settings, display: 1))
        let newMenu = try XCTUnwrap(button.menu(for: event))
        XCTAssertTrue(try XCTUnwrap(newMenu.items.first { $0.title == "Move Right" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(oldMenu.items.first { $0.title == "Move Right" }).isEnabled, "Do not mutate a menu already being tracked")
        XCTAssertTrue(button === bar.subviews.first)
        XCTAssertEqual(bar.cells.first?.target, .space(11))
    }

    @MainActor
    func testSingleLineClicksWindowLayoutsBrightnessAndFallbackMenu() throws {
        _ = NSApplication.shared
        let state = try snapshot([window(1, focus: true, floating: true), window(2, stack: 2), window(3)])
        var settings = AppSettings()
        settings.density = .custom; settings.customWidth = 1000
        settings.unfocusedBrightness = 20; settings.spaceIconGap = 0
        let controller = MenuBarController(settings: settings)
        controller.setupItem()
        defer { if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) } }
        controller.update(state, status: ConnectionStatus(mode: .live))
        let bar = try XCTUnwrap(controller.widgetBar)
        XCTAssertFalse(bar.cells.contains( where: \.isProcess))
        XCTAssertEqual(bar.cells.compactMap { $0.window == nil ? nil : $0.symbol }, ["macwindow.on.rectangle", "square.stack.3d.up", "rectangle.split.2x2"])
        XCTAssertEqual(bar.cells.filter { $0.window != nil }.map(\.opacity), [1, 0.2, 0.2])
        let menuEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        var chosen: Int?
        controller.focusAction = { _, window in chosen = window }
        for (index, cell) in bar.cells.enumerated() {
            let button = try XCTUnwrap(bar.subviews[index] as? NSButton)
            let menu = button.menu(for: menuEvent)
            XCTAssertTrue(menu?.items.contains { $0.title == "Open Full Menu" } == true)
            XCTAssertTrue(menu?.items.contains { $0.title == "Settings…" } == true)
            if let window = cell.window {
                XCTAssertTrue(bar.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
                button.performClick(nil)
                XCTAssertEqual(chosen, window.id)
            }
        }
        settings.spaceScope = .hidden; settings.windowScope = .hidden
        bar.configure(state, settings: settings) { _ in XCTFail("Hidden widgets must not load icons"); return nil }
        XCTAssertEqual(bar.cells.map(\.text), ["Yabai"])
        XCTAssertEqual(bar.cells[0].target, .menu)
    }

    @MainActor
    func testConnectionWarningsStayInMenuWithoutBarBadges() throws {
        _ = NSApplication.shared
        let state = try snapshot([])
        for placement in [AppSettings.Placement.menuBar, .floating] {
            var settings = AppSettings(); settings.placement = placement; settings.spaceScope = .all
            let controller = MenuBarController(settings: settings)
            controller.setupItem()
            defer { controller.floatingBars.close(); if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) } }
            for status in [ConnectionStatus(mode: .limited, detail: "Test connection detail"),
                           ConnectionStatus(mode: .disconnected, detail: "Test connection detail"),
                           ConnectionStatus(mode: .live, actionError: "Test connection detail")] {
                controller.update(state, status: status)
                XCTAssertFalse(controller.statusItem?.button?.title.contains("!") ?? false)
                XCTAssertFalse(controller.widgetBar?.cells.contains { $0.group == "attention" } ?? false)
                controller.menuNeedsUpdate(controller.fullMenu)
                XCTAssertTrue(controller.fullMenu.items.contains { $0.title.contains("Test connection detail") }, "Keep the useful diagnosis in the menu")
            }
            controller.update(nil, status: ConnectionStatus(mode: .disconnected, detail: "Test connection detail"))
            XCTAssertFalse(controller.statusItem?.button?.title.contains("!") ?? false)
        }
    }

    @MainActor
    func testNativeStatusWindowMouseEventsSelectCellsWithoutOpeningFullMenu() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        @MainActor final class MenuProbe: NSObject, NSMenuDelegate {
            var opens = 0
            var timers: [Timer] = []
            var release: NSEvent?
            @objc func releaseMouse() { if let release { NSApp.postEvent(release, atStart: true) } }
            func menuWillOpen(_ menu: NSMenu) {
                opens += 1
                let timer = Timer(timeInterval: 0.01, target: menu, selector: #selector(NSMenu.cancelTrackingWithoutAnimation), userInfo: nil, repeats: false)
                RunLoop.current.add(timer, forMode: .eventTracking)
                RunLoop.current.add(timer, forMode: .default)
                timers.append(timer)
            }
        }
        var settings = AppSettings()
        settings.placement = .menuBar; settings.spaceScope = .all
        settings.showCreateSpace = false; settings.density = .custom; settings.customWidth = 500
        let controller = MenuBarController(settings: settings)
        controller.setupItem()
        let item = try XCTUnwrap(controller.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        controller.update(try snapshot([window(1, focus: true)]), status: ConnectionStatus(mode: .live))
        let bar = try XCTUnwrap(controller.widgetBar)
        let native = try XCTUnwrap(item.button?.window)
        let full = controller.fullMenu
        XCTAssertNil(item.menu, "Space clicks must not be bound to automatic menu tracking")
        full.removeAllItems()
        full.addItem(withTitle: "Test menu", action: nil, keyEquivalent: "")
        let probe = MenuProbe()
        full.delegate = probe
        defer { probe.timers.forEach { $0.invalidate() }; full.delegate = controller }
        var choices: [(Int?, Int?)] = []
        controller.focusAction = { choices.append(($0, $1)) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let nativeWindows = NSApp.windows.filter { $0.level == .statusBar && abs($0.frame.width - native.frame.width) < 1 }
        XCTAssertEqual(nativeWindows.count, NSScreen.screens.count, "Exercise every actual status-window replica")
        for native in nativeWindows {
          for target in [BarTarget.space(12), .window(1, 11)] {
            let index = try XCTUnwrap(bar.cells.firstIndex { $0.target == target })
            let button = bar.subviews[index]
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: down.timestamp + 0.01, windowNumber: native.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            probe.release = up
            let watchdog = Timer(timeInterval: 0.2, target: probe, selector: #selector(MenuProbe.releaseMouse), userInfo: nil, repeats: false)
            RunLoop.current.add(watchdog, forMode: .eventTracking)
            RunLoop.current.add(watchdog, forMode: .default)
            // Dispatch the recorded coordinates without postEvent rebasing offscreen test replicas.
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            watchdog.invalidate()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
          }
        }
        XCTAssertEqual(probe.opens, 0, "Native left-click must not enter automatic full-menu tracking")
        XCTAssertEqual(choices.count, nativeWindows.count * 2)
        for index in stride(from: 0, to: choices.count - 1, by: 2) {
            XCTAssertEqual(choices[index].0, 2); XCTAssertNil(choices[index].1)
            XCTAssertEqual(choices[index + 1].1, 1)
        }
        let cancelPoint = bar.subviews[0].convert(NSPoint(x: 4, y: 4), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: cancelPoint, modifierFlags: [], timestamp: 0, windowNumber: native.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -20, y: cancelPoint.y), modifierFlags: [], timestamp: 0.01, windowNumber: native.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
        let before = choices.count
        NSApp.sendEvent(down); NSApp.sendEvent(up)
        XCTAssertEqual(choices.count, before, "Releasing outside the original cell cancels selection")
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 0, y: 12), modifierFlags: [], timestamp: 1, windowNumber: native.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 1))
        NSApp.sendEvent(right)
        XCTAssertEqual(probe.opens, 1, "The native slot must retain its right-click full-menu entry")
        let controlClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 0, y: 12), modifierFlags: .control, timestamp: 2, windowNumber: native.windowNumber, context: nil, eventNumber: 6, clickCount: 1, pressure: 1))
        NSApp.sendEvent(controlClick)
        XCTAssertEqual(probe.opens, 2, "Control-click remains a context-menu gesture")
        let commandClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 0, y: 12), modifierFlags: .command, timestamp: 3, windowNumber: native.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 1))
        XCTAssertTrue(controller.handleStatusMouse(commandClick) === commandClick, "Let macOS handle Command reordering")
    }

    func testDuplicateAppUsesFocusedWindowLayout() throws {
        var focused = window(2, focus: true, floating: true)
        focused["app"] = "App 1"
        let state = try snapshot([window(1), focused])
        let content = WidgetContent(snapshot: state, settings: AppSettings())
        XCTAssertEqual(content.groups[0].windows.map(\.id), [2])
        XCTAssertEqual(content.groups[0].windows[0].layout, "float")
    }

    func testEmptyDesktopAndNoStaleFocus() throws {
        XCTAssertNil(try snapshot([]).focusedWindow)
        XCTAssertTrue(try snapshot([]).currentWindows.isEmpty)
        XCTAssertTrue(try snapshot([window(1)], spaces: [space(1)]).currentWindows.isEmpty)
    }

    func testRejectsDuplicateIDsMissingFieldsAndInvalidJSON() throws {
        XCTAssertThrowsError(try snapshot([window(1), window(1)]))
        XCTAssertThrowsError(try snapshot([], spaces: [space(1), space(1)]))
        var incomplete = window(1)
        incomplete.removeValue(forKey: "space")
        XCTAssertThrowsError(try snapshot([incomplete]))
        XCTAssertThrowsError(try Snapshot(spaces: Data("null".utf8), windows: Data("[]".utf8)))
        XCTAssertThrowsError(try Snapshot(spaces: JSONSerialization.data(withJSONObject: [space(1)]), windows: Data("[{\"frame\":{\"x\":NaN}}]".utf8)))
        XCTAssertThrowsError(try Snapshot(spaces: Data("[\n".utf8), windows: Data("[]".utf8)), "Incomplete output observed with no active displays must never replace valid state")
    }

    func testAnonymizedYabai716Fixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "yabai-7.1.16", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let state = try Snapshot(spaces: JSONSerialization.data(withJSONObject: fixture["spaces"]!), windows: JSONSerialization.data(withJSONObject: fixture["windows"]!))
        XCTAssertFalse(state.spaces.isEmpty)
        XCTAssertFalse(state.windows.isEmpty)
    }

    @MainActor
    func testProjectedYabai716FieldsStillDecodeNonemptyWindows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "yabai-7.1.16", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func project(_ key: String, fields: String) throws -> Data {
            let names = Set(fields.split(separator: ",").map(String.init))
            let values = try XCTUnwrap(fixture[key] as? [[String: Any]])
            return try JSONSerialization.data(withJSONObject: values.map { $0.filter { names.contains($0.key) } })
        }
        let projected = try Snapshot(spaces: project("spaces", fields: YabaiClient.spaceFields),
                                     windows: project("windows", fields: YabaiClient.windowFields))
        XCTAssertFalse(projected.windows.isEmpty)
        XCTAssertFalse(projected.spaces.isEmpty)
        XCTAssertFalse(YabaiClient.windowFields.contains("opacity"))
        XCTAssertFalse(YabaiClient.windowFields.contains("shadow"))
    }

    func testCommandErrorAndTimeout() async throws {
        let output = try await Command.run("/bin/sh", ["-c", "printf stdout; printf stderr >&2"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "stdout")
        do {
            _ = try await Command.run("/bin/sh", ["-c", "printf failure >&2; exit 7"])
            XCTFail("Expected nonzero exit to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("failure")) }
        let start = Date()
        do {
            _ = try await Command.run("/bin/sleep", ["10"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(start), 2) }
        let large = try await Command.run("/bin/sh", ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000"])
        XCTAssertEqual(large.count, 200000)
        let pipeStart = Date()
        do {
            _ = try await Command.run("/bin/sh", ["-c", "/bin/sleep 1 & printf done"], timeout: 0.1)
            XCTFail("A descendant keeping stdout open must still respect the deadline")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(pipeStart), 0.7) }
    }

    func testOnlyTheExactAlreadyFocusedSpaceFailureIsRecoverable() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }
        try Data("#!/bin/sh\nprintf 'cannot focus an already focused space.\\n' >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await Command.run(executable.path, ["-m", "space", "--focus", "1"])
            XCTFail("Expected the known yabai failure")
        } catch MenuError.alreadyFocusedSpace { }
        catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await Command.run(executable.path, ["-m", "window", "--focus", "1"])
            XCTFail("An unrelated command must fail")
        } catch MenuError.alreadyFocusedSpace { XCTFail("Only Space focus can ignore this diagnostic") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Command failed")) }
    }

    @MainActor
    func testLiveYabaiNotificationsAndCleanup() async throws {
        guard let path = ProcessInfo.processInfo.environment["YABAI_MENU_LIVE_PATH"] else {
            throw XCTSkip("Set YABAI_MENU_LIVE_PATH for the local integration check")
        }
        func signals() async throws -> [[String: AnyHashable]] {
            let data = try await Command.run(path, ["-m", "signal", "--list"])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: AnyHashable]])
        }
        let before = try await signals()
        guard !before.contains(where: { ($0["label"] as? String)?.hasPrefix("yabai-menu-") == true }) else {
            throw XCTSkip("Quit Yabai Menu before the integration test so its signals are not disturbed")
        }
        let client = YabaiClient(path: path)
        let first = expectation(description: "Initial live snapshot")
        var firstPending = true
        var notificationUpdate: XCTestExpectation?
        var latest: Snapshot?
        client.onUpdate = { snapshot, status in
            XCTAssertNil(status.detail)
            guard let snapshot else { return }
            latest = snapshot
            if firstPending { firstPending = false; first.fulfill() }
            if let pending = notificationUpdate { notificationUpdate = nil; pending.fulfill() }
        }
        client.start()
        await fulfillment(of: [first], timeout: 5)
        var registered = [[String: AnyHashable]]()
        for _ in 0..<20 {
            registered = try await signals()
            if registered.filter({ ($0["label"] as? String)?.hasPrefix("yabai-menu-") == true }).count == YabaiClient.events.count { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(registered.filter { ($0["label"] as? String)?.hasPrefix("yabai-menu-") == true }.count, YabaiClient.events.count)
        let notified = expectation(description: "Darwin notification refresh")
        notificationUpdate = notified
        notify_post("user.uid.\(getuid()).dev.gladio.yabai-menu.refresh")
        await fulfillment(of: [notified], timeout: 2)
        await client.stop()
        let after = try await signals()
        XCTAssertEqual(after, before, "Existing yabai signals must be preserved exactly")
        let controller = MenuBarController()
        controller.setupItem()
        let item = try XCTUnwrap(controller.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        controller.update(try XCTUnwrap(latest), status: ConnectionStatus(mode: .live))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(item.button?.bounds.width ?? 0, 30)
        XCTAssertFalse(item.button?.attributedTitle.string.contains("!") ?? true)
        if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let counts: [String: Any] = ["spaces": latest?.spaces.count ?? 0,
                                       "windows": latest?.windows.count ?? 0,
                                       "owned_signals": YabaiClient.events.count, "existing_signals_preserved": true,
                                       "status_item_width": item.button?.bounds.width ?? 0]
            try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-check.json"))
        }
    }

    @MainActor
    func testGeometryOnlyUpdatesKeepExistingButtons() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let controller = MenuBarController()
        controller.setupItem()
        defer { if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) } }
        controller.update(try snapshot([window(1, focus: true, x: 20), window(2, x: 40)]), status: ConnectionStatus(mode: .live))
        let before = try XCTUnwrap(controller.widgetBar).subviews.map(ObjectIdentifier.init)
        controller.update(try snapshot([window(1, focus: true, x: 30), window(2, x: 50)]), status: ConnectionStatus(mode: .live))
        XCTAssertEqual(controller.widgetBar?.subviews.map(ObjectIdentifier.init), before,
                       "Pure movement with unchanged labels, order and state must not rebuild native buttons")
    }

    @MainActor
    func testTrackingMenuDoesNotMoveTargetsAndResolvesStableIDs() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("Interactive macOS session required") }
        _ = NSApplication.shared
        let controller = MenuBarController()
        controller.setupItem()
        let item = try XCTUnwrap(controller.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let initial = try snapshot([window(1), window(2, space: 999), window(3, minimized: true)])
        controller.update(initial, status: ConnectionStatus(mode: .live))
        let menu = controller.fullMenu
        controller.menuNeedsUpdate(menu)
        let preparedRows = menu.items.map(ObjectIdentifier.init)
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), preparedRows, "menuWillOpen must not change the menu structure")
        XCTAssertTrue(menu.items.contains { $0.title == "Other Windows" })
        XCTAssertTrue(menu.items.contains { $0.tag == 2 && $0.indentationLevel == 1 })
        XCTAssertTrue(menu.items.contains { $0.tag == 3 && $0.title.contains("minimized") })
        let target = try XCTUnwrap(menu.items.first { $0.tag == 2 && $0.indentationLevel == 0 })
        let rows = menu.items.map(ObjectIdentifier.init)
        var moved = space(2)
        moved["index"] = 4
        let next = try snapshot([window(1)], spaces: [space(1, focus: true), moved])
        controller.update(next, status: ConnectionStatus(mode: .live))
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), rows)
        var chosen: Int?
        controller.focusAction = { space, _ in chosen = space }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(target.action), to: target.target, from: target))
        XCTAssertEqual(chosen, 4, "Stable Space ID must resolve to its new index")
        controller.menuDidClose(menu)
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.tag == 4 && $0.indentationLevel == 0 })
    }

    @MainActor
    func testNativeMenuActionsAndLightDarkRendering() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else {
            throw XCTSkip("Set YABAI_MENU_UI_TESTS=1 in an interactive macOS session")
        }
        _ = NSApplication.shared
        let controller = MenuBarController()
        controller.setupItem()
        let item = try XCTUnwrap(controller.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let state = try snapshot([window(1, focus: true, floating: true, sticky: true), window(2)],
                                 spaces: (1...6).map { space($0, focus: $0 == 1) })
        controller.update(state, status: ConnectionStatus(mode: .live))
        let button = try XCTUnwrap(item.button)
        let bar = try XCTUnwrap(controller.widgetBar)
        XCTAssertTrue(bar.cells.contains { $0.target == .space(11) })
        XCTAssertTrue(bar.cells.contains { $0.tooltip.contains("float · sticky") })
        XCTAssertLessThanOrEqual(bar.frame.width, AppSettings().width)
        let menu = controller.fullMenu
        controller.menuNeedsUpdate(menu)
        var chosenSpace: Int?, chosenWindow: Int?
        controller.focusAction = { chosenSpace = $0; chosenWindow = $1 }
        let spaceItem = try XCTUnwrap(menu.items.first { $0.tag == 2 && $0.indentationLevel == 0 })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(spaceItem.action), to: spaceItem.target, from: spaceItem))
        XCTAssertEqual(chosenSpace, 2)
        XCTAssertNil(chosenWindow)
        let windowItem = try XCTUnwrap(menu.items.first { $0.tag == 1 && $0.indentationLevel == 1 })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(windowItem.action), to: windowItem.target, from: windowItem))
        XCTAssertEqual(chosenSpace, 1)
        XCTAssertEqual(chosenWindow, 1)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            button.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            button.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 100)
            if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu-\(name).png"))
            }
        }
        controller.update(state, status: ConnectionStatus(mode: .disconnected, detail: "offline"))
        XCTAssertTrue(controller.widgetBar?.cells.contains { $0.text == "!" } == true)
        XCTAssertEqual(button.toolTip, "offline")
        controller.update(try snapshot([]), status: ConnectionStatus(mode: .live))
        XCTAssertFalse(controller.widgetBar?.cells.contains( where: \.isProcess) == true)
        XCTAssertFalse(controller.widgetBar?.cells.contains { $0.tooltip.contains("sticky") } == true)
    }
    @MainActor
    func testZeroSizedStickyAuxiliaryWindowDoesNotCreateIcon() throws {
        _ = NSApplication.shared
        // Sanitized metadata from 1Password's invisible background window on macOS.
        let auxiliary: [String: Any] = [
            "id": 791, "pid": 741, "app": "1Password", "title": "", "space": 2, "display": 1,
            "subrole": "AXStandardWindow", "has-focus": false, "is-visible": false,
            "is-floating": true, "is-sticky": true, "is-hidden": false, "is-minimized": false,
            "stack-index": 0, "frame": ["x": 0, "y": 0, "w": 0, "h": 0]
        ]
        var settings = AppSettings()
        settings.spaceScope = .all; settings.windowScope = .hidden
        let bar = WidgetBarView()
        var realWindow = auxiliary
        realWindow["id"] = 792; realWindow["is-visible"] = true
        realWindow["frame"] = ["x": 100, "y": 100, "w": 500, "h": 400]
        for separate in [true, false] {
            settings.separateSticky = separate
            bar.configure(try snapshot([auxiliary]), settings: settings) { _ in nil }
            XCTAssertFalse(bar.cells.contains { $0.window?.id == 791 },
                           "An invisible auxiliary window must not create an icon in either group")
            bar.configure(try snapshot([auxiliary, realWindow]), settings: settings) { _ in nil }
            XCTAssertEqual(bar.cells.compactMap { $0.window?.id }, [792],
                           "The same app's real sticky window must remain available after deduplication")
        }
        settings.windowScope = .all
        XCTAssertEqual(WidgetContent(snapshot: try snapshot([auxiliary]), settings: settings).process.map(\.id), [791],
                       "The all-window recovery view retains accepted windows independently of Space icons")
    }

    func testStickyVisibilityPreservesOtherSpaceIconsAndWindowRecovery() throws {
        let legacySticky = window(1, sticky: true)
        var otherSpace = window(2, space: 2); otherSpace["is-visible"] = false
        var hidden = window(3, sticky: true, hidden: true); hidden["is-visible"] = false
        var minimized = window(4, sticky: true, minimized: true); minimized["is-visible"] = false
        let state = try snapshot([legacySticky, otherSpace, hidden, minimized])
        var settings = AppSettings()
        settings.spaceScope = .all; settings.windowScope = .all; settings.separateSticky = true
        let content = WidgetContent(snapshot: state, settings: settings)
        XCTAssertEqual(content.sticky.map(\.id), [1], "An omitted visibility field remains compatible")
        XCTAssertEqual(content.groups.flatMap { $0.windows.map(\.id) }, [2],
                       "Non-sticky windows on another Space must keep their app icons")
        XCTAssertEqual(Set(content.process.map(\.id)), Set([1, 2, 3, 4]),
                       "Hidden and minimized windows remain available for recovery")
    }

    func testWidgetFilteringAndProcessSemantics() throws {
        var duplicate = window(2)
        duplicate["app"] = "App 1"
        var dialog = window(8)
        dialog["subrole"] = "AXDialog"
        var labeled = space(2); labeled["label"] = "Read"
        var visible = space(3); visible["is-visible"] = true
        let state = try snapshot([window(1), duplicate, window(3, space: 2, sticky: true),
                                  window(4, space: 2, hidden: true), window(5, minimized: true), dialog],
                                 spaces: [space(1, focus: true), labeled, visible, space(4)])
        var settings = AppSettings()
        settings.windowScope = .currentSpace
        settings.hideEmptySpaces = true
        var content = WidgetContent(snapshot: state, settings: settings)
        XCTAssertEqual(content.groups.map { $0.space.index }, [1, 2, 3])
        XCTAssertEqual(content.groups[0].windows.map(\.id), [1])
        XCTAssertTrue(content.groups[1].windows.isEmpty, "A sticky occupant keeps the Space even when its icon moves to the pinned group")
        XCTAssertEqual(content.sticky.map(\.id), [3])
        XCTAssertEqual(content.process.map(\.id), [1, 2, 5], "Process keeps minimized windows; AXDialog is omitted from widgets")
        settings.exclusions = "App 1, Read, "
        content = WidgetContent(snapshot: state, settings: settings)
        XCTAssertEqual(content.groups.map { $0.space.index }, [1, 3])
        XCTAssertTrue(content.groups[0].windows.isEmpty)
        XCTAssertEqual(content.sticky.map(\.id), [3], "Pinned apps have their own exclusion semantics")
        settings.exclusions = "[, "
        settings.exclusionsAsRegex = true
        XCTAssertEqual(WidgetContent(snapshot: state, settings: settings).groups.count, 3)
        settings.exclusions = "^App 1$"
        XCTAssertTrue(WidgetContent(snapshot: state, settings: settings).groups[0].windows.isEmpty)
        settings.exclusions = ""
        settings.exclusionsAsRegex = false
        settings.titleExclusions = "Window 1"
        settings.hideDuplicateApps = false
        XCTAssertEqual(WidgetContent(snapshot: state, settings: settings).groups[0].windows.map(\.id), [2])
        settings.windowScope = .all
        XCTAssertTrue(WidgetContent(snapshot: state, settings: settings).process.contains { $0.hidden })
        settings.windowScope = .currentSpace
        let noFocus = try snapshot([window(9, space: 99, focus: true, sticky: true)], spaces: [space(1)])
        XCTAssertTrue(WidgetContent(snapshot: noFocus, settings: settings).process.isEmpty)
    }

    @MainActor
    func testProcessWidthFocusAndVisibleIconLoading() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let windows: [[String: Any]] = (1...500).map { id in
            let spaceIndex = id == 500 ? 50 : (id % 49 + 1)
            return window(id, space: spaceIndex, focus: id == 500, x: Double(id))
        }
        let spaces = (1...50).map { space($0, focus: $0 == 50) }
        let state = try snapshot(windows, spaces: spaces)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for width in [160, 280, 480] {
            var settings = AppSettings()
            settings.density = .custom; settings.customWidth = width; settings.windowScope = .all
            settings.fontSize = width == 280 ? 11 : 14
            settings.iconSize = 18; settings.groupSpacing = 8
            let bar = WidgetBarView()
            var calls = 0
            let start = ProcessInfo.processInfo.systemUptime
            bar.configure(state, settings: settings) { _ in calls += 1; return image }
            print("PROCESS_BENCH windows=500 spaces=50 width=\(width) elapsed_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000) icon_calls=\(calls)")
            XCTAssertLessThanOrEqual(bar.frame.width, Double(width))
            XCTAssertTrue(bar.cells.contains { $0.target == .space(60) })
            XCTAssertTrue(bar.cells.contains { $0.isProcess && $0.window?.id == 500 })
            XCTAssertEqual(calls, bar.cells.filter { $0.window != nil }.count)
            XCTAssertTrue(bar.cells.contains { $0.group == "overflow" })
            if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    bar.appearance = NSAppearance(named: appearance)
                    let bitmap = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                    bar.cacheDisplay(in: bar.bounds, to: bitmap)
                    let output = NSImage(size: bar.bounds.size)
                    output.lockFocus()
                    bar.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill(); bar.bounds.fill()
                    }
                    NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bar.bounds.size).draw(in: bar.bounds)
                    output.unlockFocus()
                    let png = try XCTUnwrap(NSBitmapImageRep(data: output.tiffRepresentation!))
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try png.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("process-\(width)-\(name).png"))
                }
            }
            var selected: BarTarget?
            bar.onSelect = { selected = $0 }
            let index = try XCTUnwrap(bar.cells.firstIndex { $0.isProcess && $0.window?.id == 500 })
            let button = try XCTUnwrap(bar.subviews[index] as? NSButton)
            XCTAssertTrue(bar.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
            button.performClick(nil)
            XCTAssertEqual(selected, .window(500, nil))
            bar.configure(try snapshot([]), settings: settings) { _ in image }
            selected = nil
            button.performClick(nil)
            XCTAssertEqual(selected, .window(500, nil), "A button retained during tracking must keep its original stable target")
            bar.configure(state, settings: settings, enabled: false) { _ in image }
            XCTAssertTrue(bar.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.isEnabled == (bar.cells[$0.tag].target == .menu) })
        }
    }

}
