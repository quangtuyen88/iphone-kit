import Foundation
import Testing
import IPhoneKitCore
@testable import IPhoneKitAPI

private let testToken = "test-only-token-01234567890123456789"

@Test func incrementalHTTPFraming() throws {
    let head = "POST /v1/phones/demo/tap HTTP/1.1\r\nHost: localhost:8766\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n"
    #expect(try HTTPParser.parse(Data(head.utf8)) == nil)
    let parsed = try HTTPParser.parse(Data((head + "{}").utf8))
    let result = try #require(parsed)
    #expect(result.method == "POST")
    #expect(result.body == Data("{}".utf8))
}

@Test func rejectsHTTPAmbiguities() {
    for extra in ["Host: duplicate\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: -1\r\n", "Content-Length: 999999\r\n", "Content-Length: 1\r\nContent-Length: 1\r\n"] {
        let wire = "GET /health HTTP/1.1\r\nHost: localhost:8766\r\n" + extra + "\r\n"
        #expect(throws: HTTPFailure.self) { try HTTPParser.parse(Data(wire.utf8)) }
    }
    #expect(throws: HTTPFailure.self) { try HTTPParser.parse(Data("GET http://evil/ HTTP/1.1\r\nHost: localhost:8766\r\n\r\n".utf8)) }
    #expect(throws: HTTPFailure.self) { try HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHeader + 1)) }
    #expect(throws: HTTPFailure.self) { try HTTPParser.parse(Data("GET /health HTTP/1.1\r\nHost: localhost:8766\r\n\r\nGET /health HTTP/1.1\r\n\r\n".utf8)) }
}

@Test func tokenComparison() {
    #expect(constantTimeEqual(testToken, testToken))
    #expect(!constantTimeEqual(testToken, testToken + "0"))
    #expect(!constantTimeEqual(testToken, String(testToken.dropFirst())))
    #expect(!constantTimeEqual("token", "tokfn"))
}

@MainActor private func request(_ router: APIRouter, _ path: String, method: String = "GET", auth: String? = testToken,
                                headers: [String: String] = [:], object: [String: Any]? = nil) async throws -> HTTPResponse {
    var fields = ["host": "127.0.0.1:8766"]
    fields.merge(headers) { _, value in value }
    if let auth { fields["x-api-key"] = auth }
    var body = Data()
    if let object { body = try JSONSerialization.data(withJSONObject: object); fields["content-type"] = "application/json" }
    return await router.handle(HTTPRequest(method: method, target: path, headers: fields, body: body), port: 8766)
}

@Test @MainActor func localhostAuthAndOriginGates() async throws {
    let hub = PhoneHub(demo: true)
    await hub.start()
    let router = APIRouter(controller: hub, token: testToken)
    #expect(try await request(router, "/health", auth: nil).status == 200)
    #expect(try await request(router, "/v1/phones", auth: nil).status == 401)
    #expect(try await request(router, "/v1/phones", auth: "wrong").status == 401)
    #expect(try await request(router, "/v1/phones").status == 200)
    #expect(try await request(router, "/v1/phones", headers: ["origin": "null"]).status == 403)
    #expect(try await request(router, "/v1/phones", headers: ["origin": "https://evil.example"]).status == 403)
    #expect(try await request(router, "/health", headers: ["host": "evil.example:8766"]).status == 403)
    await hub.stop()
}

@Test @MainActor func screenshotCoordinateAndJobContract() async throws {
    let hub = PhoneHub(demo: true)
    await hub.start()
    let router = APIRouter(controller: hub, token: testToken)
    let shotResponse = try await request(router, "/v1/phones/demo-iphone/screenshot")
    #expect(shotResponse.status == 200)
    let shot = try KitJSON.decoder().decode(Screenshot.self, from: shotResponse.body)
    #expect(shot.height == 1344)
    let missing = try await request(router, "/v1/phones/demo-iphone/tap", method: "POST", object: ["x": 5, "y": 10])
    #expect(missing.status == 400)
    let tap = try await request(router, "/v1/phones/demo-iphone/tap", method: "POST", object: ["x": 5, "y": 10, "screenshot_id": shot.id, "idempotency_key": "test-tap"])
    #expect(tap.status == 200)
    let result = try KitJSON.decoder().decode(ActionResult.self, from: tap.body)
    #expect(result.status == "simulated")
    #expect(try await request(router, "/v1/jobs/" + result.id).status == 200)
    let replay = try await request(router, "/v1/phones/demo-iphone/tap", method: "POST", object: ["x": 5, "y": 10, "screenshot_id": shot.id, "idempotency_key": "test-tap"])
    #expect(try KitJSON.decoder().decode(ActionResult.self, from: replay.body).id == result.id)
    let unicode = try await request(router, "/v1/phones/demo-iphone/type-text", method: "POST", object: ["text": "café"])
    #expect(unicode.status == 400)
    #expect(try await request(router, "/v1/phones/missing/status").status == 404)
    #expect(try await request(router, "/v1/phones/demo-iphone/screenshot?long_edge=nope").status == 400)
    let wake = try await request(router, "/v1/phones/demo-iphone/wake", method: "POST", object: [:])
    #expect(wake.status == 200)
    #expect(try KitJSON.decoder().decode(ActionResult.self, from: wake.body).action == .wake)
    let keepAwake = try await request(router, "/v1/phones/demo-iphone/keep-awake", method: "POST", object: ["enabled": true])
    #expect(keepAwake.status == 200)
    #expect(String(decoding: keepAwake.body, as: UTF8.self).contains("\"enabled\":true"))
    let status = try await request(router, "/v1/phones/demo-iphone/status")
    #expect(try KitJSON.decoder().decode(PhoneInfo.self, from: status.body).keepAwake)
    await hub.stop()
}

@Test @MainActor func networkListenerBindsLoopback() async throws {
    let hub = PhoneHub(demo: true)
    await hub.start()
    let server = try LocalServer(controller: hub, port: 0, token: testToken)
    try server.start()
    for _ in 0..<100 {
        if server.isRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.isRunning)
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/v1/phones"))
    var request = URLRequest(url: url)
    request.setValue(testToken, forHTTPHeaderField: "X-API-Key")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("demo-iphone"))
    server.stop()
    await hub.stop()
}
