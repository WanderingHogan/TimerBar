import AppKit

// Renders the TimerBar app icon: a light-purple rounded square with
// "Timer" on the top line and "Bar" on the bottom line.

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx

    let size = CGFloat(pixels)

    // Rounded-square background
    let margin = size * 0.06
    let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = size * 0.22
    NSColor(calibratedRed: 0.78, green: 0.64, blue: 0.92, alpha: 1).setFill()  // light purple
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    // Two-line text
    let textColor = NSColor(calibratedRed: 0.24, green: 0.13, blue: 0.42, alpha: 1)  // deep purple
    func drawLine(_ s: String, fontSize: CGFloat, centerY: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let str = NSAttributedString(string: s, attributes: attrs)
        let ts = str.size()
        str.draw(at: NSPoint(x: (size - ts.width) / 2, y: centerY - ts.height / 2))
    }
    let fs = size * 0.215
    drawLine("Timer", fontSize: fs, centerY: size * 0.605)
    drawLine("Bar", fontSize: fs, centerY: size * 0.375)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = "TimerBar.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    let data = renderPNG(pixels: px)
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}
print("wrote \(iconset)")
