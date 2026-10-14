import Foundation
import IPhoneKitCore
import Darwin

@MainActor
final class MCPBridge {
    private let base: URL
    private let token: String
    private let session: URLSession
    private let sessionID = UUID().uuidString
    private var initialized = false
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var sequence = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let rawPort = environment["IPHONEKIT_PORT"] ?? "8766"
        guard let port = UInt16(rawPort), port != 0, let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw KitError("INVALID_PORT", "IPHONEKIT_PORT must be a valid local port.")
        }
        base = url
        if let value = environment["IPHONEKIT_API_KEY"] { token = value }
        else {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iPhoneKit/api-token")
            guard let value = try? String(contentsOf: file, encoding: .utf8) else {
                throw KitError("APP_NOT_RUNNING", "Open iPhoneKit first. Its local API token has not been created.")
            }
            token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (32...128).contains(token.utf8.count) else { throw KitError("INVALID_TOKEN", "The local API token is invalid.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 80
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func dispatch(_ data: Data) {
        sequence += 1
        let number = sequence
        tasks[number] = Task { @MainActor in
            defer { tasks.removeValue(forKey: number) }
            await handle(data, overloaded: tasks.count > 16)
        }
    }

    func finish() async { for task in Array(tasks.values) { await task.value } }

    private func emit(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed]) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    private func result(_ id: Any, _ value: Any) { emit(["jsonrpc": "2.0", "id": id, "result": value]) }
    private func error(_ id: Any, _ code: Int, _ message: String) {
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func handle(_ data: Data, overloaded: Bool) async {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error(NSNull(), -32700, "Parse error."); return
        }
        let id = request["id"]
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            error(id ?? NSNull(), -32600, "Invalid JSON-RPC request."); return
        }
        if method.hasPrefix("notifications/") { return }
        guard let id, id is String || id is NSNumber else { return }
        guard !overloaded else { error(id, -32000, "Too many pending requests."); return }
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            let offered = params["protocolVersion"] as? String ?? ""
            initialized = true
            result(id, ["protocolVersion": supported.contains(offered) ? offered : "2025-06-18",
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": "iPhoneKit", "version": "0.1.1"],
                        "instructions": "Local iPhone control. Take a screenshot before pointer actions and pass its screenshot_id; coordinates refer to that JPEG. Use portrait orientation. Input is sent, not proof of task completion: screenshot again. Typing is US-ASCII and iOS may auto-capitalise. Ask before purchases, messages, deleting data, or sharing private content."])
            return
        }
        if method == "ping" { result(id, [:]); return }
        guard initialized else { error(id, -32000, "Initialize the MCP server first."); return }
        if method == "tools/list" { result(id, ["tools": Self.tools]); return }
        guard method == "tools/call" else { error(id, -32601, "Method not found."); return }
        guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
            error(id, -32602, "Unknown tool."); return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            if name == "list_phones" {
                result(id, try content(try await self.request(path: "/v1/phones"))); return
            }
            guard let phoneID = arguments["phone_id"] as? String, !phoneID.isEmpty,
                  let encodedID = phoneID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw KitError("PHONE_REQUIRED", "phone_id is required; obtain it from list_phones.")
            }
            let prefix = "/v1/phones/" + encodedID
            if name == "get_phone_status" { result(id, try content(try await self.request(path: prefix + "/status"))); return }
            if name == "set_keep_awake" {
                guard let enabled = arguments["enabled"] as? Bool else { throw KitError("INVALID_KEEP_AWAKE", "enabled must be true or false.") }
                result(id, try content(try await self.request(path: prefix + "/keep-awake", body: ["enabled": enabled]))); return
            }
            if name == "screenshot" {
                let payload = try await self.request(path: prefix + "/screenshot")
                guard let jpeg = payload["jpeg"] as? String else { throw KitError("INVALID_SCREENSHOT", "The app returned no screenshot image.") }
                var metadata = payload
                metadata.removeValue(forKey: "jpeg")
                metadata["screenshot_id"] = metadata["id"]
                let text = String(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
                result(id, ["content": [["type": "image", "mimeType": "image/jpeg", "data": jpeg], ["type": "text", "text": text]]]); return
            }
            let endpoints = ["tap": "tap", "double_tap": "double-tap", "triple_tap": "triple-tap", "long_press": "tap-and-hold",
                             "flick": "flick", "drag": "drag", "hold_and_drag": "hold-and-drag", "type_text": "type-text",
                             "press_key": "press-key", "press_home": "press-home", "wake": "wake", "cancel_action": "cancel"]
            var body = arguments
            body.removeValue(forKey: "phone_id")
            if body["idempotency_key"] == nil {
                body["idempotency_key"] = sessionID + ":" + String(describing: id)
            }
            result(id, try content(try await self.request(path: prefix + "/" + endpoints[name]!, body: body)))
        } catch {
            result(id, ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
        }
    }

    private func request(path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base) else { throw KitError("INVALID_URL", "Invalid local API endpoint.") }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw KitError("APP_NOT_RUNNING", "Cannot reach iPhoneKit. Open the Mac app and check its local API status.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KitError("INVALID_RESPONSE", "Invalid response from the Mac app.") }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = object["detail"] as? [String: Any]
            throw KitError(detail?["error"] as? String ?? "API_ERROR", detail?["message"] as? String ?? "Local API request failed.")
        }
        return object
    }

    private func content(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    static var tools: [[String: Any]] {
        let phone: [String: Any] = ["type": "string", "description": "Phone ID from list_phones."]
        let screenshot: [String: Any] = ["type": "string", "description": "id from the screenshot whose pixel coordinates you use."]
        let number: [String: Any] = ["type": "number", "minimum": 0]
        func tool(_ name: String, _ description: String, _ extra: [String: Any] = [:], _ required: [String] = [], readOnly: Bool = false) -> [String: Any] {
            var properties: [String: Any] = name == "list_phones" ? [:] : ["phone_id": phone]
            properties.merge(extra) { _, new in new }
            return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties,
                    "required": (name == "list_phones" ? [] : ["phone_id"]) + required, "additionalProperties": false],
                    "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": false]]
        }
        let point: [String: Any] = ["x": number, "y": number, "screenshot_id": screenshot]
        let pointRequired = ["x", "y", "screenshot_id"]
        var drag: [String: Any] = ["from_x": number, "from_y": number, "to_x": number, "to_y": number,
                                  "screenshot_id": screenshot, "speed": ["type": "string", "enum": ["slow", "medium", "fast"]]]
        let dragRequired = ["from_x", "from_y", "to_x", "to_y", "screenshot_id"]
        var holdPoint = point
        holdPoint["duration"] = ["type": "number", "minimum": 100, "maximum": 10000, "description": "Milliseconds, default 1000."]
        var flick = point
        flick["direction"] = ["type": "string", "enum": ["up", "down", "left", "right"]]
        let basicDrag = drag
        drag["hold_duration_ms"] = ["type": "number", "minimum": 100, "maximum": 10000]
        return [
            tool("list_phones", "List USB-connected phones and their setup status.", readOnly: true),
            tool("get_phone_status", "Get connection and screen status.", readOnly: true),
            tool("screenshot", "Get a JPEG and screenshot_id. Use its pixel space in subsequent pointer actions.", readOnly: true),
            tool("tap", "Tap a point, then screenshot to verify.", point, pointRequired),
            tool("double_tap", "Double tap a point.", point, pointRequired),
            tool("triple_tap", "Triple tap a point.", point, pointRequired),
            tool("long_press", "Press and hold a point.", holdPoint, pointRequired),
            tool("flick", "Flick in a direction with scroll momentum.", flick, pointRequired + ["direction"]),
            tool("drag", "Drag between two points.", basicDrag, dragRequired),
            tool("hold_and_drag", "Long press, then drag.", drag, dragRequired),
            tool("type_text", "Type US-ASCII in the focused field; verify capitalization on screen.", ["text": ["type": "string", "minLength": 1, "maxLength": 1000]], ["text"]),
            tool("press_key", "Press a keyboard key, optionally with modifiers.", ["key": ["type": "string"],
                 "modifiers": ["type": "array", "items": ["type": "string", "enum": ["control", "shift", "alternate", "command"]]],
                 "repeat_count": ["type": "integer", "minimum": 1, "maximum": 100]], ["key"]),
            tool("press_home", "Go to the Home Screen."),
            tool("wake", "Wake an iPhone whose cable remains attached but whose USB data paused during sleep. This sends a harmless modifier-only key; unlock manually if iOS remains locked."),
            tool("set_keep_awake", "Enable or disable a 20-second modifier-only pulse that prevents idle Auto-Lock while iPhoneKit runs. Explicitly disable it when unattended access is no longer needed.", ["enabled": ["type": "boolean"]], ["enabled"]),
            tool("cancel_action", "Cancel queued actions and release held keys/buttons."),
        ]
    }
}

@main
struct BridgeMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--help") {
            print("iphonekit-mcp — stdio MCP bridge. Open iPhoneKit first. Optional IPHONEKIT_PORT and IPHONEKIT_API_KEY environment variables.")
            return
        }
        do {
            let bridge = try MCPBridge()
            var line = Data()
            for try await byte in FileHandle.standardInput.bytes {
                if byte == 10 {
                    if !line.isEmpty { bridge.dispatch(line); line.removeAll(keepingCapacity: true) }
                } else {
                    line.append(byte)
                    guard line.count <= 1_048_576 else { throw KitError("MESSAGE_TOO_LARGE", "MCP input line exceeds 1 MiB.") }
                }
            }
            if !line.isEmpty { bridge.dispatch(line) }
            await bridge.finish()
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
