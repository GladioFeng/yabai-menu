// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import XCTest
@testable import YabaiMenuKit

@MainActor
final class DisplayTests: XCTestCase {
    private func state(focused: Int = 4, visible: [Int] = [1, 4], x: Double = 0, excludingPID: Int32? = nil) throws -> Snapshot {
        let spaces: [[String: Any]] = (1...6).map {
            ["id": $0 + 10, "index": $0, "label": "Long Space Name \($0)", "display": $0 < 4 ? 1 : 2,
             "type": "bsp", "has-focus": $0 == focused, "is-visible": visible.contains($0)]
        }
        let windows: [[String: Any]] = [1, 4].map { index -> [String: Any] in
            let frame: [String: Double] = ["x": x + Double(index)]
            return ["id": index + 100, "pid": index + 1000, "app": "App \(index)", "title": "Window \(index)",
             "display": index == 1 ? 1 : 2, "space": index, "has-focus": index == focused,
             "is-floating": true, "is-sticky": false, "is-hidden": false, "is-minimized": false,
             "stack-index": 0, "frame": frame]
        }
        return try Snapshot(spaces: JSONSerialization.data(withJSONObject: spaces),
                            windows: JSONSerialization.data(withJSONObject: windows),
                            displays: Data(#"[{"id":101,"index":1,"uuid":"left"},{"id":202,"index":2,"uuid":"right"}]"#.utf8),
                            excludingPID: excludingPID)
    }

    func testPerDisplayContentAndIndependentCurrentSpaces() throws {
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.windowScope = .currentSpace
        for focused in [1, 4] {
            let snapshot = try state(focused: focused)
            for display in [1, 2] {
                let first = display == 1 ? 1 : 4
                let local = WidgetContent(snapshot: snapshot, settings: settings, display: display)
                XCTAssertEqual(local.activeSpace?.index, first)
                XCTAssertEqual(local.groups.map { $0.space.index }, Array(first...(first + 2)))
                XCTAssertEqual(local.groups.filter(\.active).map { $0.space.index }, [first])
                XCTAssertEqual(local.process.map(\.id), [first + 100])
                var all = settings; all.spaceScope = .all
                let combined = WidgetContent(snapshot: snapshot, settings: all, display: display)
                XCTAssertEqual(combined.groups.filter(\.active).map { $0.space.index }, [first])
                XCTAssertEqual(combined.groups.filter { $0.space.visible }.map { $0.space.index }, [1, 4])
                XCTAssertEqual(combined.process.map(\.id), [first + 100])
                XCTAssertEqual(combined.process.first?.focused, focused == first)
            }
        }
        XCTAssertEqual(try state(excludingPID: 1004).windows.map(\.id), [101])
        XCTAssertThrowsError(try Snapshot(spaces: Data("[]".utf8), windows: Data("[]".utf8),
            displays: Data(#"[{"id":101,"index":1},{"id":101,"index":2}]"#.utf8)))
    }

    func testDisplaySpacingAndNarrowLabelsKeepTheirTargets() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.density = .custom; settings.customWidth = 1000
        settings.showSpaceIcons = false; settings.showCreateSpace = false
        settings.displayGap = 37; settings.groupSpacing = 4; settings.displaySeparatorStyle = .none
        let bar = WidgetBarView()
        let snapshot = try state()
        bar.configure(snapshot, settings: settings, display: 1) { _ in nil }
        XCTAssertEqual(bar.subviews[3].frame.minX - bar.subviews[2].frame.maxX, 37)
        XCTAssertEqual(bar.subviews[1].frame.minX - bar.subviews[0].frame.maxX, 4)
        XCTAssertEqual(bar.cells.filter(\.focus).map(\.text), ["[1]"])
        XCTAssertEqual(bar.cells.filter(\.visible).count, 2)
        settings.customWidth = 120; settings.fontSize = 24; settings.spaceName = .numberAndLabel
        bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
        XCTAssertLessThanOrEqual(bar.frame.width, 120)
        XCTAssertTrue(bar.cells.contains { $0.target == .space(11) && $0.text == "[1]" })
        XCTAssertTrue(bar.cells.contains { $0.target == .space(14) && $0.text == "[4]" })
        var selected: BarTarget?
        bar.onSelect = { selected = $0 }
        for (index, cell) in bar.cells.enumerated() {
            (bar.subviews[index] as? NSButton)?.performClick(nil)
            XCTAssertEqual(selected, cell.target)
        }
    }

    func testDisplayFocusKeepsUnchangedDrawingAndReusesIcons() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.windowScope = .hidden
        settings.spaceName = .label; settings.focusStyle = .underline
        settings.showCreateSpace = false; settings.density = .custom; settings.customWidth = 1000
        for display in [1, 2] {
            let bar = WidgetBarView()
            var menusBuilt = 0
            bar.contextMenu = { _ in menusBuilt += 1; return NSMenu() }
            let initial = try XCTUnwrap(bar.prepare(try state(focused: 4), settings: settings, display: display))
            bar.apply(initial) { _ in nil }
            let labels = bar.cells.indices.filter { if case .space = bar.cells[$0].target { return true }; return false }
            let labelViews = labels.map { bar.subviews[$0] }
            let next = try XCTUnwrap(bar.prepare(try state(focused: 1), settings: settings, display: display))
            XCTAssertEqual(initial.regularFont, next.regularFont)
            XCTAssertEqual(initial.boldFont, next.boldFont)
            XCTAssertEqual(initial.frames, next.frames)
            XCTAssertTrue(zip(initial.backgrounds, next.backgrounds).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 })
            var iconLoads = 0
            bar.apply(next) { _ in iconLoads += 1; return nil }
            XCTAssertEqual(iconLoads, 0, "A brightness change must reuse the existing application image")
            for (index, view) in zip(labels, labelViews) {
                XCTAssertTrue(bar.subviews[index] === view)
                XCTAssertTrue(initial.cells[index].hasSameDrawing(as: next.cells[index]), "Display \(display): keyboard focus must not change its Space labels")
            }
            XCTAssertEqual(menusBuilt, 0, "Render updates must not build contextual menus")
            XCTAssertTrue(bar.cells.indices.filter { bar.cells[$0].window != nil }.allSatisfy { !initial.cells[$0].hasSameDrawing(as: next.cells[$0]) })
        }
    }

    func testTitleMetadataDoesNotChangeDrawingOrReloadIcons() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.windowScope = .hidden
        settings.showCreateSpace = false
        let before = try state(), left = WidgetBarView(), right = WidgetBarView()
        left.configure(before, settings: settings, display: 1) { _ in nil }
        right.configure(before, settings: settings, display: 2) { _ in nil }
        let beforeCells = left.cells
        var after = before
        after.windows[0] = after.windows[0].replacingTitle("Updated title")
        XCTAssertNil(right.prepare(after, settings: settings, display: 2), "Unchanged per-display content must skip apply entirely")
        var iconLoads = 0
        left.configure(after, settings: settings, display: 1) { _ in iconLoads += 1; return nil }
        XCTAssertEqual(iconLoads, 0)
        XCTAssertTrue(left.subviews.contains { $0.toolTip?.contains("Updated title") == true })
        XCTAssertTrue(zip(beforeCells, left.cells).allSatisfy { $0.hasSameDrawing(as: $1) })
    }

