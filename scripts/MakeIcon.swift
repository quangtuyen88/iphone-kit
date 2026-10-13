import AppKit
import Foundation

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let c = graphics.cgContext
    let s = Double(size)
    c.setFillColor(NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.91, alpha: 1).cgColor)
    c.addPath(CGPath(roundedRect: CGRect(x: s * 0.025, y: s * 0.025, width: s * 0.95, height: s * 0.95), cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
    c.fillPath()
    let phone = CGRect(x: s * 0.32, y: s * 0.17, width: s * 0.36, height: s * 0.66)
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.055, color: NSColor.black.withAlphaComponent(0.23).cgColor)
    c.setFillColor(NSColor.white.cgColor)
    c.addPath(CGPath(roundedRect: phone, cornerWidth: s * 0.065, cornerHeight: s * 0.065, transform: nil))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.setFillColor(NSColor(calibratedRed: 0.86, green: 0.91, blue: 1, alpha: 1).cgColor)
    c.addPath(CGPath(roundedRect: phone.insetBy(dx: s * 0.019, dy: s * 0.019), cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
    c.fillPath()
    c.setFillColor(NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.91, alpha: 1).cgColor)
    c.addPath(CGPath(roundedRect: CGRect(x: s * 0.432, y: s * 0.773, width: s * 0.136, height: s * 0.022), cornerWidth: s * 0.011, cornerHeight: s * 0.011, transform: nil))
    c.fillPath()
    for i in 0..<3 {
        c.setFillColor(NSColor.white.cgColor)
        c.addPath(CGPath(roundedRect: CGRect(x: s * 0.375, y: s * (0.57 - Double(i) * 0.12), width: s * 0.25, height: s * 0.09), cornerWidth: s * 0.017, cornerHeight: s * 0.017, transform: nil))
        c.fillPath()
        c.setFillColor(NSColor.systemBlue.cgColor)
        c.fillEllipse(in: CGRect(x: s * 0.4, y: s * (0.60 - Double(i) * 0.12), width: s * 0.03, height: s * 0.03))
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
