import Foundation
import CoreGraphics
import ImageIO
import Vision
import IPhoneKitCore

/// Local, deterministic image matching for visual macro guards. No image or OCR data
/// leaves this process.
public protocol VisualMatching: Sendable {
    func matches(_ anchor: VisualAnchor, screenshot: Screenshot) async throws -> Bool
}

public struct LocalVisualMatcher: VisualMatching {
    public init() {}

    /// Validates the encoded image and its decoded thumbnail bounds without retaining it.
    /// This is also used when decoding anchors from persisted JSON.
    internal static func validateImage(_ data: Data) throws {
        _ = try LocalVisualMatcher().decodeThumbnail(data)
    }

    public func matches(_ anchor: VisualAnchor, screenshot: Screenshot) async throws -> Bool {
        try Task.checkCancellation()
        try anchor.validateStored()
        try MacroValidation.validateScreenshotMetadata(screenshot)
        try MacroValidation.validateImageData(screenshot.jpeg)
        if screenshot.pointerVisible != false, screenshot.pointerX != nil || screenshot.pointerY != nil {
            guard let x = screenshot.pointerX, let y = screenshot.pointerY,
                  x.isFinite, y.isFinite,
                  x >= 0, y >= 0,
                  x < Double(screenshot.width), y < Double(screenshot.height) else {
                throw MacroValidation.error("INVALID_POINTER", "A visible pointer must have finite coordinates inside the screenshot.")
            }
        }

        let recorded = try decodeThumbnail(anchor.image)
        try Task.checkCancellation()
        let live = try decodeThumbnail(screenshot.jpeg)
        try Task.checkCancellation()
        let recordedSamples = try crop(recorded, region: anchor.region)
        let liveSamples = try crop(live, region: anchor.region)
        try Task.checkCancellation()

        let livePointer: MacroPoint?
        if screenshot.pointerVisible != false, let x = screenshot.pointerX, let y = screenshot.pointerY {
            livePointer = MacroPoint(x: x / Double(screenshot.width),
                                     y: y / Double(screenshot.height))
        } else {
            livePointer = nil
        }
        let mask = try buildMask(region: anchor.region, recorded: anchor.pointer, live: livePointer,
                                 sampleCount: recordedSamples.count)
        try Task.checkCancellation()
        guard recordedSamples.values.count == liveSamples.values.count else {
            throw MacroValidation.error("MATCH_FAILED", "The bounded screenshot thumbnails could not be compared.")
        }
        guard hasInformation(recordedSamples.values, mask: mask) else {
            throw MacroValidation.error("LOW_INFORMATION_ANCHOR", "The visual anchor contains too little image information to match safely.")
        }

        let pixelMatch = compare(recordedSamples.values, liveSamples.values,
                                 mask: mask, tolerance: anchor.tolerance)
        try Task.checkCancellation()
        guard pixelMatch else { return false }

        if !anchor.expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            let textMatches = try recognized(expected: anchor.expectedText, image: live, region: anchor.region)
            try Task.checkCancellation()
            guard textMatches else { return false }
        }
        return true
    }

    private struct Thumbnail {
        let image: CGImage
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct Samples {
        let values: [SIMD3<Float>]
        let count: Int
    }

    private func decodeThumbnail(_ data: Data) throws -> Thumbnail {
        try Task.checkCancellation()
        try MacroValidation.validateImageData(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MacroValidation.error("INVALID_IMAGE", "The visual anchor is not a decodable JPEG image.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MacroValidation.error("INVALID_IMAGE", "The JPEG has no bounded pixel dimensions.")
        }
        let sourceWidth = widthNumber.intValue
        let sourceHeight = heightNumber.intValue
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth < sourceHeight,
              sourceWidth <= MacroValidation.maxPortraitDimension,
              sourceHeight <= MacroValidation.maxPortraitDimension else {
            throw MacroValidation.error("IMAGE_TOO_LARGE", "Decoded macro images must be no larger than 4096 pixels per side.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MacroValidation.error("INVALID_IMAGE", "The JPEG thumbnail could not be decoded.")
        }
        let width = image.width
        let height = image.height
        guard width >= 2, height >= 2, width <= 512, height <= 512 else {
            throw MacroValidation.error("INVALID_IMAGE", "The bounded JPEG thumbnail has invalid dimensions.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw MacroValidation.error("INVALID_IMAGE", "Could not rasterize the bounded JPEG thumbnail.") }
        try Task.checkCancellation()
        return Thumbnail(image: image, width: width, height: height, pixels: pixels)
    }

    private func crop(_ image: Thumbnail, region: MacroRegion, side: Int = 128) throws -> Samples {
        try MacroValidation.validateRegion(region)
        let actualWidth = Double(image.width) * region.width
        let actualHeight = Double(image.height) * region.height
        guard actualWidth >= 2, actualHeight >= 2 else {
            throw MacroValidation.error("LOW_INFORMATION_ANCHOR", "The anchor region is too small to compare safely.")
        }
        var values = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: side * side)
        for row in 0..<side {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            let normalizedY = region.y + (Double(row) + 0.5) / Double(side) * region.height
            let pixelY = min(image.height - 1, max(0, Int(normalizedY * Double(image.height))))
            for column in 0..<side {
                let normalizedX = region.x + (Double(column) + 0.5) / Double(side) * region.width
                let pixelX = min(image.width - 1, max(0, Int(normalizedX * Double(image.width))))
                let offset = (pixelY * image.width + pixelX) * 4
                values[row * side + column] = SIMD3(
                    Float(image.pixels[offset]) / 255,
                    Float(image.pixels[offset + 1]) / 255,
                    Float(image.pixels[offset + 2]) / 255
                )
            }
        }
        return Samples(values: values, count: side)
    }

    private func buildMask(region: MacroRegion, recorded: MacroPoint?, live: MacroPoint?, sampleCount: Int) throws -> [Bool] {
        var mask = [Bool](repeating: false, count: sampleCount * sampleCount)
        let points = [recorded, live].compactMap { $0 }
        guard !points.isEmpty else { return mask }
        // AssistiveTouch is a small overlay. This radius is deliberately small and is
        // measured in full-screen normalized coordinates, not an arbitrary image area.
        let radius = 0.035
        for row in 0..<sampleCount {
            let globalY = region.y + (Double(row) + 0.5) / Double(sampleCount) * region.height
            for column in 0..<sampleCount {
                let globalX = region.x + (Double(column) + 0.5) / Double(sampleCount) * region.width
                if points.contains(where: {
                    let dx = (globalX - $0.x) / max(region.width, 0.000001)
                    let dy = (globalY - $0.y) / max(region.height, 0.000001)
                    return dx * dx + dy * dy <= (radius / max(region.width, region.height, 0.000001)) * (radius / max(region.width, region.height, 0.000001))
                }) {
                    mask[row * sampleCount + column] = true
                }
            }
        }
        let covered = mask.filter { $0 }.count
        guard Double(covered) / Double(mask.count) <= 0.30 else {
            throw MacroValidation.error("POINTER_MASK_TOO_LARGE", "The AssistiveTouch pointer mask covers too much of this visual guard.")
        }
        return mask
    }

    private func hasInformation(_ values: [SIMD3<Float>], mask: [Bool]) -> Bool {
        var count = 0
        var sum: Float = 0
        var sumSquares: Float = 0
        var minimum: Float = 1
        var maximum: Float = 0
        for (index, value) in values.enumerated() where !mask[index] {
            let luminance = value.x * 0.2126 + value.y * 0.7152 + value.z * 0.0722
            count += 1
            sum += luminance
            sumSquares += luminance * luminance
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
        }
        guard count >= 32 else { return false }
        let mean = sum / Float(count)
        let variance = max(0, sumSquares / Float(count) - mean * mean)
        let deviation = variance.squareRoot()
        // Pure or nearly pure flat-color guards are not safe visual evidence. Keep the
        // threshold low enough for a mostly blank screen with a real control/text edge.
        return deviation >= 0.004 || maximum - minimum >= 0.025
    }

    private func compare(_ recorded: [SIMD3<Float>], _ live: [SIMD3<Float>], mask: [Bool], tolerance: Double) -> Bool {
        var total: Float = 0
        var count = 0
        var maximumTile: Float = 0
        let side = Int(Double(recorded.count).squareRoot())
        let tileSide = 4
        let tileCount = (side + tileSide - 1) / tileSide
        var tileTotals = [Float](repeating: 0, count: tileCount * tileCount)
        var tileCounts = [Int](repeating: 0, count: tileTotals.count)
        for index in recorded.indices where !mask[index] {
            let difference = (abs(recorded[index].x - live[index].x)
                + abs(recorded[index].y - live[index].y)
                + abs(recorded[index].z - live[index].z)) / 3
            total += difference
            count += 1
            let row = index / side
            let column = index % side
            let tile = (row / tileSide) * tileCount + column / tileSide
            tileTotals[tile] += difference
            tileCounts[tile] += 1
        }
        guard count > 0 else { return false }
        let average = total / Float(count)
        guard average <= Float(tolerance) else { return false }
        for index in tileTotals.indices where tileCounts[index] > 0 {
            maximumTile = max(maximumTile, tileTotals[index] / Float(tileCounts[index]))
        }
        // A whole-screen average can hide a changed button or popup. Tile evidence is
        // intentionally stricter than the global tolerance.
        let tileThreshold = max(0.035, Float(tolerance) * 1.2)
        return maximumTile <= tileThreshold
    }

    private func recognized(expected: String, image: Thumbnail, region: MacroRegion) throws -> Bool {
        let x = max(0, Int((region.x * Double(image.width)).rounded(.down)))
        let y = max(0, Int((region.y * Double(image.height)).rounded(.down)))
        let width = min(image.width - x, max(1, Int((region.width * Double(image.width)).rounded(.up))))
        let height = min(image.height - y, max(1, Int((region.height * Double(image.height)).rounded(.up))))
        guard width > 1, height > 1, let crop = image.image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
            return false
        }
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        try Task.checkCancellation()
        let recognized = (request.results ?? []).flatMap { $0.topCandidates(3).map(\.string) }.joined(separator: " ")
        let wanted = canonicalText(expected)
        return !wanted.isEmpty && canonicalText(recognized).contains(wanted)
    }

    private func canonicalText(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
