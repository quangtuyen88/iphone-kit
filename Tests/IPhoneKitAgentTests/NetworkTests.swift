import Foundation
import Network
import Testing
import IPhoneKitCore
@testable import IPhoneKitAgent

private actor SpyTransport: ProviderTransport {
    var requests: [URLRequest] = []
    let response: ProviderHTTPResponse
    init(content: String, status: Int = 200) throws {
        response = ProviderHTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]))
    }
    func post(_ request: URLRequest, maximumBytes: Int) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return response
    }
}

private func testScreenshot() -> Screenshot {
    Screenshot(phoneID: "private-device-id", epoch: 5, width: 621, height: 1344, nativeWidth: 1170, nativeHeight: 2532,
               capturedAt: Date(), jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]))
}

@Test func constructionDoesNotSendScreenshotsOrCredentials() async throws {
    let transport = try SpyTransport(content: #"{"kind":"done","message":"verified"}"#)
    let client = try OpenAIVisionClient(configuration: ProviderConfiguration(baseURL: "https://example.com/v1", model: "vision"), apiKey: "test-secret", transport: transport)
    #expect(await transport.requests.isEmpty)
    let history = (0..<12).map { AgentHistoryItem(action: "action-\($0)", outcome: "sent") }
    #expect(try await client.nextStep(goal: "task", screenshot: testScreenshot(), history: history) == .done("verified"))
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
    let data = try #require(request.httpBody)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("test-secret"))
    #expect(!text.contains("private-device-id"))
    #expect(!text.contains("action-0"))
    #expect(text.contains("action-11"))
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(content.filter { $0["type"] as? String == "image_url" }.count == 1)
}

@Test func providerErrorsDoNotEchoUntrustedBodies() async throws {
    let transport = try SpyTransport(content: "echoed private key", status: 401)
    let client = try OpenAIVisionClient(configuration: ProviderConfiguration(baseURL: "https://example.com/v1", model: "vision"), transport: transport)
    do { _ = try await client.nextStep(goal: "task", screenshot: testScreenshot(), history: []); Issue.record("Expected provider error") }
    catch { #expect((error as? KitError)?.code == "PROVIDER_HTTP_ERROR"); #expect(!error.localizedDescription.contains("private key")) }
}

@MainActor private final class HTTPFixture {
    private let listener: NWListener
    private let response: Data
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    private(set) var ready = false
    private(set) var accepted = 0
    init(response: Data) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; self?.ready = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                accepted += 1
                connections.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
        }
    }
    func start() async throws {
        listener.start(queue: .main)
        let deadline = ContinuousClock.now + .seconds(2)
        while !ready {
            guard ContinuousClock.now < deadline else { throw KitError("TEST_TIMEOUT", "Listener not ready.") }
            await Task.yield()
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

@Test @MainActor func realRedirectsNeverReachSecondHost() async throws {
    let recipient = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8))
    try await recipient.start()
    defer { recipient.stop() }
    for status in [301, 302, 303, 307, 308] {
        let wire = "HTTP/1.1 \(status) Redirect\r\nLocation: http://127.0.0.1:\(recipient.port)/sink\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let source = try HTTPFixture(response: Data(wire.utf8))
        try await source.start()
        let transport = BoundedProviderTransport()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(source.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer test-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("private-screenshot-fixture".utf8)
        do { _ = try await transport.post(request, maximumBytes: 1024); Issue.record("Expected redirect rejection") }
        catch { #expect((error as? KitError)?.code == "PROVIDER_REDIRECT_BLOCKED") }
        #expect(source.accepted == 1)
        #expect(recipient.accepted == 0)
        source.stop(); transport.cancel()
    }
}

@Test @MainActor func unknownLengthResponseIsBoundedWhileStreaming() async throws {
    let wire = Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8) + Data(repeating: 65, count: 4096)
    let source = try HTTPFixture(response: wire)
    try await source.start()
    defer { source.stop() }
    let transport = BoundedProviderTransport()
    defer { transport.cancel() }
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(source.port)/test")!)
    do { _ = try await transport.post(request, maximumBytes: 128); Issue.record("Expected response bound") }
    catch { #expect((error as? KitError)?.code == "PROVIDER_RESPONSE_TOO_LARGE") }
}
