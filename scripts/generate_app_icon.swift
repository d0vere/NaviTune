import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "NavidromeMusicSync/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create graphics context")
}

let rect = CGRect(origin: .zero, size: CGSize(width: 1024, height: 1024))

let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 0.055, green: 0.090, blue: 0.190, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.180, green: 0.105, blue: 0.420, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.090, green: 0.390, blue: 0.560, alpha: 1).cgColor
    ] as CFArray,
    locations: [0.0, 0.52, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 120, y: 920),
    end: CGPoint(x: 920, y: 100),
    options: []
)

// Soft luminous disc behind the mark.
context.saveGState()
context.setShadow(offset: .zero, blur: 55, color: NSColor.white.withAlphaComponent(0.18).cgColor)
context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
context.fillEllipse(in: CGRect(x: 176, y: 176, width: 672, height: 672))
context.restoreGState()

// Central "N" bridge, intentionally geometric so it remains legible at small sizes.
let mark = NSBezierPath()
mark.move(to: NSPoint(x: 300, y: 300))
mark.line(to: NSPoint(x: 300, y: 724))
mark.curve(to: NSPoint(x: 365, y: 756), controlPoint1: NSPoint(x: 300, y: 748), controlPoint2: NSPoint(x: 338, y: 766))
mark.line(to: NSPoint(x: 660, y: 360))
mark.line(to: NSPoint(x: 660, y: 724))
mark.curve(to: NSPoint(x: 724, y: 724), controlPoint1: NSPoint(x: 660, y: 748), controlPoint2: NSPoint(x: 700, y: 748))
mark.line(to: NSPoint(x: 724, y: 300))
mark.curve(to: NSPoint(x: 660, y: 268), controlPoint1: NSPoint(x: 724, y: 276), controlPoint2: NSPoint(x: 686, y: 260))
mark.line(to: NSPoint(x: 364, y: 664))
mark.line(to: NSPoint(x: 364, y: 300))
mark.curve(to: NSPoint(x: 300, y: 300), controlPoint1: NSPoint(x: 364, y: 276), controlPoint2: NSPoint(x: 324, y: 276))
mark.close()
NSColor.white.setFill()
mark.fill()

// Three audio-wave bars crossing the bridge: Navidrome music flowing into Music.
let barXs: [CGFloat] = [430, 502, 574]
let barHeights: [CGFloat] = [118, 188, 138]
for (x, h) in zip(barXs, barHeights) {
    let barRect = NSRect(x: x, y: 418 - h / 2, width: 34, height: h)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: 17, yRadius: 17)
    NSColor(calibratedRed: 0.32, green: 0.92, blue: 0.90, alpha: 1).setFill()
    bar.fill()
}

// Small sync accent.
let ring = NSBezierPath(ovalIn: NSRect(x: 695, y: 665, width: 120, height: 120))
ring.lineWidth = 18
NSColor.white.withAlphaComponent(0.88).setStroke()
ring.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode app icon PNG")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL, options: .atomic)
print("Generated NaviTune app icon at \(outputPath)")
