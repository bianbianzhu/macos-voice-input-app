import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
NSColor.clear.set()
canvas.fill()

// Squircle-ish rounded-rect background with a vertical indigo→blue gradient.
let radius: CGFloat = 229   // ~Apple's 0.2237 * 1024
let bg = NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.41, blue: 0.96, alpha: 1),   // indigo
    NSColor(srgbRed: 0.13, green: 0.39, blue: 0.93, alpha: 1)    // blue
])!
gradient.draw(in: bg, angle: -90)

// Five rounded white bars (the app's waveform motif), center-tall.
let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
let barW: CGFloat = 92
let gap: CGFloat = 60
let maxH: CGFloat = 540
let totalW = barW * CGFloat(weights.count) + gap * CGFloat(weights.count - 1)
var x = (CGFloat(size) - totalW) / 2
let cy = CGFloat(size) / 2
NSColor.white.withAlphaComponent(0.96).set()
for w in weights {
    let h = max(barW, maxH * w)
    let rect = NSRect(x: x, y: cy - h / 2, width: barW, height: h)
    NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
