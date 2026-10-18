// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：用原生按钮显示可独立点击的 Spaces 和 Process。
// 代码逻辑：1. 生成窗口布局和分组；2. 按宽度保留焦点并裁减；3. 仅加载可见图标并分发点击。
// 必需输入：快照、外观设置和动作回调。预期输出：支持两种密度和右键菜单的菜单栏视图。
import AppKit

enum BarTarget: Equatable {
    case space(Int), window(Int, Int?), create(Int), menu
}

@MainActor
final class WidgetBarView: NSView {
    struct Cell: Equatable {
        var text: String
        var spaceName: String?
        var detail = ""
        var symbol: String?
        var window: Window?
        var target: BarTarget
        var group: String
        var focus = false
        var visible = false
        var display: Int?
        var isProcess = false
        var tooltip: String
        var width: CGFloat = 0
        var opacity: CGFloat = 1
        var currentSpace: Bool {
            if case .space = target { return focus || visible }
            return false
        }
        static func == (a: Self, b: Self) -> Bool {
            // Geometry is not visible unless it changes the order of the resulting cells.
            a.hasSameDrawing(as: b) && a.spaceName == b.spaceName && a.target == b.target
                && a.group == b.group && a.isProcess == b.isProcess && a.display == b.display
                && a.tooltip == b.tooltip && a.window?.focused == b.window?.focused
        }
        func hasSameDrawing(as other: Self) -> Bool {
            text == other.text && detail == other.detail && symbol == other.symbol
                && focus == other.focus && visible == other.visible && currentSpace == other.currentSpace
                && opacity == other.opacity && window?.id == other.window?.id && window?.pid == other.window?.pid
        }
    }
    struct RenderState: Equatable {
        let cells: [Cell]
        let settings: AppSettings
        let omitted: Int
        let height: CGFloat
        let enabled: Bool
    }
    struct Layout {
        let state: RenderState
        let cells: [Cell]
        let frames: [NSRect]
        let backgrounds: [(NSRect, Bool, Bool)]
        let separators: [CGFloat]
        let size: NSSize
        let regularFont: NSFont
        let boldFont: NSFont
        let smallFont: NSFont
    }
    private var renderedState: RenderState?
    private(set) var cells: [Cell] = []
    private var settings = AppSettings()
    private var backgrounds: [(NSRect, Bool, Bool)] = []
    private(set) var displaySeparators: [CGFloat] = []
    var onSelect: ((BarTarget) -> Void)?
    var contextMenu: ((BarTarget) -> NSMenu?)?
    override var intrinsicContentSize: NSSize { frame.size }

    func cell(at point: NSPoint) -> (target: BarTarget, frame: NSRect)? {
        guard let button = subviews.compactMap({ $0 as? WidgetButton }).first(where: { $0.frame.contains(point) }) else { return nil }
        return (button.cellInfo.target, button.frame)
    }

    func configure(_ snapshot: Snapshot, settings: AppSettings,
                   enabled: Bool = true, height: CGFloat = 24, display: Int? = nil, icon: (Window) -> NSImage?) {
        if let layout = prepare(snapshot, settings: settings, enabled: enabled, height: height, display: display) {
            apply(layout, icon: icon)
        }
    }

