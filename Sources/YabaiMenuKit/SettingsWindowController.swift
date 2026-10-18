// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ServiceManagement

struct LoginItemAccess {
    var status: () -> SMAppService.Status
    var setEnabled: (Bool) throws -> Void
    var openSettings: () -> Void
    static var system: Self {
        Self(status: { SMAppService.mainApp.status }, setEnabled: { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        }, openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onChange: ((AppSettings) -> Void)?
    var onReconnect: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onEnableWindowObservation: (() -> Void)?
    private(set) var value: AppSettings
    let density = NSPopUpButton()
    let placement = NSPopUpButton()
    let barBackdrop = NSPopUpButton()
    let colorPreset = NSPopUpButton()
    let windowLayout = NSPopUpButton()
    let spaceLayout = NSPopUpButton()
    let spaceWindowLayout = NSPopUpButton()
    private(set) var colors: [WritableKeyPath<AppSettings, String>: NSColorWell] = [:]
    let richPreview = WidgetBarView()
    let previewBackdrop = BarBackdropView()
    let previewContainer = NSView()
    private var previewHeight: NSLayoutConstraint!
    private var toggles: [WritableKeyPath<AppSettings, Bool>: NSButton] = [:]
    private var numbers: [WritableKeyPath<AppSettings, Int>: NSPopUpButton] = [:]
    private var texts: [WritableKeyPath<AppSettings, String>: NSTextField] = [:]
    let scope = NSPopUpButton()
    let spaceName = NSPopUpButton()
    let focusStyle = NSPopUpButton()
    let windowScope = NSPopUpButton()
    let iconSize = NSPopUpButton()
    let width = NSSlider(value: 280, minValue: 120, maxValue: 1000, target: nil, action: nil)
    let widthLabel = NSTextField(labelWithString: "280 pt")
    let previewHint = NSTextField(labelWithString: "Example preview")
    let tabs = NSTabView()
    let layout = NSButton(checkboxWithTitle: "Show focused window layout", target: nil, action: nil)
    let path = NSTextField(string: "")
    let login = NSButton(checkboxWithTitle: "Launch Yabai Menu at login", target: nil, action: nil)
    let reconnect = NSButton(title: "Check Connection", target: nil, action: nil)
    let accessibility = NSButton(title: "Enable Native Window Updates…", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "Connecting…")
    let loginHint = NSTextField(wrappingLabelWithString: "")
    private let loginAccess: LoginItemAccess
    private let loginSettings = NSButton(title: "Open Login Items", target: nil, action: nil)
    private var lastStatus = ConnectionStatus()
    private var lastPath: String?
    private var pathError: String?
    private var loginError: String?
    private var lastLoginStatus: SMAppService.Status?
    private var previewSnapshot: Snapshot?
    private var previewIcon: ((Window) -> NSImage?)?
    private var renderedPreview: (Snapshot, AppSettings)?
    private let exampleIcon = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Example window")

    init(settings: AppSettings, loginAccess: LoginItemAccess? = nil) {
        value = settings
        self.loginAccess = loginAccess ?? .system
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Yabai Menu Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        density.addItems(withTitles: ["Compact · 180 pt", "Standard · 280 pt", "Custom"])
        density.selectItem(at: AppSettings.Density.allCases.firstIndex(of: settings.density)!)
        scope.addItems(withTitles: ["All displays · independent current Spaces", "This display only", "Hide Spaces"])
        scope.selectItem(at: AppSettings.SpaceScope.allCases.firstIndex(of: settings.spaceScope)!)
        spaceName.addItems(withTitles: ["Number", "Label", "Number and label"])
        spaceName.selectItem(at: AppSettings.SpaceName.allCases.firstIndex(of: settings.spaceName)!)
        focusStyle.addItems(withTitles: ["Brackets and bold", "Bold", "Underline and bold"])
        focusStyle.selectItem(at: AppSettings.FocusStyle.allCases.firstIndex(of: settings.focusStyle)!)
        windowScope.addItems(withTitles: ["Current Space windows", "Focused window only", "Hide Process", "All Spaces windows"])
        windowScope.selectItem(at: AppSettings.WindowScope.allCases.firstIndex(of: settings.windowScope)!)
        for size in 8...32 { iconSize.addItem(withTitle: "\(size) pt"); iconSize.lastItem?.tag = size }
        iconSize.selectItem(withTag: settings.iconSize)
        width.doubleValue = Double(settings.customWidth)
        width.numberOfTickMarks = 45
        width.allowsTickMarkValuesOnly = true
        width.isContinuous = true
        width.target = self; width.action = #selector(displayChanged(_:))
        width.setAccessibilityLabel("Custom menu-bar width")
        placement.addItems(withTitles: ["Menu bar", "Per-display top bar", "Floating · per display"])
        placement.selectItem(at: AppSettings.Placement.allCases.firstIndex(of: settings.effectivePlacement)!)
        barBackdrop.addItems(withTitles: ["Frosted glass", "Solid", "None"])
        barBackdrop.selectItem(at: AppSettings.BarBackdrop.allCases.firstIndex(of: settings.barBackdrop)!)
        colorPreset.addItems(withTitles: ColorPreset.allCases.map(\.title))
        colorPreset.selectItem(at: ColorPreset.allCases.firstIndex(of: settings.colorPreset)!)
        for popup in [windowLayout, spaceLayout, spaceWindowLayout] { popup.addItems(withTitles: ["Text", "Icon", "Off"]) }
        windowLayout.selectItem(at: AppSettings.LayoutStyle.allCases.firstIndex(of: settings.layoutStyle)!)
        spaceLayout.selectItem(at: AppSettings.LayoutStyle.allCases.firstIndex(of: settings.spaceLayout)!)
        spaceWindowLayout.selectItem(at: AppSettings.LayoutStyle.allCases.firstIndex(of: settings.spaceWindowLayout)!)
        layout.state = settings.showLayout ? .on : .off
        path.stringValue = settings.yabaiPath
        path.placeholderString = "Automatic detection"
        path.delegate = self
        path.target = self
        path.action = #selector(commitPath)
        for popup in [density, scope, spaceName, focusStyle, windowScope, iconSize, placement, barBackdrop, colorPreset, windowLayout, spaceLayout, spaceWindowLayout] { popup.target = self; popup.action = #selector(displayChanged(_:)) }
        layout.target = self; layout.action = #selector(displayChanged(_:))
        login.target = self; login.action = #selector(loginChanged)
        login.allowsMixedState = true
        reconnect.target = self; reconnect.action = #selector(checkConnection)
        accessibility.target = self; accessibility.action = #selector(enableWindowObservation)
        loginSettings.target = self; loginSettings.action = #selector(openLoginSettings)

        let widthControl = NSStackView(views: [width, widthLabel])
        widthControl.orientation = .horizontal
        width.widthAnchor.constraint(equalToConstant: 225).isActive = true
        func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
        func toggle(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>) -> NSButton {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(displayChanged(_:)))
            button.state = settings[keyPath: key] ? .on : .off
            toggles[key] = button
            return button
        }
        func number(_ key: WritableKeyPath<AppSettings, Int>, values: [Int], suffix: String = "") -> NSPopUpButton {
            let popup = NSPopUpButton()
            for value in values { popup.addItem(withTitle: "\(value)\(suffix)"); popup.lastItem?.tag = value }
            if !values.contains(settings[keyPath: key]) { popup.addItem(withTitle: "\(settings[keyPath: key])\(suffix)"); popup.lastItem?.tag = settings[keyPath: key] }
            popup.selectItem(withTag: settings[keyPath: key])
            popup.target = self; popup.action = #selector(displayChanged(_:))
            numbers[key] = popup
            return popup
        }
        func text(_ key: WritableKeyPath<AppSettings, String>, placeholder: String) -> NSTextField {
            let field = NSTextField(string: settings[keyPath: key])
            field.placeholderString = placeholder
            field.target = self; field.action = #selector(displayChanged(_:)); field.delegate = self
            texts[key] = field
            return field
        }
        func color(_ key: WritableKeyPath<AppSettings, String>, value: NSColor) -> NSColorWell {
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 50, height: 24))
            well.color = value
            well.target = self; well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 50).isActive = true
            colors[key] = well
            return well
        }
        let grid = NSGridView(views: [
            [label("Menu width"), density],
            [label("Custom width"), widthControl], [label("App icon size"), iconSize],
            [label("Layout icon size"), number(\.layoutIconSize, values: Array(8...32), suffix: " pt")],
            [label("Space icon gap"), number(\.spaceIconGap, values: Array(0...16), suffix: " pt")],
            [label("Group gap"), number(\.groupSpacing, values: Array(0...24), suffix: " pt")],
            [label("Display gap"), number(\.displayGap, values: Array(0...64), suffix: " pt")],
            [label("Display divider"), toggle("Show a line between displays", \.showDisplaySeparators)],
            [label("Font"), text(\.fontName, placeholder: "System font")],
            [label("Font size"), number(\.fontSize, values: Array(8...24), suffix: " pt")],
            [label("App icons"), toggle("Monochrome", \.monochrome)]
        ])
        let colorsGrid = NSGridView(views: [
            [label("Theme preset"), colorPreset],
            [label("Focused Space"), color(\.focusedSpaceColor, value: settings.spaceColor(focused: true, visible: true))],
            [label("Visible Space"), color(\.visibleSpaceColor, value: settings.spaceColor(focused: false, visible: true))],
            [label("Inactive Space"), color(\.inactiveSpaceColor, value: settings.spaceColor(focused: false, visible: false))],
            [label("Focused name"), color(\.focusedSpaceNameColor, value: settings.spaceNameColor(focused: true, visible: true))],
            [label("Visible name"), color(\.visibleSpaceNameColor, value: settings.spaceNameColor(focused: false, visible: true))],
            [label("Inactive name"), color(\.inactiveSpaceNameColor, value: settings.spaceNameColor(focused: false, visible: false))],
            [label("Unfocused icons"), number(\.unfocusedBrightness, values: Array(stride(from: 0, through: 100, by: 5)), suffix: "%")],
            [label("Focused bg"), number(\.backgroundOpacity, values: Array(stride(from: 0, through: 100, by: 5)), suffix: "%")],
            [label("Unfocused bg"), number(\.unfocusedBackgroundOpacity, values: Array(stride(from: 0, through: 100, by: 5)), suffix: "%")],
            [label("Corner radius"), number(\.cornerRadius, values: Array(0...18), suffix: " pt")],
            [label("Borders"), toggle("Show group borders", \.showBorder)]
        ])
        let spacesGrid = NSGridView(views: [
            [label("Spaces"), scope], [label("Space names"), spaceName], [label("Current Space"), focusStyle],
            [label("App icons"), toggle("Show apps inside each Space", \.showSpaceIcons)],
            [label("Window layout"), spaceWindowLayout],
            [label("Empty Spaces"), toggle("Hide empty Spaces", \.hideEmptySpaces)],
            [label("Duplicate apps"), toggle("Keep one icon per app", \.hideDuplicateApps)],
            [label("Sticky windows"), toggle("Show a separate pinned group", \.separateSticky)],
            [label("Create button"), toggle("Show + beside Spaces", \.showCreateSpace)],
            [label("Exclude names"), text(\.exclusions, placeholder: "App names / Space labels, comma-separated")],
            [label("Exclude titles"), text(\.titleExclusions, placeholder: "Title substrings, comma-separated")],
            [label("Matching"), toggle("Use regular expressions", \.exclusionsAsRegex)]
        ])
        let processGrid = NSGridView(views: [
            [label("Window scope"), windowScope],
            [label("Focused app"), toggle("Show only its icon", \.processOnlyIcon)],
            [label("Window title"), toggle("Show title beside the app name", \.showWindowTitle)],
            [label("Window state"), layout],
            [label("Window layout"), windowLayout], [label("Space layout"), spaceLayout]
        ])
        let floatingGrid = NSGridView(views: [
            [label("Placement"), placement],
            [label("Content height"), number(\.floatingHeight, values: Array(24...64), suffix: " pt")],
            [label("Window opacity"), number(\.floatingOpacity, values: Array(stride(from: 20, through: 100, by: 5)), suffix: "%")],
            [label("Backdrop"), barBackdrop],
            [label("Glass tint"), number(\.barBackgroundOpacity, values: Array(stride(from: 0, through: 100, by: 5)), suffix: "%")],
            [label("Bar radius"), number(\.barCornerRadius, values: Array(0...24), suffix: " pt")],
            [label("Side padding"), number(\.barHorizontalPadding, values: Array(0...24), suffix: " pt")],
            [label("Vertical padding"), number(\.barVerticalPadding, values: Array(0...12), suffix: " pt")],
            [label("Bar border"), toggle("Show a subtle outline", \.barBorder)],
            [label("Bar shadow"), toggle("Show native window shadow", \.barShadow)],
            [label("Lock position"), toggle("Keep the floating bar in place", \.floatingLocked)],
            [label("Full screen"), toggle("Show above full-screen apps", \.floatingAboveFullscreen)]
        ])
        let connectionGrid = NSGridView(views: [
            [NSTextField(labelWithString: "yabai path"), path],
            [NSTextField(labelWithString: "Startup"), login],
            [NSTextField(labelWithString: "Window events"), accessibility]
        ])
        for table in [grid, colorsGrid, spacesGrid, processGrid, floatingGrid, connectionGrid] {
            table.rowSpacing = 10
            table.columnSpacing = 14
            table.column(at: 0).width = 100
            table.column(at: 1).width = 350
        }
        let explanation = NSTextField(wrappingLabelWithString: "Each per-display bar follows its own visible Space. Leave the path empty to find a standard Homebrew installation.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let eventNote = NSTextField(wrappingLabelWithString: "Native window updates reuse a-bar's Accessibility event path. Enable Yabai Menu in macOS Accessibility, then Check Connection. Titles update from native events; window movement settles after 300 ms. Layout / float / sticky scripts still need a refresh notification.")
        eventNote.font = .systemFont(ofSize: 11)
        eventNote.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        let about = NSButton(title: "About", target: self, action: #selector(aboutApp))
        let buttons = NSStackView(views: [reconnect, copy, about])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let appearanceNote = NSTextField(wrappingLabelWithString: "Changes apply immediately. Sizes fit the native menu-bar height. Extra items move to +N; right-click any item for the full menu and settings.")
        appearanceNote.font = .systemFont(ofSize: 11)
        appearanceNote.textColor = .secondaryLabelColor
        previewHint.font = .systemFont(ofSize: 11)
        previewHint.textColor = .secondaryLabelColor
        richPreview.setAccessibilityLabel("Menu-bar appearance preview")
        previewContainer.addSubview(previewBackdrop)
        previewContainer.addSubview(richPreview)
        let appearance = NSStackView(views: [previewHint, previewContainer, NSBox.separator(), grid, appearanceNote])
        let spacesNote = NSTextField(wrappingLabelWithString: "Current Space marks each display's visible Space, even with no background. This display only also works in Menu bar placement. Left-click a Space/app to select it; right-click for management, the full menu and settings. Invalid regex patterns match nothing.")
        let processNote = NSTextField(wrappingLabelWithString: "Process is optional. Both views show window layout and sticky state inside Spaces. Space layout describes the desktop; window layout describes the focused window. Hidden and minimized windows stay available for recovery.")
        for note in [spacesNote, processNote] { note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant: 464).isActive = true }
        let colorNote = NSTextField(wrappingLabelWithString: "Space background and name colors are independent. Set Unfocused bg to 0% for transparent inactive Spaces. Picking a preset replaces the six color overrides; later edits customize that preset.")
        colorNote.font = .systemFont(ofSize: 11); colorNote.textColor = .secondaryLabelColor
        colorNote.widthAnchor.constraint(equalToConstant: 464).isActive = true
        let resetColors = NSButton(title: "Use System Colors", target: self, action: #selector(resetColors))
        let colorPanel = NSStackView(views: [colorsGrid, resetColors, colorNote])
        let floatingNote = NSTextField(wrappingLabelWithString: "Drag the left handle to move a floating bar; positions are saved per screen. Padding adds to content height. Glass tint affects only the background; Window opacity also fades text. Solid stays opaque. None disables the bar shadow.")
        floatingNote.font = .systemFont(ofSize: 11); floatingNote.textColor = .secondaryLabelColor
        floatingNote.widthAnchor.constraint(equalToConstant: 464).isActive = true
        let floating = NSStackView(views: [floatingGrid, floatingNote])
        let spaces = NSStackView(views: [spacesGrid, spacesNote])
        let process = NSStackView(views: [processGrid, processNote])
        let connection = NSStackView(views: [connectionGrid, explanation, loginHint, loginSettings, NSBox.separator(), statusLabel, buttons, eventNote])
        for (title, stack) in [("Appearance", appearance), ("Spaces", spaces), ("Process", process), ("Colors", colorPanel), ("Floating", floating), ("Connection", connection)] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            let panel = NSView()
            panel.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18)
            ])
            let tab = NSTabViewItem(identifier: title)
            tab.label = title
            tab.view = panel
            tabs.addTabViewItem(tab)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(tabs)
        previewHeight = previewContainer.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalTo: connection.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: connection.widthAnchor),
            eventNote.widthAnchor.constraint(equalTo: connection.widthAnchor),
            loginHint.widthAnchor.constraint(equalTo: connection.widthAnchor),
            appearanceNote.widthAnchor.constraint(equalTo: appearance.widthAnchor),
            previewHeight,
            previewContainer.widthAnchor.constraint(equalTo: appearance.widthAnchor)
        ])
        statusLabel.maximumNumberOfLines = 4
        refreshLoginState()
        refreshPreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateStatus(_ status: ConnectionStatus, path: String?) {
        lastStatus = status
        lastPath = path
        previewHint.stringValue = previewDescription
        renderStatus()
    }

    private var previewDescription: String {
        guard previewSnapshot != nil else { return "Example preview · Connect yabai for live data" }
        return lastStatus.mode == .live || lastStatus.mode == .limited ? "Live preview" : "Last known preview"
    }

    private func renderStatus() {
        var lines = [lastStatus.title, lastStatus.updatedDescription()]
        if let message = pathError ?? loginError ?? lastStatus.message { lines.append(message) }
        if let lastPath { lines.append(lastPath) }
        statusLabel.stringValue = lines.joined(separator: "\n")
        statusLabel.toolTip = statusLabel.stringValue
        reconnect.isEnabled = lastStatus.mode != .connecting
        fitWindow()
    }

    @objc private func displayChanged(_ sender: Any? = nil) {
        value.density = AppSettings.Density.allCases[density.indexOfSelectedItem]
        value.spaceScope = AppSettings.SpaceScope.allCases[scope.indexOfSelectedItem]
        value.placement = AppSettings.Placement.allCases[placement.indexOfSelectedItem]
        value.barBackdrop = AppSettings.BarBackdrop.allCases[barBackdrop.indexOfSelectedItem]
        let preset = ColorPreset.allCases[colorPreset.indexOfSelectedItem]
        if preset != value.colorPreset {
            value.colorPreset = preset
            for (key, _) in AppSettings.colors { value[keyPath: key] = "" }
        }
        value.spaceName = AppSettings.SpaceName.allCases[spaceName.indexOfSelectedItem]
        value.focusStyle = AppSettings.FocusStyle.allCases[focusStyle.indexOfSelectedItem]
        value.windowScope = AppSettings.WindowScope.allCases[windowScope.indexOfSelectedItem]
        value.iconSize = iconSize.selectedItem?.tag ?? 16
        value.customWidth = min(1000, max(120, Int(width.doubleValue.rounded())))
        value.showLayout = layout.state == .on
        value.layoutStyle = AppSettings.LayoutStyle.allCases[windowLayout.indexOfSelectedItem]
        value.spaceLayout = AppSettings.LayoutStyle.allCases[spaceLayout.indexOfSelectedItem]
        value.spaceWindowLayout = AppSettings.LayoutStyle.allCases[spaceWindowLayout.indexOfSelectedItem]
        for (key, control) in toggles { value[keyPath: key] = control.state == .on }
        for (key, control) in numbers { value[keyPath: key] = control.selectedItem?.tag ?? value[keyPath: key] }
        for (key, control) in texts { value[keyPath: key] = control.stringValue }
        onChange?(value)
        refreshPreview()
    }

    func updatePreview(_ snapshot: Snapshot?, icon: @escaping (Window) -> NSImage?) {
        previewSnapshot = snapshot
        previewIcon = icon
        refreshPreview()
    }

    private func refreshPreview() {
        syncColorWells()
        windowLayout.isEnabled = value.showLayout
        let floating = value.effectivePlacement != .menuBar
        numbers[\.floatingHeight]?.isEnabled = floating
        numbers[\.floatingOpacity]?.isEnabled = floating
        toggles[\.floatingLocked]?.isEnabled = value.effectivePlacement == .floating
        toggles[\.floatingAboveFullscreen]?.isEnabled = floating
        barBackdrop.isEnabled = floating
        numbers[\.barBackgroundOpacity]?.isEnabled = floating && value.barBackdrop == .glass
        for key in [\AppSettings.barCornerRadius, \.barHorizontalPadding, \.barVerticalPadding] { numbers[key]?.isEnabled = floating }
        toggles[\.barBorder]?.isEnabled = floating && value.barBackdrop != .none
        toggles[\.barShadow]?.isEnabled = floating && value.barBackdrop != .none
        width.isEnabled = value.density == .custom
        widthLabel.stringValue = "\(value.customWidth) pt"
        iconSize.isEnabled = value.windowScope != .hidden || value.showSpaceIcons || value.separateSticky
        previewHint.stringValue = previewDescription
        let state = previewSnapshot ?? Self.example
        guard renderedPreview?.0 != state || renderedPreview?.1 != value else { return }
        renderedPreview = (state, value)
        let loadIcon: (Window) -> NSImage? = { [self] in previewSnapshot == nil ? exampleIcon : previewIcon?($0) }
        var previewSettings = value
        let horizontal = floating ? CGFloat(value.barHorizontalPadding) : 0
        let vertical = floating ? CGFloat(value.barVerticalPadding) : 0
        previewSettings.density = .custom
        previewSettings.customWidth = Int(min(value.width, 464 - horizontal * 2))
        richPreview.appearance = floating ? value.colorPreset.appearance : nil
        richPreview.configure(state, settings: previewSettings, height: floating ? CGFloat(value.floatingHeight) : 24, display: value.spaceScope == .focusedDisplay ? state.focusedSpace?.display : nil, icon: loadIcon)
        richPreview.frame.origin = NSPoint(x: horizontal, y: vertical)
        previewBackdrop.configure(value)
        previewBackdrop.isHidden = !floating || value.barBackdrop == .none
        previewBackdrop.frame = NSRect(x: 0, y: 0, width: richPreview.frame.width + horizontal * 2, height: richPreview.frame.height + vertical * 2)
        previewHeight.constant = previewBackdrop.frame.height
        previewContainer.alphaValue = floating ? CGFloat(value.floatingOpacity) / 100 : 1
    }

    func syncFloatingLocked(_ locked: Bool) {
        value.floatingLocked = locked
        toggles[\.floatingLocked]?.state = locked ? .on : .off
        refreshPreview()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let key = colors.first(where: { $0.value === sender })?.key,
              let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        value[keyPath: key] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        onChange?(value)
        refreshPreview()
    }

    @objc private func resetColors() {
        for (key, _) in AppSettings.colors { value[keyPath: key] = "" }
        value.colorPreset = .system
        colorPreset.selectItem(at: 0)
        syncColorWells()
        onChange?(value)
        refreshPreview()
    }

    private func syncColorWells() {
        colors[\.focusedSpaceColor]?.color = value.spaceColor(focused: true, visible: true)
        colors[\.visibleSpaceColor]?.color = value.spaceColor(focused: false, visible: true)
        colors[\.inactiveSpaceColor]?.color = value.spaceColor(focused: false, visible: false)
        colors[\.focusedSpaceNameColor]?.color = value.spaceNameColor(focused: true, visible: true)
        colors[\.visibleSpaceNameColor]?.color = value.spaceNameColor(focused: false, visible: true)
        colors[\.inactiveSpaceNameColor]?.color = value.spaceNameColor(focused: false, visible: false)
    }

    private static let example = try! Snapshot(spaces: Data("""
        [{"id":1,"index":1,"label":"Work","display":1,"type":"bsp","has-focus":true,"is-visible":true},
         {"id":2,"index":2,"label":"Read","display":1,"type":"bsp","has-focus":false,"is-visible":false},
         {"id":3,"index":3,"label":"","display":2,"type":"bsp","has-focus":false,"is-visible":true}]
        """.utf8), windows: Data("""
        [{"id":1,"pid":0,"app":"Example","title":"Example window","space":1,"has-focus":true,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":0}},
         {"id":2,"pid":0,"app":"Example","title":"Example window","space":1,"has-focus":false,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":100}}]
        """.utf8))

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === path { commitPath() }
        else { displayChanged() }
    }

    @objc func commitPath() {
        do {
            let checked = try AppSettings.checkedPath(path.stringValue)
            pathError = nil
            path.textColor = .labelColor
            path.toolTip = nil
            guard checked != value.yabaiPath else { renderStatus(); return }
            value.yabaiPath = checked
            path.stringValue = checked
            onChange?(value)
            renderStatus()
        } catch {
            pathError = error.localizedDescription
            path.textColor = .systemRed
            path.toolTip = pathError
            renderStatus()
        }
    }

    @objc private func checkConnection() {
        let previousPath = value.yabaiPath
        commitPath()
        // A changed path starts its own connection through onChange.
        guard pathError == nil, previousPath == value.yabaiPath else { return }
        onReconnect?()
    }
    @objc private func copyDiagnostics() { onCopyDiagnostics?() }
    @objc private func enableWindowObservation() { onEnableWindowObservation?() }
    @objc private func aboutApp() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func openLoginSettings() { loginAccess.openSettings() }

    @objc private func loginChanged() {
        let current = loginAccess.status()
        loginError = nil
        do { try loginAccess.setEnabled(current != .enabled && current != .requiresApproval) }
        catch { loginError = "Could not change login startup. \(error.localizedDescription)" }
        refreshLoginState()
    }

    func refreshLoginState() {
        let status = loginAccess.status()
        if lastLoginStatus != status { loginError = nil }
        lastLoginStatus = status
        login.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginHint.stringValue = status == .requiresApproval ? "Approve Yabai Menu in System Settings to finish enabling startup." : (status == .notFound ? "macOS could not find this installed app for login startup." : "")
        loginHint.isHidden = loginHint.stringValue.isEmpty
        loginSettings.isHidden = status != .requiresApproval
        renderStatus()
    }

    private func fitWindow() {
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshLoginState() }
}

private extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
