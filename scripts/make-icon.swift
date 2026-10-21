// 代码目的：将选定的窗格图案生成为 Yabai Menu 的应用图标，无第三方图像依赖。
//
// 代码逻辑：
// 1. 读取窗格原图，裁去预览留白并用圆角路径保留透明外缘。
// 2. 输出 macOS iconset 所需的标准及 Retina 尺寸。
// 3. 验证 PNG 编码成功，供 iconutil 打包为 ICNS。
//
// 必需输入：
// - assets/AppIcon.png：选定的 B「窗格」原图。
// - 第一个参数：iconset 输出目录。
//
// 预期输出：
// - 十个尺寸的 PNG 图标文件。
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift scripts/make-icon.swift .build/AppIcon.iconset") }
guard let source = NSImage(contentsOfFile: "assets/AppIcon.png"),
      source.size.width > 0, source.size.width == source.size.height else { fatalError("Missing or invalid assets/AppIcon.png") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    background.addClip()
    // 原图中央 75% 是图标本体；外圈仅用于方案预览。
    let crop = NSRect(x: source.size.width / 8, y: source.size.height / 8,
                      width: source.size.width * 0.75, height: source.size.height * 0.75)
    source.draw(in: background.bounds, from: crop, operation: .copy, fraction: 1)
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
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { fatalError("PNG encoding failed") }
        try data.write(to: output.appendingPathComponent(name))
    }
}