    // Prepare without touching the visible frame while the native slot catches up.
    func prepare(_ snapshot: Snapshot, settings: AppSettings,
                 enabled: Bool = true, height: CGFloat = 24, display: Int? = nil) -> Layout? {
        let height = max(20, height)
        let iconSize = min(CGFloat(settings.iconSize), height - 4)
        let layoutSize = min(CGFloat(settings.layoutIconSize), height - 4)
        let content = WidgetContent(snapshot: snapshot, settings: settings, display: display)
        let limit = max(1, Int(settings.width / 10))
        func bounded<T>(_ items: [T], count: Int? = nil, focused: (T) -> Bool) -> [T] {
            let priorities = Set(items.indices.filter { focused(items[$0]) })
            var indices = Set(items.indices.prefix(max(0, count ?? limit)))
            for index in priorities.sorted() where !indices.contains(index) {
                if let replace = indices.filter({ !priorities.contains($0) }).max() { indices.remove(replace) }
                indices.insert(index)
            }
            return indices.sorted().map { items[$0] }
        }
        func short(_ string: String, count: Int) -> String {
            let clean = string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return clean.count > count ? String(clean.prefix(count)) + "…" : clean
        }
        func layoutSymbol(_ layout: String) -> String {
            layout == "float" ? "macwindow.on.rectangle" : (layout == "stack" ? "square.stack.3d.up" : "rectangle.split.2x2")
        }
        func windowCell(_ window: Window, space: Space?, group: String, active: Bool = false, process: Bool = false) -> Cell {
            let style = process ? (settings.showLayout && window.focused ? settings.layoutStyle : .off) : settings.spaceWindowLayout
            var text = process && window.focused && !settings.processOnlyIcon ? short(window.app, count: 16) : ""
            if style == .text { text += (text.isEmpty ? "" : " ") + window.layout }
            if window.sticky { text += " ⌖" }
            if window.stackIndex != 0 { text += " \(window.stackIndex)" }
            let title = process && window.focused && settings.showWindowTitle && !settings.processOnlyIcon ? short(window.title, count: 20) : ""
            if settings.presentation == .compact && !title.isEmpty { text += " " + title }
            return Cell(text: text, detail: settings.presentation == .compact ? "" : title,
                        symbol: style == .icon ? layoutSymbol(window.layout) : nil, window: window,
                        target: .window(window.id, space?.id), group: group,
                        focus: space == nil ? window.focused : active, visible: space?.visible ?? false, display: space?.display ?? window.display, isProcess: process,
                        tooltip: "\(window.app) — \(window.title) · \(window.state)\(window.stackIndex == 0 ? "" : " · Stack \(window.stackIndex)")",
                        opacity: window.focused ? 1 : CGFloat(settings.unfocusedBrightness) / 100)
        }
        var rows = [Cell]()
        var omitted = 0
        let groups = bounded(content.groups, focused: { $0.space.visible })
        omitted += content.groups.count - groups.count
        var iconBudget = limit
        for group in groups {
            let space = group.space
            let label = short(space.label, count: 12)
            var name: String
            switch settings.spaceName {
            case .number: name = String(space.index)
            case .label: name = label.isEmpty ? String(space.index) : label
            case .numberAndLabel: name = label.isEmpty ? String(space.index) : "\(space.index): \(label)"
            }
            let spaceName = name
            if space.visible && settings.focusStyle == .brackets { name = "[\(name)]" }
            let id = "space-\(space.id)"
            rows.append(Cell(text: name, spaceName: spaceName, target: .space(space.id), group: id, focus: group.active,
                             visible: space.visible, display: space.display, tooltip: "\(space.visible ? "Current Space" : "Space") \(space.index) · \(space.label) · Display \(space.display) · \(space.type). Right-click to manage."))
            let windows = bounded(group.windows, count: iconBudget, focused: \.focused)
            iconBudget = max(0, iconBudget - windows.count)
            omitted += group.windows.count - windows.count
            rows += windows.map { windowCell($0, space: space, group: id, active: group.active) }
        }
        let sticky = bounded(content.sticky, focused: \.focused)
        omitted += content.sticky.count - sticky.count
        rows += sticky.map { windowCell($0, space: nil, group: "sticky") }
        if settings.showCreateSpace, settings.spaceScope != .hidden, let space = content.activeSpace {
            rows.append(Cell(text: "+", target: .create(space.id), group: "create", tooltip: "Create a Space on Display \(space.display)"))
        }
        if settings.windowScope != .hidden {
            if settings.spaceLayout != .off, let space = content.activeSpace {
                rows.append(Cell(text: settings.spaceLayout == .text ? "Space \(space.type)" : "",
                                 symbol: settings.spaceLayout == .icon ? layoutSymbol(space.type) : nil,
                                 target: .menu, group: "layout", tooltip: "Current Space layout: \(space.type)"))
            }
            let process = bounded(content.process, focused: \.focused)
            omitted += content.process.count - process.count
            rows += process.map { windowCell($0, space: nil, group: "process-\($0.id)", process: true) }
            if process.isEmpty {
                rows.append(Cell(text: settings.processOnlyIcon ? "" : "Desktop", symbol: "app.dashed", target: .menu, group: "desktop", tooltip: "No windows in the selected Process scope"))
            }
        }
        let state = RenderState(cells: rows, settings: settings, omitted: omitted, height: height, enabled: enabled)
        guard state != renderedState else { return nil }
        var regularFont = font(settings: settings, height: height), boldFont = font(settings: settings, height: height, bold: true), smallFont = font(settings: settings, height: height, small: true)
        func measure(_ cell: Cell) -> CGFloat {
            let label: CGFloat
            if let name = cell.spaceName {
                let marked = settings.focusStyle == .brackets ? "[\(name)]" : name
                label = max((name as NSString).size(withAttributes: [.font: regularFont]).width,
                            (marked as NSString).size(withAttributes: [.font: boldFont]).width)
            } else {
                label = (cell.text as NSString).size(withAttributes: [.font: cell.focus || cell.currentSpace ? boldFont : regularFont]).width
            }
            let text = max(label,
                           (cell.detail as NSString).size(withAttributes: [.font: smallFont]).width)
            return ceil(text) + (cell.window == nil ? 0 : iconSize) + (cell.symbol == nil ? 0 : layoutSize + 1) + (cell.window == nil ? 6 : 2)
        }
        func overflow() -> Cell {
            var cell = Cell(text: "+\(omitted)", target: .menu, group: "overflow", tooltip: "\(omitted) additional items · Open the full menu")
            cell.width = measure(cell)
            return cell
        }
        var groupGap = CGFloat(settings.groupSpacing), iconGap = CGFloat(settings.spaceIconGap)
        var displayGap = CGFloat(settings.displayGap)
        var showSeparators = settings.showDisplaySeparators
        func displayBoundary(_ a: Cell, _ b: Cell) -> Bool {
            a.group.hasPrefix("space-") && b.group.hasPrefix("space-") && a.display != nil && b.display != nil && a.display != b.display
        }
        func gap(_ a: Cell, _ b: Cell) -> CGFloat {
            if a.group == b.group { return iconGap }
            if showSeparators && displayBoundary(a, b) { return max(7, displayGap) }
            if let first = a.display, let second = b.display, first != second { return displayGap }
            return groupGap
        }
        func total(_ items: [Cell]) -> CGFloat {
            items.reduce(4) { $0 + $1.width } + zip(items, items.dropFirst()).reduce(0) { $0 + gap($1.0, $1.1) }
        }
        for index in rows.indices { rows[index].width = measure(rows[index]) }
        while total(rows + (omitted > 0 ? [overflow()] : [])) > settings.width {
            if let index = rows.lastIndex(where: { $0.window != nil && $0.window?.focused != true }) {
                rows.remove(at: index); omitted += 1
            } else if let index = rows.lastIndex(where: { if case .space = $0.target { return !$0.focus && !$0.visible }; return false }) {
                rows.remove(at: index); omitted += 1
            } else if let index = rows.firstIndex(where: { $0.group == "layout" }) {
                rows.remove(at: index)
            } else if let index = rows.firstIndex(where: { $0.window != nil && (!$0.text.isEmpty || !$0.detail.isEmpty) }) {
                rows[index].text = ""; rows[index].detail = ""; rows[index].width = measure(rows[index])
            } else if let index = rows.firstIndex(where: { cell in
                guard case .space(let id) = cell.target, let space = snapshot.spaces.first(where: { $0.id == id }) else { return false }
                let short = cell.currentSpace && settings.focusStyle == .brackets ? "[\(space.index)]" : String(space.index)
                return cell.text != short
            }), case .space(let id) = rows[index].target, let space = snapshot.spaces.first(where: { $0.id == id }) {
                rows[index].text = rows[index].currentSpace && settings.focusStyle == .brackets ? "[\(space.index)]" : String(space.index)
                rows[index].spaceName = String(space.index)
                rows[index].width = measure(rows[index])
            } else if showSeparators {
                showSeparators = false
            } else if groupGap > 2 || iconGap > 0 || displayGap > 2 {
                groupGap = min(groupGap, 2); iconGap = 0; displayGap = min(displayGap, 2)
            } else if rows.filter({ $0.window?.focused == true }).count > 1,
                      let index = rows.firstIndex(where: { !$0.isProcess && $0.window?.focused == true }) {
                rows.remove(at: index); omitted += 1
            } else if let index = rows.firstIndex(where: { $0.symbol != nil }) {
                rows[index].symbol = nil; rows[index].width = measure(rows[index])
            } else { break }
        }
        if omitted > 0 { rows.append(overflow()) }
        if rows.isEmpty {
            var fallback = Cell(text: "Yabai", target: .menu, group: "menu", tooltip: "Open all Spaces, windows and settings")
            fallback.width = measure(fallback); rows.append(fallback)
        }
        // Keep native-height icons clickable when large text exceeds a very narrow width.
        while total(rows) > settings.width && regularFont.pointSize > 8 {
            let maximum = max(8, regularFont.pointSize - 1)
            regularFont = font(settings: settings, height: height, maximumSize: maximum)
            boldFont = font(settings: settings, height: height, bold: true, maximumSize: maximum)
            smallFont = font(settings: settings, height: height, small: true, maximumSize: maximum)
            for index in rows.indices { rows[index].width = measure(rows[index]) }
        }
        while total(rows) > settings.width {
            if let index = rows.indices.filter({ rows[$0].window == nil && rows[$0].symbol == nil && rows[$0].width > 12 })
                .max(by: { rows[$0].width < rows[$1].width }) {
                rows[index].width -= min(rows[index].width - 12, total(rows) - CGFloat(settings.width))
            } else if let index = rows.firstIndex(where: { if case .create = $0.target { return true }; return false }) {
                rows.remove(at: index)
            } else if let index = rows.lastIndex(where: { if case .space(let id) = $0.target { return id != content.activeSpace?.id }; return false }) {
                rows.remove(at: index); omitted += 1
                if let index = rows.firstIndex(where: { $0.group == "overflow" }) { rows[index] = overflow() }
                else { rows.append(overflow()) }
            } else if groupGap > 0 || displayGap > 0 || iconGap > 0 {
                groupGap = 0; displayGap = 0; iconGap = 0
            } else { break }
        }
        var frames = [NSRect](), backgrounds = [(NSRect, Bool, Bool)](), separators = [CGFloat]()
        var x: CGFloat = 2
        for (index, cell) in rows.enumerated() {
            let frame = NSRect(x: x, y: 1, width: cell.width, height: height - 2)
            frames.append(frame)
            if index > 0, rows[index - 1].group == cell.group, let last = backgrounds.popLast() {
                backgrounds.append((last.0.union(frame), last.1, last.2))
            } else { backgrounds.append((frame, cell.focus, cell.visible)) }
            x += cell.width
            if index + 1 < rows.count {
                let next = rows[index + 1], spacing = gap(cell, next)
                if showSeparators && displayBoundary(cell, next) { separators.append(x + spacing / 2) }
                x += spacing
            }
        }
        return Layout(state: state, cells: rows, frames: frames, backgrounds: backgrounds, separators: separators,
                      size: NSSize(width: x + 2, height: height), regularFont: regularFont, boldFont: boldFont, smallFont: smallFont)
    }

