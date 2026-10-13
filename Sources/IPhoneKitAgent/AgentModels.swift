import Foundation
import IPhoneKitCore

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public init(baseURL: String, model: String) { self.baseURL = baseURL; self.model = model }
    public func endpoint() throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased(), !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true, let url = parts.url, url.host != nil else {
            throw KitError("INVALID_PROVIDER_URL", "Enter a base URL without credentials, query, or fragment, such as https://api.openai.com/v1.")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            throw KitError("INSECURE_PROVIDER_URL", "Use HTTPS. Plain HTTP is allowed only for literal localhost, 127.0.0.1, or ::1.")
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128, !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw KitError("INVALID_MODEL", "Enter the provider's vision-capable model name.")
        }
        return url.appendingPathComponent("chat/completions")
    }
    public func credentialAccount() throws -> String {
        let url = try endpoint()
        let scheme = url.scheme!.lowercased()
        return "\(scheme)://\(url.host!.lowercased()):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

public struct AgentHistoryItem: Sendable, Equatable {
    public let action: String
    public let outcome: String
    public init(action: String, outcome: String) { self.action = action; self.outcome = outcome }
}

public enum AgentStep: Sendable, Equatable {
    case action(PhoneCommand, reason: String)
    case done(String)
    case ask(String)
    public static func parse(_ content: String) throws -> AgentStep {
        guard content.utf8.count <= 16_384, let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = object["kind"] as? String else {
            throw KitError("INVALID_MODEL_REPLY", "The model must return a single JSON action, done, or ask object.")
        }
        func message(_ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty, value.utf8.count <= 4096 else {
                throw KitError("INVALID_MODEL_REPLY", "The model returned an empty or oversized message.")
            }
            return value
        }
        if kind == "done" || kind == "ask" {
            guard Set(object.keys) == ["kind", "message"] else { throw KitError("INVALID_MODEL_REPLY", "Unexpected model reply fields.") }
            let text = try message("message")
            return kind == "done" ? .done(text) : .ask(text)
        }
        guard kind == "action", Set(object.keys) == ["kind", "reason", "command"], let fields = object["command"] as? [String: Any] else {
            throw KitError("INVALID_MODEL_REPLY", "The model returned an unknown or mixed action.")
        }
        let allowed: Set<String> = ["action", "x", "y", "from_x", "from_y", "to_x", "to_y", "duration", "hold_duration_ms", "direction", "speed", "text", "key", "modifiers", "repeat_count"]
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw KitError("INVALID_MODEL_REPLY", "The model may not supply device, screenshot, deadline, or execution identifiers.")
        }
        let command: PhoneCommand
        do { command = try KitJSON.decoder().decode(PhoneCommand.self, from: JSONSerialization.data(withJSONObject: fields)) }
        catch { throw KitError("INVALID_MODEL_REPLY", "The model returned invalid action fields.") }
        guard command.action != .release else { throw KitError("INVALID_MODEL_REPLY", "Release is managed by the host.") }
        return .action(command, reason: try message("reason"))
    }
}

public protocol VisionPlanning: Sendable {
    func nextStep(goal: String, screenshot: Screenshot, history: [AgentHistoryItem]) async throws -> AgentStep
    func cancel()
}
public extension VisionPlanning { func cancel() {} }

public struct OfflineDemoPlanner: VisionPlanning {
    public init() {}
    public func nextStep(goal: String, screenshot: Screenshot, history: [AgentHistoryItem]) async throws -> AgentStep {
        try Task.checkCancellation()
        if history.isEmpty {
            return .action(PhoneCommand(action: .tap, x: Double(screenshot.width) * 0.13, y: Double(screenshot.height) * 0.28),
                           reason: "Demo: check the first reminder. This does not touch your real phone.")
        }
        return .done("Demo complete: captured the screen, sent one approved action, and checked the screen again. No network or real-phone input occurred.")
    }
}

public enum CommandPresentation {
    public static func text(_ command: PhoneCommand) -> String {
        var copy = command
        copy.screenshotID = nil; copy.idempotencyKey = nil; copy.deadline = nil
        let value = (try? String(decoding: KitJSON.encoder().encode(copy), as: UTF8.self)) ?? command.action.rawValue
        return escaped(value)
    }
    public static func escaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            if scalar.value < 32 || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}
