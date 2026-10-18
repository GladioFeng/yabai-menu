// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：为浮动状态条提供可读的圆角玻璃或实色背景。
//
// 代码逻辑：
// 1. 复用 a-bar 的原生 menu 材质、非激活状态和圆角蒙版策略。
// 2. 独立叠加主题底色与细边框，保持文字不透明。
// 3. 仅在尺寸或圆角变化时重建蒙版，降低透明度开启时使用实色。
//
// 必需输入：外观设置与视图尺寸。
// 预期输出：不拦截鼠标事件、不增加定时器或 yabai 查询的背景。
import AppKit

@MainActor
final class BarBackdropView: NSView {
    let material = NSVisualEffectView()
    private let tint = NSView()
    private var settings: AppSettings?
    private var maskSize = NSSize.zero
    private var maskRadius: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
        tint.wantsLayer = true
        addSubview(tint)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAccessibility), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ settings: AppSettings) {
        guard self.settings != settings else { return }
        self.settings = settings
        appearance = settings.colorPreset.appearance
        refreshStyle()
        needsLayout = true
        window?.invalidateShadow()
    }

    @objc private func refreshAccessibility() { refreshStyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshStyle() }

    private func refreshStyle() {
        guard let settings else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        isHidden = settings.barBackdrop == .none
        material.isHidden = settings.barBackdrop != .glass || reduceTransparency
        let opacity = settings.barBackdrop == .solid || reduceTransparency ? 1 : CGFloat(settings.barBackgroundOpacity) / 100
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = settings.colorPreset.barBackground.withAlphaComponent(opacity).cgColor
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            tint.layer?.borderColor = (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.16 : 0.1).cgColor
        }
        tint.layer?.borderWidth = settings.barBorder ? 0.5 : 0
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        let radius = min(CGFloat(settings?.barCornerRadius ?? 0), min(bounds.width, bounds.height) / 2)
        tint.layer?.cornerRadius = radius
        guard maskSize != bounds.size || maskRadius != radius else { return }
        maskSize = bounds.size
        maskRadius = radius
        window?.invalidateShadow()
        guard radius > 0, !bounds.isEmpty else { material.maskImage = nil; return }
        let size = bounds.size
        material.maskImage = NSImage(size: size, flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}
