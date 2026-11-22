// 生成 DMG 窗口背景：左边放 App，右边放「应用程序」，中间一个箭头
// 用法：swift scripts/make_dmg_bg.swift out.png   （输出 1320×800，供 660×400 窗口的 @2x）
import AppKit

let W: CGFloat = 660, H: CGFloat = 400, scale: CGFloat = 2
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_bg.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 背景：深色渐变 + 中心淡绿辉光
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.11, green: 0.13, blue: 0.13, alpha: 1).cgColor,
    NSColor(red: 0.05, green: 0.06, blue: 0.06, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.2, green: 0.95, blue: 0.45, alpha: 0.12).cgColor,
    NSColor(red: 0.2, green: 0.95, blue: 0.45, alpha: 0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: 210), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: 210), endRadius: 300, options: [])

// 箭头（图标中心位于 y=190（Finder 坐标，自上而下），即 CG 坐标 y=210）
let green = NSColor(red: 0.3, green: 0.95, blue: 0.5, alpha: 0.9)
ctx.setStrokeColor(green.cgColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineDash(phase: 0, lengths: [2, 12])
ctx.move(to: CGPoint(x: 265, y: 210)); ctx.addLine(to: CGPoint(x: 385, y: 210)); ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.move(to: CGPoint(x: 372, y: 224)); ctx.addLine(to: CGPoint(x: 392, y: 210)); ctx.addLine(to: CGPoint(x: 372, y: 196))
ctx.strokePath()

// 文案
func text(_ s: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: color, .paragraphStyle: p]
    NSAttributedString(string: s, attributes: a).draw(in: CGRect(x: 0, y: y, width: W, height: size + 8))
}
text("拖到「应用程序」完成安装", y: 74, size: 17, color: .white.withAlphaComponent(0.9), weight: .semibold)
text("Drag ArgusLid to Applications to install", y: 50, size: 12, color: .white.withAlphaComponent(0.5), weight: .regular)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
