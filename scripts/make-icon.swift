// Renders Resources/AppIcon.iconset: the menu-bar glyph (IconRenderer.swift) on a macOS squircle.
// Usage: swift macos/scripts/make-icon.swift [output-dir]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

func hex(_ v: UInt32) -> RGBA {
    (CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, 1)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func cg(_ c: RGBA) -> CGColor {
    CGColor(colorSpace: srgb, components: [c.r, c.g, c.b, c.a])!
}

func pill(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

let slateTop = hex(0x1f2a26)
let slateBottom = hex(0x0f1512)
let green: RGBA = (0.29, 0.84, 0.44, 1) // LevelColors.green in the dark appearance
let track: RGBA = (1, 1, 1, 0.18)

// Vertical gradient painted one pixel row at a time: CGGradient dithers, which makes every
// background row unique and roughly triples the PNG size.
func verticalGradient(_ ctx: CGContext, top: RGBA, bottom: RGBA, from yTop: CGFloat, to yBottom: CGFloat) {
    let width = CGFloat(ctx.width)
    for row in Int(yBottom.rounded(.down))..<Int(yTop.rounded(.up)) {
        let t = min(1, max(0, (yTop - (CGFloat(row) + 0.5)) / (yTop - yBottom)))
        let c: RGBA = (top.r + (bottom.r - top.r) * t, top.g + (bottom.g - top.g) * t,
                       top.b + (bottom.b - top.b) * t, top.a + (bottom.a - top.a) * t)
        ctx.setFillColor(cg(c))
        ctx.fill(CGRect(x: 0, y: CGFloat(row), width: width, height: 1))
    }
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)

    // macOS icon grid: the shape sits inside a 10% transparent margin, Big Sur corner radius.
    let s = CGFloat(px)
    let side = s * 0.8
    let shape = CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    let radius = side * 0.2237
    let squircle = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    verticalGradient(ctx, top: slateTop, bottom: slateBottom, from: shape.maxY, to: shape.minY)
    verticalGradient(ctx, top: (1, 1, 1, 0.05), bottom: (1, 1, 1, 0), from: shape.maxY, to: shape.midY)
    // Inner edge highlight: stroke centred on the edge; the outer half falls outside the clip.
    ctx.addPath(squircle)
    ctx.setLineWidth(max(side * 0.012, 1))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    verticalGradient(ctx, top: (1, 1, 1, 0.22), bottom: (1, 1, 1, 0.03), from: shape.maxY, to: shape.minY)
    ctx.restoreGState()

    // Same proportions as the 20x16 menu-bar glyph: 16x3 bars, 3 apart.
    let barW = side * 0.6
    let barH = barW * 3 / 16
    let gap = barH
    let x = shape.midX - barW / 2
    func bar(y: CGFloat, fill: CGFloat) {
        ctx.setFillColor(cg(track))
        ctx.addPath(pill(CGRect(x: x, y: y, width: barW, height: barH)))
        ctx.fillPath()
        ctx.setFillColor(cg(green))
        ctx.addPath(pill(CGRect(x: x, y: y, width: barW * fill, height: barH)))
        ctx.fillPath()
    }
    bar(y: shape.midY + gap / 2, fill: 0.70)        // 5-hour
    bar(y: shape.midY - gap / 2 - barH, fill: 0.45) // weekly
    return ctx.makeImage()!
}

let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let defaultOut = script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.iconset")
let outDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : defaultOut
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for size in sizes {
    let url = outDir.appendingPathComponent(size.name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(size.px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(url.path)") }
    print("wrote \(url.path)")
}
