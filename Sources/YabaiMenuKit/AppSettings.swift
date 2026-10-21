// SPDX-License-Identifier: GPL-3.0-only
import AppKit

struct AppSettings: Equatable {
    enum Density: String, CaseIterable {
        case compact, standard, custom
        var width: Double { self == .compact ? 180 : 280 }
    }
    enum Placement: String, CaseIterable { case menuBar, docked, floating }
    enum BarBackdrop: String, CaseIterable { case glass, solid, none }
    enum SpaceScope: String, CaseIterable { case all, focusedDisplay, hidden }
    enum SpaceName: String, CaseIterable { case number, label, numberAndLabel }
    enum FocusStyle: String, CaseIterable { case brackets, bold, underline }
    enum DisplaySeparatorStyle: String, CaseIterable { case none, line }
    enum WindowScope: String, CaseIterable { case currentSpace, focused, hidden, all }
    enum LayoutStyle: String, CaseIterable { case text, icon, off }
    var density: Density = .standard
    var placement: Placement = .menuBar
    var floatingHeight = 32
    var floatingOpacity = 100
    var floatingLocked = false
    var floatingAboveFullscreen = false
    var barBackdrop: BarBackdrop = .glass
    var barBackgroundOpacity = 85
    var barCornerRadius = 10
    var barHorizontalPadding = 6
    var barVerticalPadding = 3
    var barBorder = true
    var barShadow = true
    var displayGap = 12
    var displaySeparatorStyle: DisplaySeparatorStyle = .line
    var displaySeparatorThickness = 0.5
    var displaySeparatorPadding = 6
    var displaySeparatorColor = ""
    var unfocusedBackgroundOpacity = 35
    var colorPreset: ColorPreset = .system
    var focusedSpaceNameColor = ""
    var visibleSpaceNameColor = ""
    var inactiveSpaceNameColor = ""
    var spaceScope: SpaceScope = .all
    var spaceName: SpaceName = .number
    var focusStyle: FocusStyle = .brackets
    var windowScope: WindowScope = .hidden
    var groupSpacing = 4
    var spaceIconGap = 0
    var layoutIconSize = 16
    var unfocusedBrightness = 65
    var focusedSpaceColor = ""
    var visibleSpaceColor = ""
    var inactiveSpaceColor = ""
    var spaceWindowLayout: LayoutStyle = .icon
    var iconSize = 16
    var customWidth = 280
    var showLayout = true
    var showSpaceIcons = true
    var hideEmptySpaces = false
    var hideDuplicateApps = true
    var separateSticky = true
    var showCreateSpace = true
    var exclusions = ""
    var titleExclusions = ""
    var exclusionsAsRegex = false
    var showWindowTitle = true
    var processOnlyIcon = false
    var layoutStyle: LayoutStyle = .text
    var spaceLayout: LayoutStyle = .text
    var monochrome = false
    var fontName = ""
    var fontSize = 11
    var backgroundOpacity = 35
    var cornerRadius = 5
    var showBorder = false
    var yabaiPath = ""
    var width: Double { density == .custom ? Double(customWidth) : density.width }

    var effectivePlacement: Placement { placement }

