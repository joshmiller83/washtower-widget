// Draws the app icon. `swift scripts/icon.swift mac out.png` makes the macOS icon
// (rounded square with a shadow); `ios` makes a full-bleed square, which iOS masks itself.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, ["mac", "ios"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: icon.swift mac|ios <out.png>\n".utf8)); exit(2)
}
let isMac = args[1] == "mac"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let deep = NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.75, alpha: 1)
let bright = NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1)

let rect = isMac ? NSRect(x: 100, y: 100, width: 824, height: 824) : NSRect(x: 0, y: 0, width: 1024, height: 1024)
let shape = isMac ? NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185) : NSBezierPath(rect: rect)
if isMac {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    deep.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}
NSGradient(starting: bright, ending: deep)!.draw(in: shape, angle: -90)

// Countdown ring: orange progress over a faint track.
let center = NSPoint(x: 512, y: 512), radius: CGFloat = isMac ? 300 : 360, width: CGFloat = isMac ? 44 : 52
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: -150, endAngle: 90, clockwise: true)
track.lineWidth = width
NSColor.white.withAlphaComponent(0.22).setStroke()
track.stroke()
let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -150, clockwise: true)
ring.lineWidth = width
ring.lineCapStyle = .round
NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1).setStroke()
ring.stroke()

// The washer symbol in white.
let config = NSImage.SymbolConfiguration(pointSize: isMac ? 300 : 360, weight: .medium)
if let symbol = NSImage(systemSymbolName: "washer", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = symbol.size
    let white = NSImage(size: size, flipped: false) { bounds in
        symbol.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    white.draw(in: NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height))
}
NSGraphicsContext.current = nil

// iOS icons must be opaque, so flatten onto an RGB context without alpha.
var output = rep
if !isMac, let image = rep.cgImage,
   let flat = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    flat.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if let opaque = flat.makeImage() { output = NSBitmapImageRep(cgImage: opaque) }
}
try! output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
