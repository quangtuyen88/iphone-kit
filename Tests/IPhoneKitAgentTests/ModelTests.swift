import Foundation
import Testing
import IPhoneKitCore
@testable import IPhoneKitAgent

@Test func providerURLBoundary() throws {
    for url in ["https://api.openai.com/v1", "HTTPS://example.com/v1", "http://localhost:1234/v1", "http://127.0.0.1:1234/v1", "http://[::1]:1234/v1"] {
        #expect(try ProviderConfiguration(baseURL: url, model: "vision").endpoint().path.hasSuffix("chat/completions"))
    }
    for url in ["http://example.com/v1", "http://localhost.evil.com", "http://127.0.0.1.nip.io", "http://127.1", "http://2130706433", "http://0.0.0.0", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#x", "file:///tmp/x"] {
        #expect(throws: KitError.self) { try ProviderConfiguration(baseURL: url, model: "vision").endpoint() }
    }
    #expect(throws: KitError.self) { try ProviderConfiguration(baseURL: "https://example.com/v1", model: "").endpoint() }
}

@Test func credentialsScopedToNormalizedOrigin() throws {
    let a = ProviderConfiguration(baseURL: "https://EXAMPLE.com/v1", model: "a")
    let b = ProviderConfiguration(baseURL: "https://example.com:443/api", model: "b")
    #expect(try a.credentialAccount() == b.credentialAccount())
    #expect(try a.credentialAccount() != ProviderConfiguration(baseURL: "https://example.com:8443/v1", model: "a").credentialAccount())
    #expect(try ProviderConfiguration(baseURL: "http://localhost:1234/v1", model: "a").credentialAccount() != ProviderConfiguration(baseURL: "http://localhost:1235/v1", model: "a").credentialAccount())
}

@Test func untrustedModelCannotSupplyTargetingMetadata() throws {
    let valid = #"{"kind":"action","reason":"Open list","command":{"action":"tap","x":1,"y":2}}"#
    if case .action(let command, _) = try AgentStep.parse(valid) { #expect(command.screenshotID == nil) }
    else { Issue.record("Expected action") }
    for field in ["phone_id", "screenshot_id", "epoch", "idempotency_key", "deadline"] {
        let invalid = "{\"kind\":\"action\",\"reason\":\"x\",\"command\":{\"action\":\"tap\",\"x\":1,\"y\":2,\"\(field)\":\"forged\"}}"
        #expect(throws: KitError.self) { try AgentStep.parse(invalid) }
    }
    for text in ["null", "fenced json", #"{"kind":"done","message":"ok","command":{}}"#, #"{"kind":"action","reason":"x","command":{"action":"unknown"}}"#] {
        #expect(throws: KitError.self) { try AgentStep.parse(text) }
    }
}

@Test func approvalEscapesInvisibleControls() {
    #expect(CommandPresentation.escaped("abc\n\u{202E}def") == "abc\\u{000A}\\u{202E}def")
}

@Test func approvalCommandEscapesBidiText() {
    let shown = CommandPresentation.text(PhoneCommand(action: .typeText, text: "abc\u{202E}def"))
    #expect(!shown.contains("\u{202E}"))
    #expect(shown.contains("\\u{202E}"))
}
