// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：为菜单栏提供可覆盖的主题颜色。
// 代码逻辑：1. 选择预设；2. 按显示角色返回官方色表中的 RGB 值。
// 必需输入：主题与颜色角色。预期输出：六位十六进制颜色，System 使用系统动态色。
import AppKit

// Color values: https://github.com/catppuccin/palette and https://github.com/folke/tokyonight.nvim.
enum ColorPreset: String, CaseIterable {
    case system, catppuccinMocha, catppuccinLatte, tokyoNight, tokyoStorm
    var title: String {
        switch self {
        case .system: return "System"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .tokyoNight: return "Tokyo Night"
        case .tokyoStorm: return "Tokyo Night Storm"
        }
    }
    // focused / visible / inactive backgrounds, then the corresponding names, then content.
    var colors: [String] {
        switch self {
        case .system: return Array(repeating: "", count: 7)
        case .catppuccinMocha: return ["#45475A", "#313244", "#1E1E2E", "#89B4FA", "#CDD6F4", "#A6ADC8", "#CDD6F4"]
        case .catppuccinLatte: return ["#BCC0CC", "#CCD0DA", "#EFF1F5", "#4C4F69", "#4C4F69", "#4C4F69", "#4C4F69"]
        case .tokyoNight: return ["#394B70", "#292E42", "#1A1B26", "#7AA2F7", "#C0CAF5", "#A9B1D6", "#C0CAF5"]
        case .tokyoStorm: return ["#394B70", "#292E42", "#24283B", "#7AA2F7", "#C0CAF5", "#A9B1D6", "#C0CAF5"]
        }
    }

    var appearance: NSAppearance? {
        self == .system ? nil : NSAppearance(named: self == .catppuccinLatte ? .aqua : .darkAqua)
    }

    var barBackground: NSColor {
        guard self != .system, let rgb = UInt32(colors[2].dropFirst(), radix: 16) else { return .windowBackgroundColor }
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
}
