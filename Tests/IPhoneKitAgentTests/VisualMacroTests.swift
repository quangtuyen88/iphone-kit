import AppKit
import Foundation
import Testing
import IPhoneKitCore
@testable import IPhoneKitAgent

private func fixtureJPEG(width: Int = 160, height: Int = 320, patch: CGRect? = nil, patchColor: NSColor = .systemBlue) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw KitError("TEST_IMAGE", "Could not create image fixture.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
    context.setLineWidth(2)
    for x in stride(from: 8, to: width, by: 24) {
        context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height))
    }
    for y in stride(from: 8, to: height, by: 28) {
        context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
    }
    context.strokePath()
    if let patch {
        context.setFillColor(patchColor.cgColor)
        context.fill(patch)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
        throw KitError("TEST_IMAGE", "Could not encode image fixture.")
    }
    return data
}

private func screenshot(_ jpeg: Data, id: String = UUID().uuidString, pointer: CGPoint? = nil) -> Screenshot {
    Screenshot(id: id, phoneID: "phone", epoch: 1, width: 160, height: 320,
               nativeWidth: 160, nativeHeight: 320, capturedAt: Date(), jpeg: jpeg,
               pointerX: pointer.map { Double($0.x) }, pointerY: pointer.map { Double($0.y) }, pointerVisible: pointer != nil)
}

@Test func exactImageAndLocalizedChange() async throws {
    let base = try fixtureJPEG()
    let anchor = try VisualAnchor(screenshot: screenshot(base), tolerance: 0.035)
    let matcher = LocalVisualMatcher()
    #expect(try await matcher.matches(anchor, screenshot: screenshot(base)))

    let changed = try fixtureJPEG(patch: CGRect(x: 25, y: 80, width: 24, height: 22), patchColor: .systemRed)
    #expect(!(try await matcher.matches(anchor, screenshot: screenshot(changed))))
}

@Test func pointerMaskOnlyMasksRecordedAndLiveCursor() async throws {
    let base = try fixtureJPEG()
    let recorded = screenshot(base, pointer: CGPoint(x: 80, y: 160))
    let anchor = try VisualAnchor(screenshot: recorded)
    let matcher = LocalVisualMatcher()
    let cursorChange = try fixtureJPEG(patch: CGRect(x: 77, y: 157, width: 6, height: 6), patchColor: .black)
    #expect(try await matcher.matches(anchor, screenshot: screenshot(cursorChange, pointer: CGPoint(x: 80, y: 160))))

    let outsideChange = try fixtureJPEG(patch: CGRect(x: 20, y: 40, width: 14, height: 14), patchColor: .black)
    #expect(!(try await matcher.matches(anchor, screenshot: screenshot(outsideChange, pointer: CGPoint(x: 80, y: 160)))))
}

@Test func contextMatchesWhenLiveScreenIsUnchanged() async throws {
    let base = try fixtureJPEG()
    let anchor = try VisualAnchor(screenshot: screenshot(base))
    let matcher = LocalVisualMatcher()
    #expect(try await matcher.matches(anchor, screenshot: screenshot(base)))
    #expect(try await matcher.matchesContext(anchor, screenshot: screenshot(base)))
}

@Test func croppedTargetMatchesWhileContextRejectsOverlayOutsideCrop() async throws {
    let base = try fixtureJPEG()
    // Crop covers x 16...80 px; the overlay sits at x 100...130 px, outside it in any orientation.
    let crop = MacroRegion(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
    let anchor = try VisualAnchor(screenshot: screenshot(base), region: crop)
    let matcher = LocalVisualMatcher()
    let overlay = try fixtureJPEG(patch: CGRect(x: 100, y: 200, width: 30, height: 30), patchColor: .systemRed)
    #expect(try await matcher.matches(anchor, screenshot: screenshot(overlay)))
    #expect(!(try await matcher.matchesContext(anchor, screenshot: screenshot(overlay))))
}

@Test func highTargetToleranceDoesNotWeakenContextCap() async throws {
    let base = try fixtureJPEG()
    let anchor = try VisualAnchor(screenshot: screenshot(base), tolerance: 0.5)
    let matcher = LocalVisualMatcher()
    let changed = try fixtureJPEG(patch: CGRect(x: 40, y: 100, width: 40, height: 40), patchColor: .systemRed)
    // The loose target tolerance accepts the change; the capped context tolerance must not.
    #expect(try await matcher.matches(anchor, screenshot: screenshot(changed)))
    #expect(!(try await matcher.matchesContext(anchor, screenshot: screenshot(changed))))
}

@Test func flatContextMatchesWhileFlatTargetIsRejected() async throws {
    let flat = try fixtureJPEG(patch: CGRect(x: 0, y: 0, width: 160, height: 320), patchColor: .systemBlue)
    let anchor = try VisualAnchor(screenshot: screenshot(flat))
    let matcher = LocalVisualMatcher()
    await #expect(throws: KitError.self) {
        _ = try await matcher.matches(anchor, screenshot: screenshot(flat))
    }
    #expect(try await matcher.matchesContext(anchor, screenshot: screenshot(flat)))
}

