import AppKit

@MainActor
struct DemoScreen {
    var text = ""
    var checked = false
    var home = false

    func jpeg(longEdge: Int) throws -> (Data, Int, Int) {
        let width = max(1, Int(Double(min(longEdge, 1344)) * 390 / 844))
        let height = min(longEdge, 1344)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw KitError("ENCODING_FAILED", "Cannot render demo screen.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: Double(width) / 390, y: Double(height) / 844)
        context.translateBy(x: 0, y: 844)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.setFillColor(NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.98, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
        func label(_ text: String, x: Double, y: Double, size: Double, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            NSString(string: text).draw(in: CGRect(x: x, y: y, width: 345, height: 100), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        }
        label("9:41", x: 28, y: 18, size: 15, weight: .semibold, color: .black)
        label("DEMO", x: 302, y: 20, size: 11, weight: .semibold, color: .systemBlue)
        label(home ? "iPhoneKit" : "Today", x: 25, y: 90, size: 34, weight: .bold, color: .black)
        label(home ? "A phone for your agents." : "4 reminders", x: 26, y: 136, size: 15, color: .gray)
        let rows = home ? ["Reminders", "Notes", "Safari", "Settings"] : ["Try your first tap", "Send a screenshot to your agent", "Keep your iPhone unlocked", "Build something useful"]
        for (index, row) in rows.enumerated() {
            let y = 195.0 + Double(index) * 94
            let box = CGRect(x: 20, y: y, width: 350, height: 82)
            context.setFillColor(NSColor.white.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 15, cornerHeight: 15, transform: nil))
            context.fillPath()
            context.setStrokeColor((index == 0 && checked ? NSColor.systemBlue : NSColor.lightGray).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: 38, y: y + 27, width: 25, height: 25))
            if index == 0 && checked {
                context.setFillColor(NSColor.systemBlue.cgColor)
                context.fillEllipse(in: CGRect(x: 43, y: y + 32, width: 15, height: 15))
            }
            label(row, x: 79, y: y + 22, size: 17, color: .black)
        }
        label(text.isEmpty ? "Nothing touches your real phone in demo mode." : text,
              x: 26, y: 650, size: 15, color: .gray)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 129, y: 823, width: 132, height: 5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw KitError("ENCODING_FAILED", "Cannot encode demo screen.")
        }
        return (jpeg, width, height)
    }
}
