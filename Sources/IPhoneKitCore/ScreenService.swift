import Foundation
@preconcurrency import AVFoundation
import CoreMediaIO
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// AVCapture retains each delivered pixel buffer for the lifetime of this immutable frame.
struct CapturedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let capturedAt: Date
    let uptime: TimeInterval
    let width: Int
    let height: Int
    let geometryGeneration: UInt64
}

private final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CapturedFrame?
    private var generation: UInt64 = 0
    func accept(_ pixels: CVPixelBuffer) {
        lock.withLock {
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            if frame?.width != width || frame?.height != height { generation &+= 1 }
            frame = CapturedFrame(pixels: pixels, capturedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                                  width: width, height: height, geometryGeneration: generation)
        }
    }
    func snapshot() -> CapturedFrame? { lock.withLock { frame } }
}

/// The session, output and delegate callbacks are confined to this private serial queue.
private final class CapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "iPhoneKit capture", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let store = FrameStore()
    private var received = 0
    private var configured = false

    func start(device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    if !configured {
                        let input = try AVCaptureDeviceInput(device: device)
                        let output = AVCaptureVideoDataOutput()
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.alwaysDiscardsLateVideoFrames = true
                        output.setSampleBufferDelegate(self, queue: queue)
                        session.beginConfiguration()
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            session.commitConfiguration()
                            throw KitError("CAPTURE_BUSY", "Another application may be using this iPhone screen. Close QuickTime or other mirroring apps.")
                        }
                        session.addInput(input)
                        session.addOutput(output)
                        session.commitConfiguration()
                        configured = true
                    }
                    session.startRunning()
                    guard session.isRunning else { throw KitError("CAPTURE_FAILED", "Unable to start the iPhone screen. Unlock and reconnect it.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        received += 1
        guard received > 5, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        store.accept(pixels)
    }

    func latest() -> CapturedFrame? { store.snapshot() }
}

struct EncodedFrame: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let nativeWidth: Int
    let nativeHeight: Int
    let capturedAt: Date
    let uptime: TimeInterval
    let geometryGeneration: UInt64
}

@MainActor
final class ScreenService {
    private var devices: [String: AVCaptureDevice] = [:]
    private var pipelines: [String: CapturePipeline] = [:]
    private var starting: [String: Task<Void, any Error>] = [:]
    private var originalScreenCapture: UInt32?
    private var enabled = false
    var captures: [CaptureInfo] { devices.values.map { CaptureInfo(id: $0.uniqueID, name: $0.localizedName) }.sorted { $0.id < $1.id } }
    var permission: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "allowed"
        case .denied, .restricted: "denied"
        default: "not_requested"
        }
    }

    func enableDiscovery() throws {
        guard !enabled else { return }
        var address = propertyAddress()
        var original: UInt32 = 0
        var used: UInt32 = 0
        if CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &used, &original) == 0 {
            originalScreenCapture = original
        }
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &allow)
        guard status == 0 else { throw KitError("CAPTURE_UNAVAILABLE", "iPhone screen discovery is unavailable on this macOS version.") }
        enabled = true
        refresh()
    }

func refresh() {
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified).devices
            .filter { device in device.hasMediaType(.muxed) && device.modelID == "iOS Device" }
        devices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uniqueID, $0) })
        for id in pipelines.keys where devices[id] == nil {
            if let pipeline = pipelines.removeValue(forKey: id) { Task { await pipeline.stop() } }
        }
    }

func requestPermission() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw KitError("CAMERA_PERMISSION", "Allow iPhoneKit in System Settings > Privacy & Security > Camera, then retry.")
        }
    }

    func start(captureID: String) async throws {
        if let existing = starting[captureID] { return try await existing.value }
        if pipelines[captureID] != nil { return }
        guard let device = devices[captureID] else { throw KitError("CAPTURE_NOT_FOUND", "Select a connected iPhone screen source.") }
        let pipeline = CapturePipeline()
        let task = Task { try await pipeline.start(device: device) }
        starting[captureID] = task
        defer { starting.removeValue(forKey: captureID) }
        try await task.value
        pipelines[captureID] = pipeline
    }

    func frame(captureID: String) -> CapturedFrame? { pipelines[captureID]?.latest() }

    func screenshot(captureID: String, longEdge: Int) async throws -> EncodedFrame {
        guard (1...4096).contains(longEdge) else { throw KitError("INVALID_SIZE", "long_edge must be 1–4096.") }
        try await start(captureID: captureID)
        for _ in 0..<100 {
            if let frame = frame(captureID: captureID) {
                guard ProcessInfo.processInfo.systemUptime - frame.uptime < 3 else {
                    throw KitError("SCREEN_STALE", "The screen stopped updating. Unlock and reconnect the iPhone.")
                }
                return try await Self.encode(frame, longEdge: longEdge)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw KitError("SCREEN_UNAVAILABLE", "No screen frames received. Keep the iPhone plugged in and unlocked.")
    }

    @concurrent
    private static func encode(_ frame: CapturedFrame, longEdge: Int) async throws -> EncodedFrame {
        let scale = min(1, Double(longEdge) / Double(max(frame.width, frame.height)))
        let width = max(1, Int(Double(frame.width) * scale)), height = max(1, Int(Double(frame.height) * scale))
        let image = CIImage(cvPixelBuffer: frame.pixels)
            .transformed(by: CGAffineTransform(scaleX: Double(width) / Double(frame.width), y: Double(height) / Double(frame.height)))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw KitError("ENCODING_FAILED", "Cannot encode the iPhone screen.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw KitError("ENCODING_FAILED", "Cannot create screenshot JPEG.")
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw KitError("ENCODING_FAILED", "Screenshot encoding failed.") }
        return EncodedFrame(jpeg: data as Data, width: width, height: height, nativeWidth: frame.width, nativeHeight: frame.height,
                            capturedAt: frame.capturedAt, uptime: frame.uptime, geometryGeneration: frame.geometryGeneration)
    }

    func stop() async {
        for task in starting.values { _ = try? await task.value }
        starting.removeAll()
        for pipeline in pipelines.values { await pipeline.stop() }
        pipelines.removeAll()
        if enabled, var originalScreenCapture {
            var address = propertyAddress()
            _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &originalScreenCapture)
        }
        enabled = false
    }

    private func propertyAddress() -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}
