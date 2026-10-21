// 代码目的：生成 Yabai Menu 的应用图标，无第三方图像依赖。
//
// 代码逻辑：
// 1. 用可编辑的矢量路径绘制三个工作区，其中一个处于聚焦状态。
// 2. 输出 macOS iconset 所需的标准及 Retina 尺寸。
// 3. 验证 PNG 编码成功，供 iconutil 打包为 ICNS。
//
// 必需输入：
// - 第一个参数：iconset 输出目录。
//
// 预期输出：
// - 十个尺寸的 PNG 图标文件。
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift scripts/make-icon.swift .build/AppIcon.iconset") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(srgbRed: 0.86, green: 0.94, blue: 0.90, alpha: 1),
               ending: NSColor(srgbRed: 0.98, green: 0.99, blue: 0.97, alpha: 1))!.draw(in: background, angle: 90)
    NSColor(srgbRed: 0.76, green: 0.87, blue: 0.81, alpha: 0.8).setStroke()
    background.lineWidth = 4
    background.stroke()
    for i in 0..<3 {
        let focused = i == 1
        let rect = NSRect(x: CGFloat(178 + i * 234), y: focused ? 296 : 336, width: 200, height: focused ? 432 : 352)
        let card = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
        let bottom = focused ? NSColor(srgbRed: 0.34, green: 0.76, blue: 0.62, alpha: 1)
                             : NSColor(srgbRed: 0.66, green: 0.82, blue: 0.89, alpha: 1)
        let top = focused ? NSColor(srgbRed: 0.66, green: 0.90, blue: 0.79, alpha: 1)
                          : NSColor(srgbRed: 0.82, green: 0.92, blue: 0.96, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.22, green: 0.47, blue: 0.39, alpha: 0.13)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 18
        shadow.set()
        NSGradient(starting: bottom, ending: top)!.draw(in: card, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        card.lineWidth = 3
        card.stroke()
        (focused ? NSColor(srgbRed: 0.13, green: 0.43, blue: 0.34, alpha: 1) : NSColor(srgbRed: 0.31, green: 0.53, blue: 0.64, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 28, y: rect.maxY - 62, width: 144, height: 14), xRadius: 7, yRadius: 7).fill()
    }
    return true
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { fatalError("PNG encoding failed") }
        try data.write(to: output.appendingPathComponent(name))
    }
}
