import AppKit
import CoreGraphics
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icon = URL(fileURLWithPath: CommandLine.arguments[2])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

func drawLayer(in ctx: CGContext, y: CGFloat, top: UInt32, left: UInt32, right: UInt32) {
    let far = CGPoint(x: 512, y: y + 130)
    let west = CGPoint(x: 260, y: y)
    let front = CGPoint(x: 512, y: y - 129)
    let east = CGPoint(x: 764, y: y)
    let base = CGPoint(x: front.x, y: front.y - 49)
    let westBase = CGPoint(x: west.x, y: west.y - 49)
    let eastBase = CGPoint(x: east.x, y: east.y - 49)

    ctx.setFillColor(color(left))
    ctx.addPath(polygon([west, front, base, westBase]))
    ctx.fillPath()
    ctx.setFillColor(color(right))
    ctx.addPath(polygon([front, east, eastBase, base]))
    ctx.fillPath()
    ctx.setFillColor(color(top))
    ctx.addPath(polygon([far, west, front, east]))
    ctx.fillPath()

    ctx.setStrokeColor(color(0xFFD28A, alpha: 0.56))
    ctx.setLineWidth(5)
    ctx.setLineJoin(.round)
    ctx.addLines(between: [west, front, east])
    ctx.strokePath()
}

func drawIcon(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    let bounds = CGRect(x: 80, y: 80, width: 864, height: 864)
    let body = CGPath(roundedRect: bounds, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, alpha: 0.45))
    ctx.setFillColor(color(0x0B0D10))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(colorsSpace: colorSpace, colors: [color(0x181D23), color(0x0B0D10)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 944), end: CGPoint(x: 512, y: 80), options: [])
    let glow = CGGradient(colorsSpace: colorSpace,
                          colors: [color(0x7D460D, alpha: 0.3), color(0x7D460D, alpha: 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 88,
                           endCenter: CGPoint(x: 512, y: 476), endRadius: 455, options: [])
    ctx.restoreGState()

    ctx.addPath(body)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(color(0xBEC7D1, alpha: 0.17))
    ctx.strokePath()

    drawLayer(in: ctx, y: 397, top: 0x965515, left: 0x6E380B, right: 0x532705)
    drawLayer(in: ctx, y: 507, top: 0xC77819, left: 0x95510B, right: 0x763A06)
    drawLayer(in: ctx, y: 617, top: 0xF5A524, left: 0xC87615, right: 0xA55E0D)
    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var representations: [(image: CGImage, dpi: Int)] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let image = drawIcon(size * scale)
        representations.append((image, 72 * scale))
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = CGSize(width: size, height: size)
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", output.path, "-o", icon.path]
try iconutil.run()
iconutil.waitUntilExit()

if iconutil.terminationStatus != 0 {
    // The IconServices writer can reject valid iconsets under headless build restrictions.
    guard let destination = CGImageDestinationCreateWithURL(icon as CFURL, "com.apple.icns" as CFString,
                                                            representations.count, nil) else {
        throw CocoaError(.fileWriteUnsupportedScheme)
    }
    for (image, dpi) in representations {
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard let source = CGImageSourceCreateWithURL(icon as CFURL, nil),
      CGImageSourceGetCount(source) == representations.count else {
    throw CocoaError(.fileReadCorruptFile)
}