    var resolvedPath: String? {
        if !yabaiPath.isEmpty { return (yabaiPath as NSString).expandingTildeInPath }
        return ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    init(defaults: UserDefaults = .standard) {
        density = Density(rawValue: defaults.string(forKey: "displayDensity") ?? "") ?? .standard
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .menuBar
        barBackdrop = BarBackdrop(rawValue: defaults.string(forKey: "barBackdrop") ?? "") ?? .glass
        let dividerStyle = defaults.string(forKey: "displaySeparatorStyle") ?? ""
        displaySeparatorStyle = DisplaySeparatorStyle(rawValue: dividerStyle == "dot" ? "line" : dividerStyle)
            ?? ((defaults.object(forKey: "showDisplaySeparators") as? Bool ?? true) ? .line : .none)
        if let thickness = defaults.object(forKey: "displaySeparatorThickness") as? Double, thickness.isFinite {
            displaySeparatorThickness = min(4, max(0.5, thickness))
        }
        colorPreset = ColorPreset(rawValue: defaults.string(forKey: "colorPreset") ?? "") ?? .system
        spaceScope = SpaceScope(rawValue: defaults.string(forKey: "spaceScope") ?? "") ?? .all
        spaceName = SpaceName(rawValue: defaults.string(forKey: "spaceName") ?? "") ?? .number
        focusStyle = FocusStyle(rawValue: defaults.string(forKey: "focusStyle") ?? "") ?? .brackets
        windowScope = WindowScope(rawValue: defaults.string(forKey: "windowScope") ?? "") ?? .hidden
        groupSpacing = ["compact": 2, "standard": 4, "relaxed": 8][defaults.string(forKey: "itemSpacing") ?? ""] ?? 4
        spaceWindowLayout = LayoutStyle(rawValue: defaults.string(forKey: "spaceWindowLayout") ?? "") ?? .icon
        for (key, name) in Self.colors { self[keyPath: key] = Self.checkedColor(defaults.string(forKey: name) ?? "") }
        // Migrate the old linked text/background colors once; an explicit empty name color follows its theme.
        for (nameKey, name, backgroundKey) in [(\Self.focusedSpaceNameColor, "focusedSpaceNameColor", \Self.focusedSpaceColor),
                                             (\Self.visibleSpaceNameColor, "visibleSpaceNameColor", \Self.visibleSpaceColor),
                                             (\Self.inactiveSpaceNameColor, "inactiveSpaceNameColor", \Self.inactiveSpaceColor)] {
            if defaults.object(forKey: name) == nil { self[keyPath: nameKey] = self[keyPath: backgroundKey] }
        }
        if defaults.object(forKey: "unfocusedBackgroundOpacity") == nil {
            unfocusedBackgroundOpacity = defaults.object(forKey: "backgroundOpacity") == nil ? 35 : min(100, max(0, defaults.integer(forKey: "backgroundOpacity")))
        }
        showLayout = defaults.object(forKey: "showLayout") as? Bool ?? true
        for (key, fallback) in Self.booleans { self[keyPath: key] = defaults.object(forKey: fallback.0) as? Bool ?? fallback.1 }
        exclusions = defaults.string(forKey: "exclusions") ?? ""
        titleExclusions = defaults.string(forKey: "titleExclusions") ?? ""
        fontName = defaults.string(forKey: "fontName") ?? ""
        layoutStyle = LayoutStyle(rawValue: defaults.string(forKey: "layoutStyle") ?? "") ?? .text
        spaceLayout = LayoutStyle(rawValue: defaults.string(forKey: "spaceLayout") ?? "") ?? .text
        for (key, name, range) in Self.numbers where defaults.object(forKey: name) != nil {
            self[keyPath: key] = min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: name)))
        }
        yabaiPath = defaults.string(forKey: "yabaiPath") ?? ""
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(placement.rawValue, forKey: "placement")
        defaults.set(barBackdrop.rawValue, forKey: "barBackdrop")
        defaults.set(displaySeparatorStyle.rawValue, forKey: "displaySeparatorStyle")
        defaults.set(displaySeparatorThickness, forKey: "displaySeparatorThickness")
        defaults.set(displaySeparatorStyle != .none, forKey: "showDisplaySeparators")
        defaults.set(colorPreset.rawValue, forKey: "colorPreset")
        defaults.set(density.rawValue, forKey: "displayDensity")
        defaults.set(spaceScope.rawValue, forKey: "spaceScope")
        defaults.set(spaceName.rawValue, forKey: "spaceName")
        defaults.set(focusStyle.rawValue, forKey: "focusStyle")
        defaults.set(windowScope.rawValue, forKey: "windowScope")
        defaults.set(showLayout, forKey: "showLayout")
        defaults.set(spaceWindowLayout.rawValue, forKey: "spaceWindowLayout")
        for (key, name) in Self.colors { defaults.set(Self.checkedColor(self[keyPath: key]), forKey: name) }
        for (key, info) in Self.booleans { defaults.set(self[keyPath: key], forKey: info.0) }
        for (key, name, _) in Self.numbers { defaults.set(self[keyPath: key], forKey: name) }
        defaults.set(exclusions, forKey: "exclusions")
        defaults.set(titleExclusions, forKey: "titleExclusions")
        defaults.set(fontName, forKey: "fontName")
        defaults.set(layoutStyle.rawValue, forKey: "layoutStyle")
        defaults.set(spaceLayout.rawValue, forKey: "spaceLayout")
        defaults.set(yabaiPath, forKey: "yabaiPath")
    }

    private static let booleans: [(WritableKeyPath<Self, Bool>, (String, Bool))] = [
        (\.showSpaceIcons, ("showSpaceIcons", true)), (\.hideEmptySpaces, ("hideEmptySpaces", false)),
        (\.hideDuplicateApps, ("hideDuplicateApps", true)), (\.separateSticky, ("separateSticky", true)),
        (\.showCreateSpace, ("showCreateSpace", true)), (\.exclusionsAsRegex, ("exclusionsAsRegex", false)),
        (\.showWindowTitle, ("showWindowTitle", true)), (\.processOnlyIcon, ("processOnlyIcon", false)),
        (\.monochrome, ("monochrome", false)), (\.showBorder, ("showBorder", false)),
        (\.floatingLocked, ("floatingLocked", false)), (\.floatingAboveFullscreen, ("floatingAboveFullscreen", false)),
        (\.barBorder, ("barBorder", true)), (\.barShadow, ("barShadow", true))]
    private static let numbers: [(WritableKeyPath<Self, Int>, String, ClosedRange<Int>)] = [
        (\.fontSize, "fontSize", 8...24), (\.backgroundOpacity, "backgroundOpacity", 0...100),
        (\.cornerRadius, "cornerRadius", 0...18), (\.iconSize, "iconSize", 8...32),
        (\.layoutIconSize, "layoutIconSize", 8...32), (\.customWidth, "customWidth", 120...1000),
        (\.groupSpacing, "groupSpacing", 0...24), (\.spaceIconGap, "spaceIconGap", 0...16),
        (\.displaySeparatorPadding, "displaySeparatorPadding", 0...24),
        (\.unfocusedBrightness, "unfocusedBrightness", 0...100),
        (\.unfocusedBackgroundOpacity, "unfocusedBackgroundOpacity", 0...100), (\.displayGap, "displayGap", 0...64),
        (\.floatingHeight, "floatingHeight", 24...64), (\.floatingOpacity, "floatingOpacity", 20...100),
        (\.barBackgroundOpacity, "barBackgroundOpacity", 0...100), (\.barCornerRadius, "barCornerRadius", 0...24),
        (\.barHorizontalPadding, "barHorizontalPadding", 0...24), (\.barVerticalPadding, "barVerticalPadding", 0...12)]

    static let colors: [(WritableKeyPath<Self, String>, String)] = [
        (\.focusedSpaceColor, "focusedSpaceColor"), (\.visibleSpaceColor, "visibleSpaceColor"),
        (\.inactiveSpaceColor, "inactiveSpaceColor"), (\.focusedSpaceNameColor, "focusedSpaceNameColor"),
        (\.visibleSpaceNameColor, "visibleSpaceNameColor"), (\.inactiveSpaceNameColor, "inactiveSpaceNameColor"),
        (\.displaySeparatorColor, "displaySeparatorColor")]

    static func checkedColor(_ value: String) -> String {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return "" }
        return "#" + hex.uppercased()
    }

    private func color(_ override: String, preset: Int, fallback: NSColor) -> NSColor {
        let custom = Self.checkedColor(override)
        let value = custom.isEmpty ? colorPreset.colors[preset] : custom
        guard let rgb = UInt32(value.dropFirst(), radix: 16) else { return fallback }
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }

    func spaceColor(focused: Bool, visible: Bool) -> NSColor {
        color(focused ? focusedSpaceColor : (visible ? visibleSpaceColor : inactiveSpaceColor),
              preset: focused ? 0 : (visible ? 1 : 2),
              fallback: focused ? .controlAccentColor : (visible ? .secondaryLabelColor : .tertiaryLabelColor))
    }

    func spaceNameColor(focused: Bool, visible: Bool) -> NSColor {
        color(focused ? focusedSpaceNameColor : (visible ? visibleSpaceNameColor : inactiveSpaceNameColor),
              preset: focused ? 3 : (visible ? 4 : 5), fallback: .labelColor)
    }

    var contentColor: NSColor { color("", preset: 6, fallback: .labelColor) }
    // Mint/Sky 的强调色在背景色中，其余主题沿用焦点名称色。
    var separatorColor: NSColor { color(displaySeparatorColor, preset: colorPreset.colors[3].isEmpty ? 0 : 3, fallback: .labelColor) }
    func backgroundAlpha(focused: Bool, visible: Bool) -> CGFloat {
        CGFloat(focused ? backgroundOpacity : unfocusedBackgroundOpacity) / 100 * (focused ? 0.65 : (visible ? 0.4 : 0.15))
    }

    static func checkedPath(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw MenuError.message("Choose an executable yabai file using its full path, or leave the field empty for automatic detection.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else {
            throw MenuError.message("The yabai path must point to an executable file.")
        }
        return path
    }
}
