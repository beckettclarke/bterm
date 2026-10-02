// Renders the bterm app icon (1024×1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body with soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let bg = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor,
    NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Faint grid, like a dashboard canvas.
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.035).cgColor)
ctx.setLineWidth(2)
var g: CGFloat = 100
while g < 924 {
    ctx.move(to: CGPoint(x: g, y: 100)); ctx.addLine(to: CGPoint(x: g, y: 924))
    ctx.move(to: CGPoint(x: 100, y: g)); ctx.addLine(to: CGPoint(x: 924, y: g))
    g += 64
}
ctx.strokePath()

// Top glow.
let glow = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.24, green: 0.81, blue: 0.56, alpha: 0.28).cgColor,
    NSColor(srgbRed: 0.24, green: 0.81, blue: 0.56, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 760), endRadius: 520, options: [])
ctx.restoreGState()

// Hairline border.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

// Prompt: chevron + block cursor.
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(58)
ctx.move(to: CGPoint(x: 290, y: 650))
ctx.addLine(to: CGPoint(x: 450, y: 512))
ctx.addLine(to: CGPoint(x: 290, y: 374))
ctx.strokePath()

let cursor = CGRect(x: 520, y: 352, width: 220, height: 56)
ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 14, cornerHeight: 14, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 0.24, green: 0.81, blue: 0.56, alpha: 1).cgColor)
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
