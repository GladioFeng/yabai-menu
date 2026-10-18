// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
import ServiceManagement
@testable import YabaiMenuKit

final class SettingsTests: XCTestCase {
    @MainActor
    func testPreviewHeightFitsActualBarInsteadOfReservingMaximum() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        let access = LoginItemAccess(status: { .notRegistered }, setEnabled: { _ in }, openSettings: {})
        for (height, padding) in [(32, 3), (64, 12)] {
            var settings = AppSettings()
            settings.placement = .floating; settings.floatingHeight = height; settings.barVerticalPadding = padding
            let controller = SettingsWindowController(settings: settings, loginAccess: access)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.previewContainer.frame.height, CGFloat(height + padding * 2))
            controller.placement.selectItem(at: 0)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.placement.action), to: controller.placement.target, from: controller.placement))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.previewContainer.frame.height, 24)
            controller.close()
        }
    }

    @MainActor
    func testFloatingContextMenuOffersPositionLock() throws {
        _ = NSApplication.shared
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings(); settings.placement = .floating
        let controller = MenuBarController(settings: settings, defaults: defaults)
        for target in [BarTarget.menu, .space(1), .window(1, 1)] {
            XCTAssertNotNil(controller.barContextMenu(target).items.first { $0.title == "Lock Floating Bar Position" })
        }
        let lock = try XCTUnwrap(controller.barContextMenu(.menu).items.first { $0.title == "Lock Floating Bar Position" })
        XCTAssertEqual(lock.state, .off)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(lock.action), to: lock.target, from: lock))
        XCTAssertTrue(AppSettings(defaults: defaults).floatingLocked)
        let unlock = try XCTUnwrap(controller.barContextMenu(.menu).items.first { $0.title == "Lock Floating Bar Position" })
        XCTAssertEqual(unlock.state, .on)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(unlock.action), to: unlock.target, from: unlock))
        XCTAssertFalse(AppSettings(defaults: defaults).floatingLocked)
        settings.placement = .menuBar
        XCTAssertNil(MenuBarController(settings: settings, defaults: defaults).barContextMenu(.menu).items.first { $0.title == "Lock Floating Bar Position" })
    }

    @MainActor
    func testContextLockSynchronizesSettingsWithoutFeedback() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else { throw XCTSkip("AppKit session required") }
        _ = NSApplication.shared
        var settings = AppSettings(); settings.placement = .floating; settings.colorPreset = .catppuccinLatte
        let controller = SettingsWindowController(settings: settings, loginAccess: LoginItemAccess(status: { .notRegistered }, setEnabled: { _ in }, openSettings: {}))
        defer { controller.close() }
        var changes = 0
        controller.onChange = { _ in changes += 1 }
        controller.syncFloatingLocked(true)
        XCTAssertTrue(controller.value.floatingLocked)
        XCTAssertEqual(controller.value.colorPreset, .catppuccinLatte)
        XCTAssertEqual(changes, 0)
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Keep the floating bar in place" { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        let panel = try XCTUnwrap(controller.tabs.tabViewItems.first { $0.label == "Floating" }?.view)
        let checkbox = try XCTUnwrap(find(panel))
        XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil)
        XCTAssertFalse(controller.value.floatingLocked)
        XCTAssertEqual(changes, 1)
    }

    func testPreferencesRoundTripAndPathValidation() throws {
        let name = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.density, .standard)
        XCTAssertTrue(settings.showLayout)
        XCTAssertEqual(settings.windowScope, .hidden)
        defaults.set("relaxed", forKey: "itemSpacing")
        XCTAssertEqual(AppSettings(defaults: defaults).groupSpacing, 8)
        defaults.set("currentSpace", forKey: "windowScope")
        XCTAssertEqual(AppSettings(defaults: defaults).windowScope, .currentSpace)
        settings.density = .compact
        settings.spaceScope = .focusedDisplay
        settings.showLayout = false
        settings.spaceName = .numberAndLabel
        settings.focusStyle = .underline
        settings.windowScope = .focused
        settings.iconSize = 18
        settings.groupSpacing = 24
        settings.spaceIconGap = 16
        settings.layoutIconSize = 32
        settings.unfocusedBrightness = 20
        settings.spaceWindowLayout = .text
        settings.focusedSpaceColor = "#FF0000"
        settings.visibleSpaceColor = "#00FF00"
        settings.inactiveSpaceColor = "#0000FF"
        settings.customWidth = 420
        settings.presentation = .compact
        settings.showSpaceIcons = false
        settings.hideEmptySpaces = true
        settings.hideDuplicateApps = false
        settings.separateSticky = false
        settings.showCreateSpace = false
        settings.exclusions = "Finder, Work"
        settings.titleExclusions = "^tmp"
        settings.exclusionsAsRegex = true
        settings.showWindowTitle = false
        settings.processOnlyIcon = true
        settings.layoutStyle = .icon
        settings.spaceLayout = .off
        settings.monochrome = true
        settings.fontName = "Menlo"
        settings.fontSize = 14
        settings.backgroundOpacity = 65
        settings.cornerRadius = 7
        settings.showBorder = true
        settings.yabaiPath = "/bin/echo"
        settings.placement = .floating
        settings.floatingHeight = 48
        settings.floatingOpacity = 75
        settings.floatingLocked = true
        settings.floatingAboveFullscreen = true
        settings.barBackdrop = .solid
        settings.barBackgroundOpacity = 70
        settings.barCornerRadius = 16
        settings.barHorizontalPadding = 12
        settings.barVerticalPadding = 8
        settings.barBorder = false
        settings.barShadow = false
        settings.displayGap = 37
        settings.showDisplaySeparators = false
        settings.unfocusedBackgroundOpacity = 0
        settings.colorPreset = .tokyoNight
        settings.focusedSpaceNameColor = "#336699"
        XCTAssertEqual(settings.spaceColor(focused: true, visible: true), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(settings.spaceColor(focused: false, visible: true), NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        XCTAssertEqual(settings.spaceColor(focused: false, visible: false), NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(AppSettings.checkedColor("bad color"), "")
        settings.save(to: defaults)
        XCTAssertEqual(AppSettings(defaults: defaults), settings)
        XCTAssertEqual(AppSettings(defaults: defaults).groupSpacing, 24, "New spacing overrides the legacy key")
        defaults.set(999, forKey: "iconSize")
        defaults.set(-1, forKey: "customWidth")
        defaults.set("unsupported", forKey: "spaceName")
        defaults.set("unsupported", forKey: "barBackdrop")
        defaults.set(999, forKey: "barCornerRadius")
        defaults.set(-1, forKey: "barHorizontalPadding")
        defaults.set(999, forKey: "barVerticalPadding")
        defaults.set(999, forKey: "barBackgroundOpacity")
        let repaired = AppSettings(defaults: defaults)
        XCTAssertEqual(repaired.iconSize, 32)
        XCTAssertEqual(repaired.customWidth, 120)
        XCTAssertEqual(repaired.spaceName, .number)
        XCTAssertEqual(repaired.barBackdrop, .glass)
        XCTAssertEqual(repaired.barCornerRadius, 24)
        XCTAssertEqual(repaired.barHorizontalPadding, 0)
        XCTAssertEqual(repaired.barVerticalPadding, 12)
        XCTAssertEqual(repaired.barBackgroundOpacity, 100)
        XCTAssertEqual(try AppSettings.checkedPath("   "), "")
        XCTAssertEqual(try AppSettings.checkedPath("/bin/echo"), "/bin/echo")
        XCTAssertThrowsError(try AppSettings.checkedPath("echo"))
        XCTAssertThrowsError(try AppSettings.checkedPath("/tmp"))
        XCTAssertThrowsError(try AppSettings.checkedPath("/not/a/real/yabai"))
    }

    func testIndependentNameColorsAndLegacyMigration() throws {
        let suite = "test.yabai-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("#112233", forKey: "focusedSpaceColor")
        defaults.set(70, forKey: "backgroundOpacity")
        var settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.focusedSpaceNameColor, "#112233")
        XCTAssertEqual(settings.unfocusedBackgroundOpacity, 70)
        settings.focusedSpaceNameColor = ""; settings.colorPreset = .catppuccinMocha
        settings.unfocusedBackgroundOpacity = 0
        settings.save(to: defaults)
        settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.focusedSpaceNameColor, "")
        XCTAssertEqual(settings.focusedSpaceColor, "#112233")
        XCTAssertNotEqual(settings.spaceNameColor(focused: true, visible: true), settings.spaceColor(focused: true, visible: true))
        XCTAssertEqual(settings.backgroundAlpha(focused: false, visible: false), 0)
        XCTAssertEqual(settings.backgroundAlpha(focused: false, visible: true), 0)
        XCTAssertGreaterThan(settings.backgroundAlpha(focused: true, visible: true), 0)
        for preset in ColorPreset.allCases where preset != .system {
            XCTAssertEqual(preset.colors.count, 7)
            XCTAssertTrue(preset.colors.allSatisfy { AppSettings.checkedColor($0) == $0 })
        }
    }

    @MainActor
    func testControlsAndLoginItemStateWithoutRegisteringRealService() throws {
        guard ProcessInfo.processInfo.environment["YABAI_MENU_UI_TESTS"] == "1" else {
            throw XCTSkip("Set YABAI_MENU_UI_TESTS=1 in an interactive macOS session")
        }
        _ = NSApplication.shared
        var serviceStatus = SMAppService.Status.notRegistered
        var operations: [Bool] = []
        var failLogin = false
        let access = LoginItemAccess(status: { serviceStatus }, setEnabled: { enabled in
            operations.append(enabled)
            if failLogin { throw MenuError.message("login denied") }
            serviceStatus = enabled ? .requiresApproval : .notRegistered
        }, openSettings: {})
        let controller = SettingsWindowController(settings: AppSettings(), loginAccess: access)
        defer { controller.close() }
        XCTAssertTrue(operations.isEmpty, "Opening settings must never change login startup")
        var accessRequests = 0
        controller.onEnableWindowObservation = { accessRequests += 1 }
        XCTAssertEqual(accessRequests, 0)
        controller.accessibility.performClick(nil)
        XCTAssertEqual(accessRequests, 1, "Only the explicit button invokes the system permission path")
        var changed: AppSettings?
        controller.onChange = { changed = $0 }
        controller.density.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.density.action), to: controller.density.target, from: controller.density))
        XCTAssertEqual(changed?.density, .compact)
        controller.scope.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.scope.action), to: controller.scope.target, from: controller.scope))
        XCTAssertEqual(changed?.spaceScope, .focusedDisplay)
        XCTAssertEqual(changed?.placement, .menuBar)
        XCTAssertEqual(controller.value.effectivePlacement, .menuBar)
        controller.placement.selectItem(at: 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.placement.action), to: controller.placement.target, from: controller.placement))
        controller.barBackdrop.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.barBackdrop.action), to: controller.barBackdrop.target, from: controller.barBackdrop))
        XCTAssertEqual(changed?.barBackdrop, .solid)
        XCTAssertFalse(controller.previewBackdrop.isHidden)
        XCTAssertTrue(controller.previewBackdrop.material.isHidden)
        controller.barBackdrop.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.barBackdrop.action), to: controller.barBackdrop.target, from: controller.barBackdrop))
        controller.density.selectItem(at: 2)
        controller.width.doubleValue = 420
        controller.spaceName.selectItem(at: 2)
        controller.focusStyle.selectItem(at: 2)
        controller.windowScope.selectItem(at: 1)
        controller.iconSize.selectItem(withTag: 18)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.density.action), to: controller.density.target, from: controller.density))
        XCTAssertEqual(changed?.width, 420)
        XCTAssertEqual(changed?.spaceName, .numberAndLabel)
        XCTAssertEqual(changed?.focusStyle, .underline)
        XCTAssertEqual(changed?.windowScope, .focused)
        XCTAssertEqual(changed?.iconSize, 18)
        XCTAssertTrue(controller.width.isEnabled)
        XCTAssertTrue(controller.richPreview.cells.contains { $0.tooltip.contains("Work") })
        let well = try XCTUnwrap(controller.colors[\.focusedSpaceColor])
        well.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(well.action), to: well.target, from: well))
        XCTAssertEqual(changed?.focusedSpaceColor, "#336699")
        controller.colorPreset.selectItem(at: ColorPreset.allCases.firstIndex(of: .catppuccinMocha)!)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.colorPreset.action), to: controller.colorPreset.target, from: controller.colorPreset))
        XCTAssertEqual(changed?.colorPreset, .catppuccinMocha)
        for (key, _) in AppSettings.colors { XCTAssertEqual(controller.value[keyPath: key], "") }
        XCTAssertEqual(well.color, controller.value.spaceColor(focused: true, visible: true))
        controller.placement.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.placement.action), to: controller.placement.target, from: controller.placement))
        XCTAssertEqual(changed?.spaceScope, .focusedDisplay)
        XCTAssertEqual(changed?.placement, .menuBar)
        XCTAssertTrue(operations.isEmpty, "Appearance changes must not alter login registration")
        controller.windowScope.selectItem(at: 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.windowScope.action), to: controller.windowScope.target, from: controller.windowScope))
        XCTAssertTrue(controller.iconSize.isEnabled, "Space icons still use the icon-size setting")
        controller.windowScope.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.windowScope.action), to: controller.windowScope.target, from: controller.windowScope))
        controller.path.stringValue = "/invalid/yabai"
        controller.commitPath()
        XCTAssertEqual(changed?.yabaiPath, "")
        controller.updateStatus(ConnectionStatus(mode: .live, lastUpdated: Date()), path: "/opt/homebrew/bin/yabai")
        XCTAssertTrue(controller.statusLabel.stringValue.contains("full path"), "Background connection updates must not hide a validation error")
        controller.path.stringValue = ""
        controller.commitPath()
        XCTAssertFalse(controller.statusLabel.stringValue.contains("full path"), "Restoring the previous valid value must clear the error")
        controller.path.stringValue = "/bin/echo"
        controller.commitPath()
        XCTAssertEqual(changed?.yabaiPath, "/bin/echo")
        controller.login.performClick(nil)
        XCTAssertEqual(operations, [true])
        XCTAssertEqual(controller.login.state, .mixed)
        XCTAssertFalse(controller.loginHint.isHidden)
        serviceStatus = .enabled
        controller.refreshLoginState()
        XCTAssertEqual(controller.login.state, .on)
        XCTAssertTrue(controller.loginHint.isHidden)
        controller.login.performClick(nil)
        XCTAssertEqual(operations, [true, false])
        XCTAssertEqual(controller.login.state, .off)
        failLogin = true
        controller.login.performClick(nil)
        controller.updateStatus(ConnectionStatus(mode: .live, lastUpdated: Date()), path: "/opt/homebrew/bin/yabai")
        XCTAssertTrue(controller.statusLabel.stringValue.contains("login denied"))
        failLogin = false
        controller.login.performClick(nil)
        XCTAssertFalse(controller.statusLabel.stringValue.contains("login denied"))
        serviceStatus = .notRegistered
        controller.refreshLoginState()
        var checks = 0
        controller.onReconnect = { checks += 1 }
        controller.updateStatus(ConnectionStatus(mode: .live, lastUpdated: Date()), path: "/opt/homebrew/bin/yabai")
        controller.reconnect.performClick(nil)
        XCTAssertEqual(checks, 1)
        controller.path.stringValue = "/not/an/executable"
        controller.reconnect.performClick(nil)
        XCTAssertEqual(checks, 1, "Invalid uncommitted input must prevent connection checks")
        XCTAssertEqual(controller.value.yabaiPath, "/bin/echo")
        controller.path.stringValue = "/bin/ls"
        controller.reconnect.performClick(nil)
        XCTAssertEqual(changed?.yabaiPath, "/bin/ls", "Check Connection must commit valid input without requiring Return")
        XCTAssertEqual(checks, 1, "The path-change callback already starts the new connection")
        controller.reconnect.performClick(nil)
        XCTAssertEqual(checks, 2)
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "yabai-7.1.16", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let live = try Snapshot(spaces: JSONSerialization.data(withJSONObject: fixture["spaces"]!), windows: JSONSerialization.data(withJSONObject: fixture["windows"]!))
        var iconCalls = 0
        controller.updatePreview(live) { _ in iconCalls += 1; return NSImage(size: NSSize(width: 16, height: 16)) }
        XCTAssertEqual(controller.previewHint.stringValue, "Live preview")
        let rendered = iconCalls
        controller.updateStatus(ConnectionStatus(mode: .suspended), path: "/bin/ls")
        XCTAssertEqual(controller.previewHint.stringValue, "Last known preview")
        XCTAssertEqual(iconCalls, rendered, "Status-only changes must not redraw icons")
        controller.updateStatus(ConnectionStatus(mode: .live, lastUpdated: Date()), path: "/opt/homebrew/bin/yabai")
        XCTAssertEqual(controller.previewHint.stringValue, "Live preview")
        controller.updatePreview(nil) { _ in nil }

        let colorPanel = try XCTUnwrap(controller.tabs.tabViewItems.first { $0.label == "Colors" }?.view)
        let colorStack = try XCTUnwrap(colorPanel.subviews.first as? NSStackView)
        let reset = try XCTUnwrap(colorStack.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        for well in controller.colors.values {
            well.color = NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(well.action), to: well.target, from: well))
        }
        reset.performClick(nil)
        for (key, _) in AppSettings.colors { XCTAssertEqual(controller.value[keyPath: key], "") }
        let resetSuite = "test.yabai-menu.\(UUID().uuidString)"
        let resetDefaults = try XCTUnwrap(UserDefaults(suiteName: resetSuite))
        defer { resetDefaults.removePersistentDomain(forName: resetSuite) }
        controller.value.save(to: resetDefaults)
        for (key, _) in AppSettings.colors { XCTAssertEqual(AppSettings(defaults: resetDefaults)[keyPath: key], "") }
        controller.windowScope.selectItem(at: 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.windowScope.action), to: controller.windowScope.target, from: controller.windowScope))

        let window = try XCTUnwrap(controller.window)
        controller.placement.selectItem(at: 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.placement.action), to: controller.placement.target, from: controller.placement))
        controller.path.stringValue = ""
        controller.commitPath()
        window.orderFront(nil)
        window.makeFirstResponder(nil)
        let content = try XCTUnwrap(window.contentView)
        for (tabIndex, tabName) in [(0, "appearance"), (1, "spaces"), (2, "process"), (3, "colors"), (4, "floating"), (5, "connection")] {
          controller.tabs.selectTabViewItem(at: tabIndex)
          for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            content.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(content.subviews[0].frame.maxY, content.bounds.maxY)
            let panel = try XCTUnwrap(controller.tabs.selectedTabViewItem?.view)
            let stack = try XCTUnwrap(panel.subviews.first as? NSStackView)
            XCTAssertLessThanOrEqual(stack.fittingSize.height + 18, panel.bounds.height, "Settings must fit without clipped controls")
            for view in stack.arrangedSubviews where !view.isHidden {
                let frame = panel.convert(view.bounds, from: view)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, panel.bounds.maxX + 1, "Visible controls must fit after text wrapping")
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["YABAI_MENU_TEST_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let preview = NSImage(size: content.bounds.size)
                preview.lockFocus()
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(rect: content.bounds).fill()
                }
                NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: content.bounds.size).draw(in: content.bounds)
                preview.unlockFocus()
                let opaque = try XCTUnwrap(NSBitmapImageRep(data: preview.tiffRepresentation!))
                try opaque.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(tabName)-\(name).png"))
            }
          }
        }
    }
}
