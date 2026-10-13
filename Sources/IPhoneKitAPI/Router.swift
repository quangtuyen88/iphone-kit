import Foundation
import IPhoneKitCore

@MainActor
final class APIRouter {
    private let controller: any PhoneControlling
    private let token: String
    private var results: [String: ActionResult] = [:]
    private var resultOrder: [String] = []
    init(controller: any PhoneControlling, token: String) { self.controller = controller; self.token = token }

    func handle(_ request: HTTPRequest, port: UInt16) async -> HTTPResponse {
        do {
            guard let host = request.headers["host"]?.lowercased(), ["localhost:\(port)", "127.0.0.1:\(port)"].contains(host) else {
                return .error("INVALID_HOST", "Only the local API host is accepted.", status: 403)
            }
            guard request.headers["origin"] == nil, request.headers["sec-fetch-site"] == nil else {
                return .error("BROWSER_REQUEST_DENIED", "Browser-origin API requests are not accepted.", status: 403)
            }
            guard let components = URLComponents(string: "http://localhost" + request.target) else {
                return .error("INVALID_PATH", "Invalid API path.", status: 400)
            }
            let path = components.path.split(separator: "/").map(String.init)
            if path == ["health"], request.method == "GET" {
                struct Health: Encodable { let status = "ok"; let service = "iPhoneKit" }
                return try .json(Health())
            }
            let supplied: String?
            if let authorization = request.headers["authorization"], authorization.lowercased().hasPrefix("bearer ") {
                supplied = String(authorization.dropFirst(7))
            } else { supplied = request.headers["x-api-key"] }
            guard let supplied, constantTimeEqual(supplied, token) else {
                return .error("AUTH_REQUIRED", "Send the local API token in X-API-Key or Authorization: Bearer.", status: 401)
            }
            guard ["GET", "POST"].contains(request.method) else { return .error("METHOD_NOT_ALLOWED", "Use GET or POST.", status: 405) }
            if request.method == "POST" {
                guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                    return .error("JSON_REQUIRED", "Set Content-Type: application/json.", status: 415)
                }
            } else if !request.body.isEmpty { return .error("INVALID_BODY", "GET requests cannot have a body.", status: 400) }
            if path == ["v1", "phones"], request.method == "GET" {
                struct Phones: Encodable { let phones: [PhoneInfo] }
                return try .json(Phones(phones: controller.phones))
            }
            if path.count == 3, path[0] == "v1", path[1] == "jobs", request.method == "GET", let result = results[path[2]] {
                return try .json(result)
            }
            guard path.count == 4, path[0] == "v1", path[1] == "phones",
                  let phone = controller.phones.first(where: { $0.id == path[2] }) else {
                return .error("PHONE_NOT_FOUND", "Phone or endpoint not found.", status: 404)
            }
            let endpoint = path[3]
            if endpoint == "status", request.method == "GET" { return try .json(phone) }
            if endpoint == "screenshot", request.method == "GET" {
                let query = components.queryItems?.filter { $0.name == "long_edge" } ?? []
                guard query.count <= 1, query.isEmpty || Int(query[0].value ?? "") != nil else {
                    return .error("INVALID_SIZE", "long_edge must be an integer.", status: 400)
                }
                let edge = query.first.flatMap { Int($0.value ?? "") } ?? 1344
                return try .json(try await controller.screenshot(phoneID: phone.id, longEdge: edge))
            }
            guard request.method == "POST" else { return .error("METHOD_NOT_ALLOWED", "This endpoint requires POST.", status: 405) }
            guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .error("INVALID_BODY", "The JSON body must be an object.", status: 400)
            }
            if endpoint == "prepare" {
                try await controller.prepare(phoneID: phone.id)
                struct Prepared: Encodable { let status = "setup_started" }
                return try .json(Prepared())
            }
            if endpoint == "cancel" {
                controller.cancel(phoneID: phone.id)
                struct Cancelled: Encodable { let status = "cancelled" }
                return try .json(Cancelled())
            }
            if endpoint == "bind-capture" {
                guard let captureID = object["capture_id"] as? String else { return .error("INVALID_CAPTURE", "capture_id is required.", status: 400) }
                try controller.bindCapture(phoneID: phone.id, captureID: captureID)
                struct Bound: Encodable { let status = "bound" }
                return try .json(Bound())
            }
            if endpoint == "keep-awake" {
                guard let enabled = object["enabled"] as? Bool else { return .error("INVALID_KEEP_AWAKE", "enabled must be true or false.", status: 400) }
                try controller.setKeepAwake(phoneID: phone.id, enabled: enabled)
                struct KeepAwake: Encodable { let status = "updated"; let enabled: Bool }
                return try .json(KeepAwake(enabled: enabled))
            }
            let actions: [String: PhoneAction] = [
                "tap": .tap, "double-tap": .doubleTap, "triple-tap": .tripleTap, "tap-and-hold": .longPress,
                "long-press": .longPress, "flick": .flick, "drag": .drag, "hold-and-drag": .holdAndDrag,
                "type-text": .typeText, "press-key": .pressKey, "press-home": .pressHome, "wake": .wake, "move": .move, "release": .release,
            ]
            var payload = object
            if let action = actions[endpoint] { payload["action"] = action.rawValue }
            else if endpoint != "actions" { return .error("NOT_FOUND", "Unknown endpoint.", status: 404) }
            if let repeated = payload.removeValue(forKey: "repeat") { payload["repeat_count"] = repeated }
            let command = try KitJSON.decoder().decode(PhoneCommand.self, from: JSONSerialization.data(withJSONObject: payload))
            let result = try await controller.execute(phoneID: phone.id, command: command)
            results[result.id] = result
            resultOrder.append(result.id)
            if resultOrder.count > 256 { results.removeValue(forKey: resultOrder.removeFirst()) }
            return try .json(result)
        } catch let error as KitError {
            let status: Int
            switch error.code {
            case "PHONE_OFFLINE", "USB_UNAVAILABLE", "SCREEN_UNAVAILABLE", "CAPTURE_BUSY": status = 503
            case "CAMERA_PERMISSION", "BLUETOOTH_PERMISSION": status = 403
            case "QUEUE_FULL": status = 429
            case "DEADLINE_EXCEEDED": status = 504
            case "PHONE_ASLEEP", "PHONE_NOT_READY", "PHONE_ALREADY_AWAKE", "STALE_SCREENSHOT", "CONNECTION_CHANGED", "BLUETOOTH_DISCONNECTED", "ACTION_INTERRUPTED", "IDEMPOTENCY_CONFLICT", "CANCELLED": status = 409
            default: status = 400
            }
            return .error(error.code, error.message, status: status)
        } catch is DecodingError {
            return .error("INVALID_BODY", "Invalid action parameters. Check the documented JSON field types.", status: 400)
        } catch {
            return .error("OPERATION_FAILED", "Operation failed. Check the Mac app's connection status.", status: 400)
        }
    }
}
