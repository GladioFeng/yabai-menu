// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：按 a-bar 的 Spaces / Process 规则整理同一份 yabai 快照。
// 代码逻辑：1. 编译筛选条件；2. 按空间分组、去重和排序；3. 输出供菜单栏使用的数据。
// 必需输入：Snapshot、AppSettings。预期输出：空间图标、sticky 列表和 Process 窗口。
import Foundation

struct WidgetContent {
    struct Group { let space: Space; let windows: [Window]; let active: Bool }
    let activeSpace: Space?
    let groups: [Group]
    let sticky: [Window]
    let process: [Window]

    init(snapshot: Snapshot, settings: AppSettings, display: Int? = nil) {
        activeSpace = display.flatMap { index in snapshot.spaces.first { $0.display == index && $0.visible } } ?? (display == nil ? snapshot.focusedSpace : nil)
        func patterns(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let names = patterns(settings.exclusions), titles = patterns(settings.titleExclusions)
        let nameRegex = settings.exclusionsAsRegex ? names.compactMap { try? NSRegularExpression(pattern: $0) } : []
        let titleRegex = settings.exclusionsAsRegex ? titles.compactMap { try? NSRegularExpression(pattern: $0) } : []
        func excluded(_ value: String, title: Bool = false) -> Bool {
            if settings.exclusionsAsRegex {
                return (title ? titleRegex : nameRegex).contains {
                    $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                }
            }
            return (title ? titles : names).contains { title ? value.contains($0) : value == $0 }
        }
        func deduplicate(_ windows: [Window]) -> [Window] {
            var seen = Set<String>()
            // Prefer the focused window so a collapsed app still reports its current layout.
            let focusedApps = Set(windows.filter(\.focused).map(\.app))
            return windows.filter { ($0.focused || !focusedApps.contains($0.app)) && seen.insert($0.app).inserted }
        }
        let localDisplay = display ?? snapshot.focusedSpace?.display
        func onSelectedDisplay(_ window: Window) -> Bool {
            let owner = window.display ?? snapshot.spaces.first(where: { $0.index == window.space })?.display
            return settings.spaceScope != .focusedDisplay || localDisplay == nil || owner == localDisplay
        }
        let accepted = snapshot.windows.filter { ($0.subrole == nil || ($0.subrole != "" && $0.subrole != "AXDialog")) && onSelectedDisplay($0) }
        let visible = accepted.filter { !$0.hidden && !$0.minimized }
        let grouped = Dictionary(grouping: visible, by: \.space)
        groups = snapshot.spaces.compactMap { space in
            guard settings.spaceScope != .hidden,
                  settings.spaceScope != .focusedDisplay || localDisplay == nil || space.display == localDisplay,
                  !excluded(space.name) else { return nil }
            let all = grouped[space.index] ?? []
            // Empty-space visibility follows real occupancy, before icon exclusions and sticky separation.
            guard !settings.hideEmptySpaces || space.focused || space.visible || !all.isEmpty else { return nil }
            var windows = all.filter { (!settings.separateSticky || !$0.sticky) && !excluded($0.app) && !excluded($0.title, title: true) }
            if settings.hideDuplicateApps { windows = deduplicate(windows) }
            windows.sort { ($0.app, $0.id) < ($1.app, $1.id) }
            // Each host accents its own current Space; other displays retain the separate visible color.
            let active = space.visible && (display.map { $0 == space.display } ?? space.focused)
            return Group(space: space, windows: settings.showSpaceIcons ? windows : [], active: active)
        }
        // a-bar keeps this independent group outside Space/app exclusion rules.
        sticky = settings.separateSticky && settings.spaceScope != .hidden ? deduplicate(visible.filter(\.sticky)) : []
        let windows: [Window]
        switch settings.windowScope {
        case .all: windows = accepted
        case .currentSpace:
            if let space = activeSpace {
                windows = accepted.filter { window in
                    let owner = window.display ?? snapshot.spaces.first(where: { $0.index == window.space })?.display
                    return window.space == space.index || (window.focused && window.sticky && (owner == nil || owner == space.display))
                }
            } else { windows = [] }
        case .focused: windows = accepted.filter(\.focused)
        case .hidden: windows = []
        }
        process = windows.enumerated().sorted {
            let a = $0.element, b = $1.element
            if a.stackIndex != b.stackIndex { return a.stackIndex < b.stackIndex }
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}
