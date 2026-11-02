// 生成结界图标：天地之间一扇门，门里一盏灯
import AppKit
let size = 1024.0, u = size / 8
func hex(_ h: Int) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: NSColor) { c.setFill(); NSBezierPath(rect: NSRect(x: x * u, y: y * u, width: w * u, height: h * u)).fill() }
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = size * 0.098
    let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), xRadius: size * 0.185, yRadius: size * 0.185)
    shape.addClip()
    block(0, 0, 8, 8, hex(0x1B3BFF))        // 天
    block(0, 0, 8, 3.2, hex(0x111111))      // 地
    block(2.6, 2.2, 2.8, 3.6, .white)       // 门
    block(3.5, 3.5, 1, 1, hex(0xFFD400))    // 灯
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size)); NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