    func apply(_ layout: Layout, icon: (Window) -> NSImage?) {
        let settings = layout.state.settings, height = layout.state.height
        let appearanceChanged = self.settings != settings
        let monochromeChanged = self.settings.monochrome != settings.monochrome
        let oldBackgrounds = backgrounds, oldSeparators = displaySeparators
        let buttons = subviews.compactMap { $0 as? WidgetButton }
        let reuse = buttons.count == layout.cells.count && zip(buttons, layout.cells).allSatisfy {
            $0.cellInfo.group == $1.group && $0.cellInfo.target == $1.target
        }
        if !reuse { subviews.forEach { $0.removeFromSuperview() } }
        self.settings = settings
        renderedState = layout.state
        cells = layout.cells
        backgrounds = layout.backgrounds
        displaySeparators = layout.separators
        for (index, cell) in cells.enumerated() {
            let button = reuse ? buttons[index] : WidgetButton(frame: layout.frames[index])
            let previous = button.cellInfo
            var textFont = cell.focus || cell.currentSpace ? layout.boldFont : layout.regularFont
            var detailFont = layout.smallFont
            if !cell.detail.isEmpty {
                let totalHeight = textFont.ascender - textFont.descender + textFont.leading
                    + detailFont.ascender - detailFont.descender + detailFont.leading
                let scale = min(1, (height - 4) / totalHeight)
                textFont = NSFontManager.shared.convert(textFont, toSize: textFont.pointSize * scale)
                detailFont = NSFontManager.shared.convert(detailFont, toSize: detailFont.pointSize * scale)
            }
            let enabled = layout.state.enabled || cell.target == .menu
            let redraw = !reuse || appearanceChanged || previous?.hasSameDrawing(as: cell) != true
                || button.frame != layout.frames[index] || button.textFont != textFont || button.detailFont != detailFont
                || button.isEnabled != enabled
            button.cellInfo = cell
            if redraw {
                if button.frame != layout.frames[index] { button.frame = layout.frames[index] }
                button.textFont = textFont
                button.detailFont = detailFont
                button.iconSize = min(CGFloat(settings.iconSize), height - 4)
                button.layoutSize = min(CGFloat(settings.layoutIconSize), height - 4)
                if !reuse || monochromeChanged || previous?.window?.pid != cell.window?.pid {
                    button.appIcon = cell.window.flatMap(icon)
                }
                if !reuse || previous?.symbol != cell.symbol {
                    button.stateIcon = cell.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: cell.tooltip) }
                }
                button.underline = cell.currentSpace && settings.focusStyle == .underline
                button.textColor = settings.contentColor
                button.symbolColor = settings.contentColor
                if case .space = cell.target { button.textColor = settings.spaceNameColor(focused: cell.focus, visible: cell.visible) }
                if button.isEnabled != enabled { button.isEnabled = enabled }
                button.needsDisplay = true
            }
            if !reuse {
                button.owner = self
                button.tag = index
                button.target = self
                button.action = #selector(selected(_:))
                button.isBordered = false
            }
            let tooltip = cell.tooltip + " · Right-click for menu and settings"
            if button.toolTip != tooltip {
                button.toolTip = tooltip
                button.setAccessibilityLabel(tooltip)
            }
            if !reuse { addSubview(button) }
        }
        let resized = frame.size != layout.size
        if resized {
            setFrameSize(layout.size)
            invalidateIntrinsicContentSize()
        }
        if !reuse || appearanceChanged || resized || oldSeparators != displaySeparators || oldBackgrounds.count != backgrounds.count {
            needsDisplay = true
        } else {
            for (old, new) in zip(oldBackgrounds, backgrounds) where old.0 != new.0 || old.1 != new.1 || old.2 != new.2 {
                setNeedsDisplay(old.0.union(new.0))
            }
        }
    }

    private func font(settings: AppSettings, height: CGFloat, bold: Bool = false, small: Bool = false, maximumSize: CGFloat = .greatestFiniteMagnitude) -> NSFont {
        let size = min(CGFloat(settings.fontSize) * (small ? 0.85 : 1), height - 6, maximumSize)
        var base = NSFont(name: settings.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let lineHeight = base.ascender - base.descender + base.leading
        if lineHeight > height - 4 { base = NSFontManager.shared.convert(base, toSize: size * (height - 4) / lineHeight) }
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (rect, focused, visible) in backgrounds {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(settings.cornerRadius), yRadius: CGFloat(settings.cornerRadius))
            settings.spaceColor(focused: focused, visible: visible).withAlphaComponent(settings.backgroundAlpha(focused: focused, visible: visible)).setFill()
            path.fill()
            if settings.showBorder && settings.backgroundAlpha(focused: focused, visible: visible) > 0 { NSColor.labelColor.withAlphaComponent(0.15).setStroke(); path.lineWidth = 1; path.stroke() }
        }
        settings.contentColor.withAlphaComponent(0.45).setStroke()
        for x in displaySeparators {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: bounds.height * 0.25))
            line.line(to: NSPoint(x: x, y: bounds.height * 0.75))
            line.lineWidth = 0.5
            line.stroke()
        }
    }
    @objc private func selected(_ sender: NSButton) {
        // A refresh can replace the visible list while AppKit is still tracking this button.
        if let target = (sender as? WidgetButton)?.cellInfo.target { onSelect?(target) }
    }
}

