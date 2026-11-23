// 앱 아이콘(1024px PNG)을 그린다: swift scripts/make-icon.swift <출력.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 아이콘 격자: 1024 캔버스 안 824 크기 둥근 사각형
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.70, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.95, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.33, green: 0.20, blue: 0.80, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// 위쪽 하이라이트
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
ctx.restoreGState()

// 도넛 차트 (디스크 분석)
let center = CGPoint(x: size / 2, y: size / 2 - 10)
let r: CGFloat = 250
let segments: [(CGFloat, NSColor)] = [
    (0.42, NSColor.white),
    (0.23, NSColor.white.withAlphaComponent(0.72)),
    (0.15, NSColor.white.withAlphaComponent(0.48)),
    (0.20, NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 1)),
]
var start = CGFloat.pi / 2
for (frac, color) in segments {
    let end = start - frac * 2 * .pi
    let p = CGMutablePath()
    p.addArc(center: center, radius: r, startAngle: start - 0.025, endAngle: end + 0.025, clockwise: true)
    ctx.addPath(p)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(118)
    ctx.setLineCap(.butt)
    ctx.strokePath()
    start = end
}

// 반짝임 (정리)
func sparkle(_ c: CGPoint, _ s: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + s))
    p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: c)
    ctx.addPath(p)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
}
sparkle(CGPoint(x: center.x, y: center.y), 92)
sparkle(CGPoint(x: center.x + 330, y: center.y + 300), 54)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
