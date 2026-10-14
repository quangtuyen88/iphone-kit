import AppKit
import Foundation
import ImageIO
import Testing
import IPhoneKitCore
import IPhoneKitAgent

private struct LiveGuardFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Never follow redirects (including local redirects), forward credentials, or use disk caches.
private final class LiveGuardNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct LiveGuardPhones: Decodable {
    let phones: [PhoneInfo]
}

private func liveGuardToken(_ environment: [String: String]) throws -> String {
    let value: String
    if let supplied = environment["IPHONEKIT_API_KEY"] {
        value = supplied
    } else {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iPhoneKit/api-token")
        do { value = try String(contentsOf: file, encoding: .utf8) }
        catch { throw LiveGuardFailure("Existing API token unavailable; supply IPHONEKIT_API_KEY. No key was created.") }
    }
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
        throw LiveGuardFailure("API token is empty or invalid.")
    }
    return token
}

private func liveGuardGET<T: Decodable>(_ type: T.Type, path: String, port: UInt16,
                                       token: String, session: URLSession,
                                       screenshot: Bool = false) async throws -> T {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = Int(port)
    components.path = path
    if screenshot { components.queryItems = [URLQueryItem(name: "long_edge", value: "900")] }
    guard let url = components.url else { throw LiveGuardFailure("Could not form loopback API URL.") }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue(token, forHTTPHeaderField: "X-API-Key")
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) }
    catch { throw LiveGuardFailure("Loopback GET failed; open the existing app and check its API port. Details redacted.") }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw LiveGuardFailure("Loopback GET was not HTTP 200; check authentication and capture readiness. Response redacted.")
    }
    do { return try KitJSON.decoder().decode(type, from: data) }
    catch { throw LiveGuardFailure("Loopback response could not decode as a Core DTO. Details redacted.") }
}

private func liveGuardOverlay(_ shot: Screenshot) throws -> Screenshot {
    guard let source = CGImageSourceCreateWithData(shot.jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == shot.width, image.height == shot.height,
          let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw LiveGuardFailure("Capture JPEG dimensions or in-memory rendering are invalid.")
    }
    let width = CGFloat(image.width), height = CGFloat(image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Both black and white ensure a substantial change, well outside the left crop.
    // Vertical placement is symmetric, independent of bitmap coordinate orientation.
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: width * 0.65, y: height * 0.15, width: width * 0.15, height: height * 0.7))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: width * 0.80, y: height * 0.15, width: width * 0.15, height: height * 0.7))
    guard let rendered = context.makeImage(),
          let jpeg = NSBitmapImageRep(cgImage: rendered).representation(using: .jpeg,
                                                                      properties: [.compressionFactor: 1.0]) else {
        throw LiveGuardFailure("Could not encode the in-memory overlay JPEG.")
    }
    // Preserve actual capture metadata, including absent uptime from older live apps.
    // This synthetic image is not a new capture and supplies no freshness evidence.
    return Screenshot(id: shot.id, phoneID: shot.phoneID, epoch: shot.epoch,
                      width: shot.width, height: shot.height,
                      nativeWidth: shot.nativeWidth, nativeHeight: shot.nativeHeight,
                      capturedAt: shot.capturedAt, jpeg: jpeg,
                      pointerX: shot.pointerX, pointerY: shot.pointerY,
                      pointerVisible: shot.pointerVisible, capturedUptime: shot.capturedUptime)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IPHONEKIT_LIVE_GUARD_SMOKE"] == "1"))
func liveCaptureImageGuardsRejectOutsideCropOverlay() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let port = UInt16(environment["IPHONEKIT_PORT"] ?? "8766"), port != 0 else {
        throw LiveGuardFailure("IPHONEKIT_PORT must be a nonzero UInt16 port; default is 8766.")
    }
    let token = try liveGuardToken(environment)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.connectionProxyDictionary = [:]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: LiveGuardNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let inventory = try await liveGuardGET(LiveGuardPhones.self, path: "/v1/phones",
                                          port: port, token: token, session: session)
    guard inventory.phones.count == 1, let phone = inventory.phones.first else {
        throw LiveGuardFailure("Connect exactly one non-demo phone before opting in; inventory is empty or ambiguous.")
    }
    guard phone.id != "demo-iphone", phone.model != "Simulated device", phone.systemVersion != "Demo",
          phone.status == .ready, phone.width > 0, phone.height > phone.width else {
        throw LiveGuardFailure("The sole phone must be ready, non-demo and portrait; complete setup manually, then retry.")
    }
    let safeIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !phone.id.isEmpty, phone.id.unicodeScalars.allSatisfy({ safeIDCharacters.contains($0) }) else {
        throw LiveGuardFailure("Phone identifier is not a safe single API path component. Identifier redacted.")
    }
    let shot = try await liveGuardGET(Screenshot.self, path: "/v1/phones/" + phone.id + "/screenshot",
                                     port: port, token: token, session: session, screenshot: true)
    guard shot.phoneID == phone.id, shot.epoch == phone.epoch,
          shot.width > 0, shot.width < shot.height, shot.height == 900,
          shot.nativeWidth > 0, shot.nativeWidth < shot.nativeHeight, shot.orientation == "portrait" else {
        throw LiveGuardFailure("Capture must belong to the selected connection and be portrait with a 900-pixel long edge.")
    }
    // Native dimensions are capture attributes, not an inferred resized-screen aspect ratio.
    // No OCR, input, macro dispatch, timing inference, or persistent image output occurs here.
    do {
        let crop = MacroRegion(x: 0.05, y: 0.1, width: 0.4, height: 0.8)
        let anchor = try VisualAnchor(screenshot: shot, region: crop, tolerance: 0.035)
        let matcher = LocalVisualMatcher()
        let sameTarget = try await matcher.matches(anchor, screenshot: shot)
        let sameContext = try await matcher.matchesContext(anchor, screenshot: shot)
        #expect(sameTarget, "An informative left crop must match the original real capture.")
        #expect(sameContext, "Full context must match the original real capture.")
        let overlay = try liveGuardOverlay(shot)
        let overlayTarget = try await matcher.matches(anchor, screenshot: overlay)
        let overlayContext = try await matcher.matchesContext(anchor, screenshot: overlay)
        #expect(overlayTarget, "High-quality right-side overlay must preserve the left crop match.")
        #expect(!overlayContext, "Mandatory full context must reject the right-side overlay.")
    } catch {
        throw LiveGuardFailure("Image guard smoke failed. Use a harmless static screen with informative left-side content; matcher/render details redacted. No fuzzy pass or tolerance fallback.")
    }
}
