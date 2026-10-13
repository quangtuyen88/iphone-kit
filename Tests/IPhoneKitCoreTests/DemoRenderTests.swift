import AppKit
import Vision
import Testing
@testable import IPhoneKitCore

@Test @MainActor func demoScreenTextIsReadable() throws {
    let (jpeg, _, _) = try DemoScreen().jpeg(longEdge: 1344)
    let image = try #require(NSBitmapImageRep(data: jpeg)?.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    #expect(text.contains("Today"))
    #expect(text.contains("Try your first tap"))
}