private struct TargetOnlyMatcher: VisualMatching {
    func matches(_ anchor: VisualAnchor, screenshot: Screenshot) async throws -> Bool { true }
}

@Test func defaultContextMatchingThrowsInsteadOfFallingBack() async throws {
    let base = try fixtureJPEG()
    let anchor = try VisualAnchor(screenshot: screenshot(base))
    let matcher = TargetOnlyMatcher()
    #expect(try await matcher.matches(anchor, screenshot: screenshot(base)))
    await #expect(throws: KitError("MACRO_CONTEXT_UNSUPPORTED", "This visual matcher does not support full-screen context matching.")) {
        _ = try await matcher.matchesContext(anchor, screenshot: screenshot(base))
    }
}

@Test func gestureScalesToFreshScreenshotAndDropsRuntimeMetadata() throws {
    let data = try fixtureJPEG(width: 100, height: 200)
    let first = Screenshot(id: "old", phoneID: "phone", epoch: 1, width: 100, height: 200,
                           nativeWidth: 100, nativeHeight: 200, capturedAt: Date(), jpeg: data)
    let command = PhoneCommand(action: .drag, screenshotID: "forged", idempotencyKey: "forged",
                               deadline: Date(), fromX: 10, fromY: 20, toX: 80, toY: 120, speed: "fast")
    let gesture = try MacroGesture(command: command, screenshot: first)
    let second = Screenshot(id: "new", phoneID: "phone", epoch: 1, width: 200, height: 400,
                            nativeWidth: 200, nativeHeight: 400, capturedAt: Date(), jpeg: data)
    let replay = try gesture.command(for: second)
    #expect(replay.screenshotID == "new")
    #expect(UUID(uuidString: replay.idempotencyKey ?? "") != nil)
    #expect(replay.deadline == nil)
    #expect(replay.fromX == 20 && replay.fromY == 40 && replay.toX == 160 && replay.toY == 240)
}

@Test func profileStoreRoundTripAndCorruption() throws {
    let data = try fixtureJPEG()
    let shot = screenshot(data)
    let anchor = try VisualAnchor(screenshot: shot)
    let command = PhoneCommand(action: .tap, x: 40, y: 80)
    let gesture = try MacroGesture(command: command, screenshot: shot)
    let step = MacroStep(name: "Tap", gesture: gesture, before: anchor, after: anchor)
    let profile = MacroProfile(name: "Demo", phoneID: "phone", nativeWidth: 160, nativeHeight: 320, steps: [step])
    try profile.validate()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("macros.json")
    let store = MacroStore(url: url)
    try store.save([profile])
    #expect(try store.load().first?.id == profile.id)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try Data("not json".utf8).write(to: url)
    #expect(throws: KitError.self) { try store.load() }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "not json")
    try? FileManager.default.removeItem(at: directory)
}

@Test func invalidDecodedValuesAreRejected() throws {
    var landscape = MacroProfile(name: "x", phoneID: "p", nativeWidth: 400, nativeHeight: 300)
    #expect(throws: KitError.self) { try landscape.validate(allowDraft: true) }
    landscape.nativeWidth = 300; landscape.nativeHeight = 400
    landscape.maximumSeconds = .nan
    #expect(throws: KitError.self) { try landscape.validate(allowDraft: true) }
    #expect(throws: KitError.self) {
        _ = try VisualAnchor(screenshot: Screenshot(phoneID: "p", epoch: 1, width: 10, height: 10,
                                                    nativeWidth: 10, nativeHeight: 10, capturedAt: Date(), jpeg: Data([0xFF, 0xD8])))
    }
}
