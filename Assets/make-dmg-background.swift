// 生成安装镜像窗口的背景：左边是结界，右边是“应用程序”，中间一道带黄色方点的箭头（取自图标）。
// 用法：swift Assets/make-dmg-background.swift <输出目录>，得到 dmg-background.png 和 @2x，供 make-dmg.sh 合成 tiff。
// 坐标与 make-dmg.sh 里的窗口大小、图标位置一一对应，改一处要改另一处。
import AppKit

let size = NSSize(width: 640, height: 400)
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 180  // 图标中心，从左上角算
let blue = NSColor(srgbRed: 0x23 / 255, green: 0x59 / 255, blue: 1, alpha: 1)
let yellow = NSColor(srgbRed: 1, green: 0xD9 / 255, blue: 0, alpha: 1)

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let y = size.height - iconY  // 画图坐标从左下角算

    NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // 箭头：细线，中间一个黄色方点，末端一个折角
    let from = appX + 78, to = appsX - 78
    let line = NSBezierPath()
    line.move(to: NSPoint(x: from, y: y))
    line.line(to: NSPoint(x: to, y: y))
    line.lineWidth = 1.5
    blue.withAlphaComponent(0.55).setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to - 7, y: y + 6))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 7, y: y - 6))
    head.lineWidth = 1.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    blue.setStroke()
    head.stroke()
    let mid = (from + to) / 2
    yellow.setFill()
    NSRect(x: mid - 4, y: y - 4, width: 8, height: 8).fill()

    func text(_ s: String, top: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: 400 - top - size * 1.6, width: 640, height: size * 1.6))
    }
    text("将“结界”拖到“应用程序”文件夹即可安装", top: 300, size: 14, color: NSColor(white: 0.23, alpha: 1), weight: .medium)
    text("Drag Kekkai to Applications to install", top: 324, size: 11.5, color: NSColor(white: 0.55, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: "\(out)/dmg-background.png")
render(scale: 2, to: "\(out)/dmg-background@2x.png")