    func testSpaceSwitchDoesNotPrepareUnchangedOtherDisplay() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.windowScope = .hidden
        settings.showCreateSpace = false
        let left = WidgetBarView(), right = WidgetBarView()
        let before = try state(focused: 1), after = try state(focused: 2, visible: [2, 4])
        left.configure(before, settings: settings, display: 1) { _ in nil }
        right.configure(before, settings: settings, display: 2) { _ in nil }
        XCTAssertNotNil(left.prepare(after, settings: settings, display: 1))
        XCTAssertNil(right.prepare(after, settings: settings, display: 2), "A Space switch on display 1 must not update display 2's unchanged content")
    }

    func testOtherDisplayCurrentSpaceKeepsItsMarkerWithoutBackground() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .all
        settings.spaceName = .number
        settings.focusStyle = .brackets
        settings.unfocusedBackgroundOpacity = 0
        settings.showSpaceIcons = false
        settings.showCreateSpace = false
        settings.density = .custom; settings.customWidth = 1000
        let bar = WidgetBarView()
        for focused in [1, 4] {
            for host in [1, 2] {
                bar.configure(try state(focused: focused), settings: settings, display: host) { _ in nil }
                XCTAssertEqual(bar.cells.filter(\.visible).map(\.text), ["[1]", "[4]"], "Each screen's current Space needs a marker even with a transparent background")
                XCTAssertEqual(bar.cells.filter(\.focus).count, 1, "Keep the separate focused/visible color roles")
            }
        }
    }

    func testDisplaySeparatorsUseOnlySurvivingSpaceBoundaries() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .all; settings.showSpaceIcons = false; settings.showCreateSpace = false
        settings.density = .custom; settings.customWidth = 1000
        settings.displayGap = 0; settings.displaySeparatorStyle = .none
        let bar = WidgetBarView(), snapshot = try state()
        bar.configure(snapshot, settings: settings) { _ in nil }
        let width = bar.frame.width, targets = bar.cells.map(\.target)
        XCTAssertTrue(bar.displaySeparators.isEmpty)
        settings.displaySeparatorStyle = .line
        bar.configure(snapshot, settings: settings) { _ in nil }
        XCTAssertEqual(bar.cells.map(\.target), targets)
        XCTAssertEqual(bar.frame.width, width + 12.5)
        XCTAssertEqual(bar.displaySeparators.count, 1)
        let divider = try XCTUnwrap(bar.displaySeparators.first)
        XCTAssertGreaterThan(divider, bar.subviews[2].frame.maxX)
        XCTAssertLessThan(divider, bar.subviews[3].frame.minX)
        settings.exclusions = "Long Space Name 1, Long Space Name 2, Long Space Name 3"
        bar.configure(snapshot, settings: settings) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty)
        settings.exclusions = ""; settings.spaceScope = .focusedDisplay
        bar.configure(snapshot, settings: settings, display: 1) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty)
        settings.spaceScope = .hidden; settings.windowScope = .all
        bar.configure(snapshot, settings: settings) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty, "Process rows are not Space display groups")
    }

    func testSpaceProcessDividerTracksTheVisibleSectionBoundary() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .focusedDisplay; settings.windowScope = .all
        settings.showSpaceIcons = false; settings.showCreateSpace = true
        settings.density = .custom; settings.customWidth = 1000
        settings.groupSpacing = 0; settings.displaySeparatorThickness = 4; settings.displaySeparatorStyle = .line
        let bar = WidgetBarView(), snapshot = try state()
        for layout in [AppSettings.LayoutStyle.icon, .off] {
            settings.spaceLayout = layout
            bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
            let first = try XCTUnwrap(bar.cells.firstIndex(where: \.isProcess))
            let divider = try XCTUnwrap(bar.displaySeparators.first)
            XCTAssertEqual(bar.displaySeparators.count, 1)
            XCTAssertGreaterThanOrEqual(divider - 2, bar.subviews[first - 1].frame.maxX)
            XCTAssertLessThanOrEqual(divider + 2, bar.subviews[first].frame.minX)
        }
        settings.displaySeparatorPadding = 9
        bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
        let first = try XCTUnwrap(bar.cells.firstIndex(where: \.isProcess))
        let divider = try XCTUnwrap(bar.displaySeparators.first)
        XCTAssertEqual(divider - 2 - bar.subviews[first - 1].frame.maxX, 9)
        XCTAssertEqual(bar.subviews[first].frame.minX - divider - 2, 9)
        bar.configure(try state(excludingPID: 1004), settings: settings, display: 2) { _ in nil }
        XCTAssertEqual(bar.cells.last?.group, "desktop")
        XCTAssertEqual(bar.displaySeparators.count, 1, "The empty Process state keeps its section boundary")
        settings.spaceScope = .hidden
        bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty)
        settings.spaceScope = .focusedDisplay; settings.windowScope = .hidden
        bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty)
        settings.windowScope = .all; settings.displaySeparatorStyle = .none
        bar.configure(snapshot, settings: settings, display: 2) { _ in nil }
        XCTAssertTrue(bar.displaySeparators.isEmpty)
    }

    func testDisplayDividerStylesPaintWithoutChangingTargetsOrReloadingIcons() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.spaceScope = .all; settings.windowScope = .hidden
        settings.density = .custom; settings.customWidth = 1000
        settings.showCreateSpace = false; settings.displayGap = 0
        settings.displaySeparatorThickness = 4; settings.displaySeparatorColor = "#FF0000"
        settings.backgroundOpacity = 0; settings.unfocusedBackgroundOpacity = 0
        settings.focusedSpaceNameColor = "#000000"; settings.visibleSpaceNameColor = "#000000"; settings.inactiveSpaceNameColor = "#000000"
        let bar = WidgetBarView(), snapshot = try state()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        var iconCalls = 0
        var targets: [BarTarget] = []
        for style in [AppSettings.DisplaySeparatorStyle.line, .none] {
            settings.displaySeparatorStyle = style
            bar.configure(snapshot, settings: settings) { _ in iconCalls += 1; return icon }
            if targets.isEmpty { targets = bar.cells.map(\.target) }
            XCTAssertEqual(bar.cells.map(\.target), targets)
            XCTAssertEqual(iconCalls, 2, "Changing a divider must reuse the existing icons")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(bar.bounds.width * 2), pixelsHigh: Int(bar.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = bar.bounds.size
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("divider-\(style.rawValue).png"))
            }
            var pixels: [(Int, Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.85 && color.greenComponent < 0.15 && color.blueComponent < 0.15 && color.alphaComponent > 0.15 {
                        pixels.append((x, y))
                    }
                }
            }
            if style == .none { XCTAssertTrue(pixels.isEmpty); XCTAssertTrue(bar.displaySeparators.isEmpty); continue }
            let marker = try XCTUnwrap(bar.displaySeparators.first)
            let edge = try XCTUnwrap(bar.cells.lastIndex { $0.display == 1 })
            XCTAssertGreaterThanOrEqual(marker - 2, bar.subviews[edge].frame.maxX)
            XCTAssertLessThanOrEqual(marker + 2, bar.subviews[edge + 1].frame.minX)
            let pixelWidth = try XCTUnwrap(pixels.map { $0.0 }.max()) - XCTUnwrap(pixels.map { $0.0 }.min()) + 1
            let pixelHeight = try XCTUnwrap(pixels.map { $0.1 }.max()) - XCTUnwrap(pixels.map { $0.1 }.min()) + 1
            XCTAssertLessThanOrEqual(abs(pixelWidth - 8), 1)
            XCTAssertGreaterThan(pixelHeight, pixelWidth * 2)
        }
    }

    func testNativeContentFrameUsesEachSlotsOwnInsets() throws {
        _ = NSApplication.shared
        for height in [CGFloat(24), 37] {
            let slot = FloatingBarPanel(contentRect: NSRect(x: 200, y: 400, width: 200, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            slot.isReleasedWhenClosed = false
            defer { slot.close() }
            XCTAssertEqual(MenuBarHosts.contentFrame(in: slot), slot.frame)
            let content = NSView(frame: NSRect(x: 1, y: 1, width: 198, height: height - 2))
            slot.contentView?.addSubview(content)
            XCTAssertEqual(MenuBarHosts.contentFrame(in: slot), slot.frame.insetBy(dx: 1, dy: 1))
            content.frame.origin.y = -1
            XCTAssertEqual(MenuBarHosts.contentFrame(in: slot), slot.frame, "Reject a transient content frame outside its native slot")
        }
    }

    func testNativeScopesKeepTheSameBackgroundVerticalInsets() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        func settle() {
            let deadline = Date(timeIntervalSinceNow: 0.15)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        var settings = AppSettings()
        settings.spaceScope = .all; settings.windowScope = .hidden
        settings.density = .custom; settings.customWidth = 1000
        settings.showSpaceIcons = false; settings.showCreateSpace = false
        settings.spaceName = .number; settings.focusStyle = .bold
        settings.focusedSpaceColor = "#FF0000"; settings.backgroundOpacity = 100
        settings.unfocusedBackgroundOpacity = 0; settings.showBorder = false
        let snapshot = try state(focused: 1)
        let controller = MenuBarController(settings: settings)
        controller.setupItem()
        let item = try XCTUnwrap(controller.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        controller.update(snapshot, status: ConnectionStatus(mode: .live))
        settle()
        controller.update(snapshot, status: ConnectionStatus(mode: .live), force: true)
        let button = try XCTUnwrap(item.button), slot = try XCTUnwrap(button.window)
        let screen = try XCTUnwrap(slot.screen)
        let allBar = try XCTUnwrap(controller.widgetBar)
        let allCell = try XCTUnwrap(allBar.subviews.first)
        let allRect = allBar.convert(allCell.frame.insetBy(dx: 0.5, dy: 0.5), to: nil)

        func paintedHeight(_ view: NSView, name: String) throws -> CGFloat {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("background-\(name).png"))
            }
            let rows = (0..<bitmap.pixelsHigh).filter { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.85 && color.greenComponent < 0.15 && color.blueComponent < 0.15 && color.alphaComponent > 0.5
                }
            }
            return CGFloat(try XCTUnwrap(rows.last) - XCTUnwrap(rows.first) + 1) * view.bounds.height / CGFloat(bitmap.pixelsHigh)
        }
        let allPaintedHeight = try paintedHeight(button, name: "all")
        allBar.removeFromSuperview()
        let hosts = MenuBarHosts(screens: { _ in [.init(id: 101, index: 1, frame: screen.frame)] })
        defer { hosts.close() }
        settings.spaceScope = .focusedDisplay
        for _ in 0..<2 {
            hosts.update(snapshot, settings: settings, status: ConnectionStatus(mode: .live),
                         reserveWidth: { if item.length != $0 { item.length = $0 } }, icon: { _ in nil }, menu: { _ in nil }, select: { _ in })
            settle()
        }
        let local = try XCTUnwrap(hosts.hosts[101])
        let onscreen = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int })
        let nativeSlots = NSApp.windows.filter { $0.level == .statusBar && MenuBarHosts.anchorFrame($0, screen: screen.frame, onscreen: onscreen) != nil }
        guard nativeSlots.count == 1 else { throw XCTSkip("Unhide the test status item before comparing native backgrounds") }
        XCTAssertTrue(local.panel.isVisible, "A valid native slot must produce a visible overlay")
        let localCell = try XCTUnwrap(local.bar.subviews.first)
        let localRect = local.panel.convertToScreen(local.bar.convert(localCell.frame.insetBy(dx: 0.5, dy: 0.5), to: nil))
            .offsetBy(dx: -slot.frame.minX, dy: -slot.frame.minY)
        let localPaintedHeight = try paintedHeight(try XCTUnwrap(local.panel.contentView), name: "local")
        XCTAssertEqual(localRect.minY, allRect.minY, accuracy: 0.5)
        XCTAssertEqual(localRect.height, allRect.height, accuracy: 0.5)
        XCTAssertEqual(localPaintedHeight, allPaintedHeight, accuracy: 0.5)
    }

    func testMenuBarAnchorRejectsHiddenOffscreenAndWrongSlots() {
        let screen = NSRect(x: -1440, y: -200, width: 1440, height: 900)
        let frame = NSRect(x: -300, y: 676, width: 150, height: 24)
        XCTAssertEqual(MenuBarHosts.anchorFrame(frame, screen: screen, width: 148, visible: true), frame)
        XCTAssertNil(MenuBarHosts.anchorFrame(frame, screen: screen, width: 148, visible: false))
        XCTAssertNil(MenuBarHosts.anchorFrame(frame.offsetBy(dx: -2000, dy: 0), screen: screen, width: 148, visible: true))
        XCTAssertNil(MenuBarHosts.anchorFrame(frame.offsetBy(dx: 0, dy: 10), screen: screen, width: 148, visible: true))
        XCTAssertNil(MenuBarHosts.anchorFrame(frame, screen: screen, width: 100, visible: true))
    }

    func testOnscreenNativeSlotSurvivesOcclusionWithoutKeepingHiddenSlots() throws {
        final class Slot: NSPanel {
            var shown = true
            override var isVisible: Bool { shown }
            override var occlusionState: NSWindow.OcclusionState { .init(rawValue: 8192) }
        }
        _ = NSApplication.shared
        let slot = Slot(contentRect: NSRect(x: 1802, y: 1272, width: 124, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        slot.isReleasedWhenClosed = false
        defer { slot.close() }
        let screen = NSRect(x: 0, y: 0, width: 2304, height: 1296), onscreen: Set<Int> = [slot.windowNumber]
        XCTAssertFalse(slot.occlusionState.contains(.visible))
        XCTAssertNotNil(MenuBarHosts.anchorFrame(slot, screen: screen, onscreen: onscreen), "Recorded native slot: ordered and on screen, but no occlusion-visible bit")
        XCTAssertNil(MenuBarHosts.anchorFrame(slot, screen: screen, onscreen: []), "A hidden native slot must still hide its overlay")
        slot.shown = false
        XCTAssertNil(MenuBarHosts.anchorFrame(slot, screen: screen, onscreen: onscreen))
    }

    func testMenuBarResizeKeepsOldContentInsideItsSlotUntilReady() throws {
        let oldSize = NSSize(width: 80, height: 24), nextSize = NSSize(width: 140, height: 24)
        let oldSlot = NSRect(x: 500, y: 700, width: 80, height: 24)
        let pending = try XCTUnwrap(MenuBarHosts.placement(in: oldSlot, requestedWidth: 140, nextSize: nextSize, previousSize: oldSize))
        XCTAssertFalse(pending.appliesLayout)
        XCTAssertEqual(pending.frame, oldSlot)
        XCTAssertEqual(pending.contentOrigin, .zero)
        XCTAssertNil(MenuBarHosts.placement(in: oldSlot, requestedWidth: 140, nextSize: nextSize, previousSize: nil), "An unrecognized slot must not receive stale content")
        let readySlot = NSRect(x: 440, y: 700, width: 140, height: 24)
        let ready = try XCTUnwrap(MenuBarHosts.placement(in: readySlot, requestedWidth: 140, nextSize: nextSize, previousSize: oldSize))
        XCTAssertTrue(ready.appliesLayout)
        XCTAssertEqual(ready.frame, readySlot)
        let shrinkingSlot = NSRect(x: 520, y: 700, width: 60, height: 24)
        let shrinking = try XCTUnwrap(MenuBarHosts.placement(in: shrinkingSlot, requestedWidth: 40, nextSize: NSSize(width: 40, height: 24), previousSize: oldSize))
        XCTAssertFalse(shrinking.appliesLayout)
        XCTAssertTrue(shrinkingSlot.contains(shrinking.frame))
        XCTAssertEqual(shrinking.contentOrigin.x, -20, "Clip old content at the slot boundary while keeping its right edge aligned")
    }

    func testMenuBarHostsFollowOwnedSlotsWithoutOcclusionFeedback() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        var screens = [MenuBarHosts.Screen(id: 101, index: 1, frame: NSRect(x: 100, y: 100, width: 1000, height: 700)),
                       MenuBarHosts.Screen(id: 202, index: 2, frame: NSRect(x: 1200, y: 100, width: 1000, height: 700))]
        let slots = screens.map { screen -> NSWindow in
            let height: CGFloat = screen.index == 1 ? 24 : 37
            let slot = FloatingBarPanel(contentRect: NSRect(x: screen.frame.midX - 150, y: screen.frame.maxY - height, width: 120, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            slot.isReleasedWhenClosed = false
            slot.level = .statusBar
            slot.hasShadow = false
            slot.backgroundColor = .white
            return slot
        }
        var anchors = slots
        let hosts = MenuBarHosts(screens: { _ in screens }, anchors: { anchors })
        defer { hosts.close(); slots.forEach { $0.close() } }
        var settings = AppSettings()
        settings.placement = .menuBar; settings.spaceScope = .focusedDisplay
        settings.showSpaceIcons = false; settings.showCreateSpace = false
        let snapshot = try state()
        func update(command: Bool = false) -> CGFloat {
            hosts.update(snapshot, settings: settings, status: ConnectionStatus(mode: .live), commandDown: command, icon: { _ in nil }, menu: { _ in nil }, select: { _ in })
        }
        let width = update()
        for slot in slots {
            slot.setContentSize(NSSize(width: width + 2, height: slot.frame.height))
            slot.orderFrontRegardless()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        _ = update()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        let left = try XCTUnwrap(hosts.hosts[101]), right = try XCTUnwrap(hosts.hosts[202])
        XCTAssertTrue(left.panel.isVisible && right.panel.isVisible)
        XCTAssertTrue(slots.allSatisfy { $0.occlusionState.contains(.visible) }, "Transparent overlays must not hide their own native anchors")
        XCTAssertFalse(left.panel.hasShadow || left.panel.canBecomeKey)
        XCTAssertEqual(left.bar.frame.height, 24)
        XCTAssertEqual(right.bar.frame.height, 37)
        anchors.reverse(); _ = update()
        XCTAssertEqual(left.bar.frame.height, 24)
        XCTAssertEqual(right.bar.frame.height, 37)
        XCTAssertEqual(left.bar.cells.map(\.display), [1, 1, 1])
        XCTAssertEqual(right.bar.cells.map(\.display), [2, 2, 2])
        XCTAssertEqual(left.bar.cells.filter(\.currentSpace).map(\.text), ["[1]"])
        XCTAssertEqual(right.bar.cells.filter(\.currentSpace).map(\.text), ["[4]"])
        XCTAssertTrue(slots[0].frame.contains(left.panel.frame))
        let old = left.panel.frame
        slots[0].setFrameOrigin(NSPoint(x: slots[0].frame.minX + 25, y: slots[0].frame.minY))
        _ = update()
        XCTAssertEqual(left.panel.frame.minX, old.minX + 25)
        _ = update(command: true)
        XCTAssertTrue(left.panel.isVisible && right.panel.isVisible, "Command must keep the bar visible")
        XCTAssertTrue(left.panel.ignoresMouseEvents && right.panel.ignoresMouseEvents)
        _ = update()
        XCTAssertTrue(left.panel.isVisible && right.panel.isVisible)
        XCTAssertFalse(left.panel.ignoresMouseEvents || right.panel.ignoresMouseEvents)
        slots[0].orderOut(nil); _ = update()
        XCTAssertFalse(left.panel.isVisible)
        XCTAssertTrue(right.panel.isVisible)
        slots[0].orderFrontRegardless()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        anchors = [slots[0], slots[0], slots[1]]; _ = update()
        XCTAssertFalse(left.panel.isVisible, "Ambiguous slot matches must fail closed")
        anchors = slots
        settings.fontSize = 20
        let wider = update()
        XCTAssertTrue(left.panel.isVisible && right.panel.isVisible, "Keep the old content while the native slot acquires the new width")
        XCTAssertTrue(slots[0].frame.contains(left.panel.frame) && slots[1].frame.contains(right.panel.frame))
        for slot in slots { slot.setContentSize(NSSize(width: wider + 2, height: slot.frame.height)) }
        _ = update()
        XCTAssertTrue(hosts.hosts[101] === left)
        XCTAssertTrue(slots[0].frame.contains(left.panel.frame))
        screens.removeLast(); _ = update()
        XCTAssertNil(hosts.hosts[202]); XCTAssertFalse(right.panel.isVisible)
    }

    func testLocalMenuClicksThroughNativeSlotAndOnInactivePanel() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let screens = [MenuBarHosts.Screen(id: 101, index: 1, frame: NSRect(x: 100, y: 100, width: 1000, height: 700)),
                       MenuBarHosts.Screen(id: 202, index: 2, frame: NSRect(x: 1200, y: 100, width: 1000, height: 700))]
        let slots = screens.map { screen -> NSWindow in
            let slot = FloatingBarPanel(contentRect: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 24, width: 100, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            slot.isReleasedWhenClosed = false; slot.level = .statusBar
            return slot
        }
        let hosts = MenuBarHosts(screens: { _ in screens }, anchors: { slots })
        var settings = AppSettings()
        settings.placement = .menuBar; settings.spaceScope = .focusedDisplay; settings.density = .custom; settings.customWidth = 1000
        let controller = MenuBarController(settings: settings, menuBarHosts: hosts)
        controller.setupItem()
        defer { hosts.close(); slots.forEach { $0.close() }; if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) } }
        let snapshot = try state()
        controller.update(snapshot, status: ConnectionStatus(mode: .live))
        let width = try XCTUnwrap(controller.statusItem?.length)
        for slot in slots { slot.setContentSize(NSSize(width: width + 2, height: 24)); slot.orderFrontRegardless() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        controller.update(snapshot, status: ConnectionStatus(mode: .live), force: true)
        XCTAssertEqual(width, hosts.hosts.values.map { $0.bar.frame.width }.max(), "A ready slot must not reserve an extra ellipsis")
        var choices: [(Int?, Int?)] = []
        controller.focusAction = { choices.append(($0, $1)) }
        for (index, screen) in screens.enumerated() {
            let host = try XCTUnwrap(hosts.hosts[screen.id])
            XCTAssertTrue(host.panel.isVisible)
            XCTAssertNotNil(host.bar.menu?.items.first { $0.title == "Settings…" })
            XCTAssertNotNil(host.panel.contentView?.menu)
            let inactive = screen.index == 1 ? 12 : 15
            let window = screen.index == 1 ? 101 : 104
            for target in [BarTarget.space(inactive), .window(window, screen.index == 1 ? 11 : 14)] {
                let cell = try XCTUnwrap(host.bar.cells.firstIndex { $0.target == target })
                let view = host.bar.subviews[cell]
                let onPanel = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let global = host.panel.convertPoint(toScreen: onPanel)
                let onSlot = slots[index].convertPoint(fromScreen: global)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: onSlot, modifierFlags: [], timestamp: 0, windowNumber: slots[index].windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: onSlot, modifierFlags: [], timestamp: 0.01, windowNumber: slots[index].windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                NSApp.sendEvent(down); NSApp.sendEvent(up)
            }
            let cell = try XCTUnwrap(host.bar.cells.firstIndex { $0.target == .space(inactive) })
            let view = host.bar.subviews[cell]
            XCTAssertTrue(view.acceptsFirstMouse(for: nil))
            XCTAssertFalse(view.needsPanelToBecomeKey || view.mouseDownCanMoveWindow)
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.panel.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: host.panel.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: false)
            host.panel.sendEvent(down)
        }
        XCTAssertEqual(choices.count, 6)
        if choices.count == 6 {
            XCTAssertEqual(choices[0].0, 2); XCTAssertEqual(choices[1].1, 101); XCTAssertEqual(choices[2].0, 2)
            XCTAssertEqual(choices[3].0, 5); XCTAssertEqual(choices[4].1, 104); XCTAssertEqual(choices[5].0, 5)
        }
        XCTAssertNil(controller.statusItem?.menu)
    }

    func testFrameProjectionWithNegativeCoordinatesAndInvalidSavedValues() {
        let screen = BarScreen(id: 101, index: 1, key: "left", visibleFrame: NSRect(x: -1440, y: -200, width: 1440, height: 900), screenFrame: NSRect(x: -1440, y: -200, width: 1440, height: 924))
        let size = NSSize(width: 280, height: 32)
        for position in [NSPoint(x: 0, y: 0), NSPoint(x: 0.5, y: 0.25), NSPoint(x: 1, y: 1)] {
            let frame = screen.frame(size: size, position: position)
            XCTAssertTrue(screen.visibleFrame.contains(frame))
            XCTAssertEqual(screen.position(for: frame).x, position.x, accuracy: 0.0001)
            XCTAssertEqual(screen.position(for: frame).y, position.y, accuracy: 0.0001)
        }
        let repaired = screen.frame(size: NSSize(width: 9000, height: 9000), position: NSPoint(x: CGFloat.nan, y: CGFloat.infinity))
        XCTAssertTrue(screen.visibleFrame.contains(repaired))
        XCTAssertTrue(repaired.origin.x.isFinite && repaired.origin.y.isFinite)
    }

    func testFloatingBarCanStayInMenuBarAfterReleaseAndRefresh() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = BarScreen(id: 101, index: 1, key: "left", visibleFrame: NSRect(x: 100, y: 100, width: 1000, height: 700), screenFrame: NSRect(x: 100, y: 100, width: 1000, height: 724))
        defaults.set(["left": ["x": 0.4, "y": 0.7]], forKey: "floatingPositions")
        let bars = FloatingBars(defaults: defaults, screens: { _ in [screen] })
        defer { bars.close() }
        var settings = AppSettings(); settings.placement = .floating
        let snapshot = try state()
        func update() { bars.update(snapshot, settings: settings, status: ConnectionStatus(mode: .live), icon: { _ in nil }, menu: { _ in NSMenu() }, select: { _ in }) }
        update()
        let host = try XCTUnwrap(bars.hosts[101])
        let legacy = screen.frame(size: host.panel.frame.size, position: NSPoint(x: 0.4, y: 0.7))
        XCTAssertEqual(host.panel.frame.minX, legacy.minX, accuracy: 0.5, "Allow AppKit pixel alignment, not a change of position bounds")
        XCTAssertEqual(host.panel.frame.minY, legacy.minY, accuracy: 0.5)
        let oldTop = host.panel.frame.maxY
        host.handle.beginDrag(at: .zero)
        host.handle.drag(to: NSPoint(x: 0, y: 824 - oldTop))
        host.handle.endDrag()
        XCTAssertEqual(host.panel.frame.maxY, 824, "Release must not pull the bar back below the menu strip")
        update()
        XCTAssertEqual(host.panel.frame.maxY, 824)
        XCTAssertEqual(host.panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        let restored = FloatingBars(defaults: defaults, screens: { _ in [screen] })
        defer { restored.close() }
        restored.update(snapshot, settings: settings, status: ConnectionStatus(mode: .live), icon: { _ in nil }, menu: { _ in NSMenu() }, select: { _ in })
        XCTAssertEqual(restored.hosts[101]?.panel.frame.maxY, 824, "New positions must survive a restart")
        XCTAssertNotNil(host.panel.contentView?.menu)
        XCTAssertNotNil(host.bar.menu)
        host.handle.beginDrag(at: .zero)
        host.handle.drag(to: NSPoint(x: 0, y: -100))
        XCTAssertEqual(host.panel.level, .floating)
        host.handle.endDrag()
        settings.placement = .docked; update()
        XCTAssertEqual(host.panel.frame.maxY, screen.visibleFrame.maxY - 8)
        XCTAssertEqual(host.panel.level, .floating)
    }

    func testFloatingBarReachesActualScreenMenuStrip() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let physical = try XCTUnwrap(NSScreen.main)
        let screen = BarScreen(id: 101, index: 1, key: "physical", visibleFrame: physical.visibleFrame, screenFrame: physical.frame)
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bars = FloatingBars(defaults: defaults, screens: { _ in [screen] })
        defer { bars.close() }
        var settings = AppSettings(); settings.placement = .floating; settings.showSpaceIcons = false
        bars.update(try state(), settings: settings, status: ConnectionStatus(mode: .live), icon: { _ in nil }, menu: { _ in NSMenu() }, select: { _ in })
        let host = try XCTUnwrap(bars.hosts[101])
        host.handle.beginDrag(at: .zero)
        host.handle.drag(to: NSPoint(x: 0, y: physical.frame.maxY - host.panel.frame.maxY))
        host.handle.endDrag()
        XCTAssertEqual(host.panel.frame.maxY, physical.frame.maxY)
        XCTAssertEqual(host.panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
    }

    func testFloatingHostsDragPersistenceHotplugAndSuspension() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var screens = [BarScreen(id: 101, index: 1, key: "left", visibleFrame: NSRect(x: 100, y: 100, width: 1000, height: 700), screenFrame: NSRect(x: 100, y: 100, width: 1000, height: 724)),
                       BarScreen(id: 202, index: 2, key: "right", visibleFrame: NSRect(x: 1200, y: 100, width: 1000, height: 700), screenFrame: NSRect(x: 1200, y: 100, width: 1000, height: 724))]
        let bars = FloatingBars(defaults: defaults, screens: { _ in screens })
        defer { bars.close() }
        var settings = AppSettings()
        settings.placement = .floating; settings.spaceScope = .focusedDisplay
        settings.floatingOpacity = 80; settings.floatingAboveFullscreen = true
        let snapshot = try state()
        var selected: BarTarget?
        func update(_ mode: ConnectionStatus.Mode = .live) {
            bars.update(snapshot, settings: settings, status: ConnectionStatus(mode: mode), icon: { _ in nil }, menu: { _ in NSMenu() }, select: { selected = $0 })
        }
        update()
        XCTAssertEqual(bars.hosts.count, 2)
        let left = try XCTUnwrap(bars.hosts[101]), right = try XCTUnwrap(bars.hosts[202])
        XCTAssertFalse(left.panel.canBecomeKey || left.panel.canBecomeMain)
        XCTAssertEqual(left.panel.alphaValue, 0.8)
        XCTAssertTrue(left.panel.hasShadow)
        XCTAssertFalse(left.backdrop.isHidden)
        XCTAssertNil(left.backdrop.hitTest(NSPoint(x: 20, y: 10)))
        XCTAssertEqual(left.panel.frame.height, CGFloat(settings.floatingHeight + settings.barVerticalPadding * 2))
        XCTAssertEqual(left.bar.frame.minX, CGFloat(settings.barHorizontalPadding + 18))
        left.backdrop.layoutSubtreeIfNeeded()
        XCTAssertNotNil(left.backdrop.material.maskImage)
        XCTAssertTrue(left.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(left.bar.cells.filter { if case .space = $0.target { return true }; return false }.map(\.display), [1, 1, 1])
        let index = try XCTUnwrap(right.bar.cells.firstIndex { $0.target == .window(104, 14) })
        (right.bar.subviews[index] as? NSButton)?.performClick(nil)
        XCTAssertEqual(selected, .window(104, 14))
        let beforeClick = left.panel.frame
        bars.onDragFinished = { update() }
        left.handle.beginDrag(at: NSPoint(x: 200, y: 200))
        settings.floatingHeight = 34
        update()
        XCTAssertEqual(left.panel.frame, beforeClick)
        left.handle.endDrag()
        XCTAssertEqual(left.panel.frame.height, 40, "Mouse-up must apply a skipped update even without movement")
        XCTAssertNil(defaults.dictionary(forKey: "floatingPositions"), "A click refreshes without saving a new position")
        bars.onDragFinished = nil
        let original = left.panel.frame
        left.handle.beginDrag(at: NSPoint(x: 200, y: 200))
        XCTAssertTrue(left.handle.isDragging)
        settings.floatingHeight = 40
        update()
        XCTAssertEqual(left.panel.frame, original, "A refresh between mouse-down and the first drag must not change the anchor")
        left.handle.drag(to: NSPoint(x: 300, y: 100))
        let dragged = left.panel.frame
        XCTAssertEqual(dragged.origin, NSPoint(x: original.minX + 100, y: original.minY - 100))
        update()
        XCTAssertEqual(left.panel.frame, dragged, "Data refresh must not snap a bar back during drag")
        var finishes = 0
        bars.onDragFinished = { finishes += 1 }
        left.handle.endDrag()
        XCTAssertEqual(finishes, 1)
        settings.barBackdrop = .solid; settings.barShadow = false; update()
        XCTAssertTrue(bars.hosts[101] === left)
        XCTAssertTrue(left.backdrop.material.isHidden)
        XCTAssertFalse(left.panel.hasShadow)
        settings.barBackdrop = .none; settings.barShadow = true; update()
        XCTAssertTrue(left.backdrop.isHidden)
        XCTAssertFalse(left.panel.hasShadow)
        settings.barBackdrop = .glass; update()
        XCTAssertTrue(left.panel.hasShadow)
        XCTAssertNotNil(defaults.dictionary(forKey: "floatingPositions")?["left"])
        let saved = left.panel.frame
        update()
        XCTAssertTrue(bars.hosts[101] === left)
        XCTAssertEqual(left.panel.frame, saved)
        settings.floatingLocked = true; update()
        left.handle.beginDrag(at: .zero); left.handle.drag(to: NSPoint(x: 50, y: 50)); left.handle.endDrag()
        XCTAssertEqual(left.panel.frame, saved)
        XCTAssertEqual(finishes, 1)
        screens.removeLast(); update()
        XCTAssertNil(bars.hosts[202]); XCTAssertFalse(right.panel.isVisible)
        screens[0] = BarScreen(id: 101, index: 1, key: "left", visibleFrame: NSRect(x: -800, y: 20, width: 800, height: 600), screenFrame: NSRect(x: -800, y: 20, width: 800, height: 624))
        update()
        XCTAssertTrue(screens[0].visibleFrame.contains(left.panel.frame))
        update(.suspended); XCTAssertFalse(left.panel.isVisible)
        update(); XCTAssertTrue(left.panel.isVisible)
        settings.placement = .menuBar; settings.spaceScope = .all; update()
        XCTAssertTrue(bars.hosts.isEmpty)
    }

    func testGeometryRefreshPerformanceDoesNotLoadIconsOrRebuildButtons() throws {
        _ = NSApplication.shared
        let bar = WidgetBarView()
        var settings = AppSettings(); settings.spaceScope = .focusedDisplay
        var requests = 0
        bar.configure(try state(), settings: settings, display: 1) { _ in requests += 1; return nil }
        let original = bar.subviews.map(ObjectIdentifier.init), count = requests
        let states = try (0..<200).map { try state(x: Double($0)) }
        let start = ProcessInfo.processInfo.systemUptime
        for snapshot in states { bar.configure(snapshot, settings: settings, display: 1) { _ in requests += 1; return nil } }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), original)
        XCTAssertEqual(requests, count)
        print("GEOMETRY_BENCH updates=200 rebuilds=0 icon_loads=0 elapsed_ms=\(elapsed * 1000)")
    }

    func testHandleUsesQueuedEventCoordinatesAndFinalMouseUpPosition() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let panel = FloatingBarPanel(contentRect: NSRect(x: 200, y: 200, width: 160, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let handle = BarDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 40))
        panel.contentView?.addSubview(handle)
        var saves = 0
        handle.didDrag = { saves += 1 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = NSPoint(x: 208, y: 220)
        handle.mouseDown(with: try event(.leftMouseDown, down))
        // The physical pointer stays still; delivery must use each event's recorded position.
        handle.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 248, y: 232)))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 240, y: 212))
        handle.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 258, y: 238)))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 250, y: 218))
        XCTAssertEqual(saves, 1)
        handle.mouseDown(with: try event(.leftMouseDown, down))
        handle.mouseUp(with: try event(.leftMouseUp, down))
        XCTAssertEqual(saves, 1, "A click alone does not persist a new position")
        handle.locked = true
        handle.mouseDown(with: try event(.leftMouseDown, down))
        handle.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 300, y: 300)))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 250, y: 218))
        XCTAssertEqual(saves, 1)
    }

    func testBackdropMaskReuseAndPaletteAppearance() {
        _ = NSApplication.shared
        let backdrop = BarBackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 38))
        var settings = AppSettings()
        for preset in [ColorPreset.catppuccinLatte, .catppuccinMocha, .system] {
            settings.colorPreset = preset
            backdrop.configure(settings)
            backdrop.layoutSubtreeIfNeeded()
            XCTAssertEqual(backdrop.appearance?.name, preset.appearance?.name)
            let mask = backdrop.material.maskImage
            backdrop.configure(settings)
            backdrop.layoutSubtreeIfNeeded()
            XCTAssertTrue(backdrop.material.maskImage === mask)
        }
        settings.barCornerRadius = 0
        backdrop.configure(settings)
        backdrop.layoutSubtreeIfNeeded()
        XCTAssertNil(backdrop.material.maskImage)
    }

    func testGlassCompositionOverControlledBackgrounds() throws {
        guard #unavailable(macOS 15) else { throw XCTSkip("Owned-window composition capture uses the macOS 14 test host") }
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1",
              let output = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] else { throw XCTSkip("Optional owned-window visual capture") }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let rectangle = NSRect(x: screen.visibleFrame.midX - 280, y: screen.visibleFrame.midY - 70, width: 560, height: 140)
        let background = FloatingBarPanel(contentRect: rectangle, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.level = .floating
        background.hasShadow = false
        let canvas = NSImageView(frame: NSRect(origin: .zero, size: rectangle.size))
        background.contentView = canvas
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let bars = FloatingBars(defaults: defaults, screens: { _ in [BarScreen(id: 101, index: 1, key: "preview", visibleFrame: rectangle, screenFrame: rectangle)] })
        defer { bars.close(); background.close(); defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings(defaults: defaults)
        settings.placement = .floating
        settings.focusStyle = .underline
        settings.fontSize = 12
        settings.backgroundOpacity = 100
        settings.unfocusedBackgroundOpacity = 0
        settings.showSpaceIcons = false
        settings.density = .custom; settings.customWidth = 460
        let snapshot = try state()
        for (kind, colors) in [("black", [NSColor.black]), ("white", [NSColor.white]), ("busy", [.systemRed, .systemBlue, .systemYellow, .systemGreen])] {
            canvas.image = NSImage(size: rectangle.size, flipped: false) { bounds in
                for x in stride(from: 0, to: Int(bounds.width), by: 14) {
                    colors[(x / 14) % colors.count].setFill()
                    NSBezierPath(rect: NSRect(x: x, y: 0, width: 14, height: Int(bounds.height))).fill()
                }
                return true
            }
            background.orderFrontRegardless()
            for preset in [ColorPreset.catppuccinLatte, .catppuccinMocha, .system] {
                settings.colorPreset = preset
                bars.update(snapshot, settings: settings, status: ConnectionStatus(mode: .live), icon: { _ in nil }, menu: { _ in nil }, select: { _ in })
                let host = try XCTUnwrap(bars.hosts[101])
                host.panel.setFrameOrigin(NSPoint(x: rectangle.midX - host.panel.frame.width / 2, y: rectangle.midY - host.panel.frame.height / 2))
                host.panel.order(.above, relativeTo: background.windowNumber)
                host.panel.contentView?.layoutSubtreeIfNeeded()
                host.panel.displayIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
                // Only our two synthetic windows are included; no desktop or user-window capture.
                // CGWindow expects raw window IDs, not boxed CFNumber values.
                let ids = try XCTUnwrap(CFArrayCreateMutable(nil, 2, nil))
                CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: host.panel.windowNumber))
                CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: background.windowNumber))
                let cg = try XCTUnwrap(CGImage(windowListFromArrayScreenBounds: .null, windowArray: ids, imageOption: [.bestResolution]))
                let bitmap = NSBitmapImageRep(cgImage: cg)
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("glass-\(preset.rawValue)-\(kind).png"))
            }
        }
    }
}
