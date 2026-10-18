// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Display: Decodable, Equatable {
    let id: UInt32
    let index: Int
    let uuid: String?
    let focused: Bool?
    enum CodingKeys: String, CodingKey { case id, index, uuid; case focused = "has-focus" }
}

struct Space: Decodable, Equatable {
    let id: Int
    let index: Int
    let label: String
    let display: Int
    let type: String
    let focused: Bool
    let visible: Bool
    let windows: [Int]?
    var name: String { label.isEmpty ? String(index) : label }
    enum CodingKeys: String, CodingKey {
        case id, index, label, display, type, windows
        case focused = "has-focus", visible = "is-visible"
    }
}

struct Window: Decodable, Equatable {
    let id: Int
    let pid: Int32
    let app: String
    private(set) var title: String
    let subrole: String?
    let display: Int?
    let space: Int
    private(set) var focused: Bool
    let visible: Bool?
    let floating: Bool
    let sticky: Bool
    let hidden: Bool
    let minimized: Bool
    let stackIndex: Int
    let frame: Frame
    struct Frame: Decodable, Equatable { let x: Double }
    var layout: String { floating ? "float" : (stackIndex > 0 ? "stack" : "bsp") }
    var state: String { layout + (sticky ? " · sticky" : "") }
    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, subrole, display, space, frame
        case focused = "has-focus", visible = "is-visible", floating = "is-floating", sticky = "is-sticky"
        case hidden = "is-hidden", minimized = "is-minimized", stackIndex = "stack-index"
    }
    func replacingTitle(_ title: String) -> Window {
        var window = self; window.title = title; return window
    }
    fileprivate mutating func setFocus(_ focused: Bool) { self.focused = focused }
}

struct Snapshot: Equatable {
    let displays: [Display]
    let spaces: [Space]
    var windows: [Window]

    init(spaces: Data, windows: Data, displays: Data? = nil, excludingPID: Int32? = nil) throws {
        let d = try displays.map { try Self.decode([Display].self, from: $0) } ?? []
        let s = try Self.decode([Space].self, from: spaces)
        let w = try Self.decode([Window].self, from: windows)
        try self.init(spaces: s, windows: w, displays: d)
        self.windows = w.filter { $0.pid != excludingPID }
    }

    init(spaces s: [Space], windows w: [Window], displays d: [Display]) throws {
        guard Set(d.map(\.id)).count == d.count, Set(d.map(\.index)).count == d.count,
              d.allSatisfy({ $0.id > 0 && $0.index > 0 }),
              Set(s.map(\.id)).count == s.count, Set(s.map(\.index)).count == s.count,
              Set(w.map(\.id)).count == w.count,
              s.allSatisfy({ $0.id > 0 && $0.index > 0 && $0.display > 0 }),
              w.allSatisfy({ $0.id > 0 && $0.frame.x.isFinite }) else {
            throw MenuError.message("yabai 返回了重复 ID 或无效坐标；保留上次状态。")
        }
        self.displays = d.sorted { $0.index < $1.index }
        self.spaces = s.sorted { $0.index < $1.index }
        self.windows = w
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(type, from: data) { return value }
        return try decoder.decode(type, from: Data(YabaiJSONSanitizer.sanitize(String(decoding: data, as: UTF8.self)).utf8))
    }

    var focusedSpace: Space? { spaces.first { $0.focused } }
    var focusedWindow: Window? { windows.first { $0.focused && !$0.hidden && !$0.minimized } }

    // The same identity and membership checks as a-bar's YabaiState.updatingFocus.
    func updatingFocus(_ window: Window) -> Snapshot? {
        guard window.focused, !window.hidden, !window.minimized,
              let current = focusedSpace, current.display == window.display,
              displays.contains(where: { $0.index == window.display && $0.focused == true }),
              window.sticky || window.space == current.index,
              let index = windows.firstIndex(where: { $0.id == window.id }),
              windows.filter({ $0.id == window.id }).count == 1 else { return nil }
        let old = windows[index]
        guard old.pid == window.pid, old.app == window.app, old.space == window.space,
              old.display == window.display, old.sticky == window.sticky,
              old.hidden == window.hidden, old.minimized == window.minimized,
              old.visible == window.visible, old.subrole == window.subrole,
              spaces.contains(where: { $0.index == window.space && $0.windows?.contains(window.id) == true }) else { return nil }
        var next = self
        for i in next.windows.indices { next.windows[i].setFocus(false) }
        next.windows[index] = window
        return next
    }

    var currentWindows: [Window] {
        guard let space = focusedSpace else { return [] }
        return windows.enumerated().filter {
            !$0.element.hidden && !$0.element.minimized &&
            ($0.element.space == space.index || ($0.element.focused && $0.element.sticky))
        }.sorted {
            let a = $0.element, b = $1.element
            if a.stackIndex != b.stackIndex { return a.stackIndex < b.stackIndex }
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            return $0.offset < $1.offset
        }.map(\.element)
    }

}

enum MenuError: LocalizedError {
    case message(String)
    case alreadyFocusedSpace
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .alreadyFocusedSpace: return "The Space is already focused."
        }
    }
}
