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
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.14, blue: 0.25, alpha: 1),
               ending: NSColor(srgbRed: 0.19, green: 0.28, blue: 0.44, alpha: 1))!.draw(in: background, angle: 90)
    for i in 0..<3 {
        let focused = i == 1
        let rect = NSRect(x: CGFloat(178 + i * 234), y: focused ? 296 : 336, width: 200, height: focused ? 432 : 352)
        let card = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
        (focused ? NSColor(srgbRed: 0.31, green: 0.87, blue: 0.79, alpha: 1) : NSColor.white.withAlphaComponent(0.28)).setFill()
        card.fill()
        (focused ? NSColor(srgbRed: 0.08, green: 0.19, blue: 0.26, alpha: 1) : NSColor.white.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 28, y: rect.maxY - 60, width: 144, height: 12), xRadius: 6, yRadius: 6).fill()
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