@MainActor
private final class WidgetButton: NSButton {
    weak var owner: WidgetBarView?
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    var cellInfo: WidgetBarView.Cell!
    var appIcon: NSImage?
    var stateIcon: NSImage?
    var textFont = NSFont.systemFont(ofSize: 11)
    var detailFont = NSFont.systemFont(ofSize: 9)
    var textColor = NSColor.labelColor
    var symbolColor = NSColor.labelColor
    var iconSize: CGFloat = 16
    var layoutSize: CGFloat = 16
    var underline = false
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let target = cellInfo?.target else { return super.menu(for: event) }
        return owner?.contextMenu?(target) ?? super.menu(for: event)
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func draw(_ dirtyRect: NSRect) {
        guard let cell = cellInfo else { return }
        if isHighlighted { NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
        let opacity = isEnabled ? cell.opacity : 0.5
        var x: CGFloat = cell.window == nil ? 3 : 1
        if cell.window != nil {
            if let appIcon { drawIcon(appIcon, in: NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize), opacity: opacity) }
            x += iconSize
        }
        if let stateIcon {
            let symbol = stateIcon.withSymbolConfiguration(.init(pointSize: layoutSize, weight: .medium)) ?? stateIcon
            drawIcon(symbol, in: NSRect(x: x, y: (bounds.height - layoutSize) / 2, width: layoutSize, height: layoutSize), opacity: opacity)
            x += layoutSize + 1
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color = (isEnabled ? textColor : .disabledControlTextColor).withAlphaComponent(opacity)
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont, .paragraphStyle: paragraph, .foregroundColor: color]
        let lineHeight = textFont.ascender - textFont.descender + textFont.leading
        let y = cell.detail.isEmpty ? (bounds.height - lineHeight) / 2 : bounds.height - lineHeight
        (cell.text as NSString).draw(in: NSRect(x: x, y: y, width: max(0, bounds.width - x - 1), height: lineHeight), withAttributes: attributes)
        if underline {
            let width = min((cell.text as NSString).size(withAttributes: [.font: textFont]).width, max(0, bounds.width - x - 1))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: max(1, floor(y - 2)), width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        }
        if !cell.detail.isEmpty {
            let detailHeight = detailFont.ascender - detailFont.descender + detailFont.leading
            (cell.detail as NSString).draw(in: NSRect(x: x, y: 0, width: max(0, bounds.width - x - 1), height: detailHeight),
                withAttributes: [.font: detailFont, .paragraphStyle: paragraph, .foregroundColor: textColor.withAlphaComponent(opacity * 0.75)])
        }
    }

    private func drawIcon(_ image: NSImage, in rect: NSRect, opacity: CGFloat) {
        let rendered: NSImage
        if image.isTemplate {
            rendered = NSImage(size: rect.size, flipped: false) { bounds in
                image.draw(in: bounds)
                self.symbolColor.setFill()
                bounds.fill(using: .sourceAtop)
                return true
            }
        } else { rendered = image }
        rendered.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
    }
}
