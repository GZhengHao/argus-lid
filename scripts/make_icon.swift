// 生成 App 图标：深色玻璃方块 + 绿色发光的眼睛
// 用法：swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS 图标网格：824×824 圆角方块，居中
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// 底色渐变
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.10, green: 0.13, blue: 0.12, alpha: 1).cgColor,
    NSColor(red: 0.02, green: 0.03, blue: 0.03, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])

// 中心绿色辉光
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.20, green: 0.95, blue: 0.45, alpha: 0.35).cgColor,
    NSColor(red: 0.20, green: 0.95, blue: 0.45, alpha: 0.0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: 380, options: [])

// 顶部玻璃高光
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: size / 2), options: [])
ctx.restoreGState()

// 描边
ctx.addPath(path)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

// 眼睛符号
let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(.init(paletteColors: [NSColor(red: 0.25, green: 0.98, blue: 0.50, alpha: 1)]))
if let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = eye.size
    let r = CGRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor(red: 0.2, green: 1, blue: 0.45, alpha: 0.9).cgColor)
    eye.draw(in: r)
    ctx.restoreGState()
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
