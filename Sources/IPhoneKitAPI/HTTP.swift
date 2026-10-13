import Foundation
import IPhoneKitCore

struct HTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

struct HTTPFailure: Error, Sendable {
    let status: Int
    let message: String
}

struct HTTPParser {
    static let maxHeader = 8192
    static let maxBody = 65536

    static func parse(_ bytes: Data) throws -> HTTPRequest? {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > maxHeader { throw HTTPFailure(status: 431, message: "Request headers too large.") }
            return nil
        }
        guard separator.lowerBound <= maxHeader,
              let head = String(data: bytes.prefix(separator.lowerBound), encoding: .utf8) else {
            throw HTTPFailure(status: 400, message: "Invalid request headers.")
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 65 else { throw HTTPFailure(status: 400, message: "Invalid HTTP request.") }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1", requestLine[1].hasPrefix("/"), !requestLine[1].hasPrefix("//"),
              !requestLine[1].contains("#"), requestLine[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw HTTPFailure(status: 400, message: "Only origin-form HTTP/1.1 requests are supported.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(status: 400, message: "Malformed header.") }
            let rawName = line[..<colon]
            guard !rawName.isEmpty, rawName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw HTTPFailure(status: 400, message: "Invalid header name.")
            }
            let name = rawName.lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil, value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else {
                throw HTTPFailure(status: 400, message: "Duplicate or invalid header.")
            }
            headers[name] = value
        }
        guard headers["host"] != nil else { throw HTTPFailure(status: 400, message: "Host is required.") }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw HTTPFailure(status: 400, message: "Chunked or Expect requests are not supported.")
        }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength), length <= maxBody else {
            throw HTTPFailure(status: 413, message: "Invalid or oversized body.")
        }
        let total = separator.upperBound + length
        guard bytes.count <= total else { throw HTTPFailure(status: 400, message: "HTTP pipelining is not supported.") }
        guard bytes.count == total else { return nil }
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers,
                           body: Data(bytes[separator.upperBound..<total]))
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    let body: Data
    let contentType: String
    init(status: Int = 200, body: Data, contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, body: try KitJSON.encoder().encode(value))
    }
    static func error(_ code: String, _ message: String, status: Int) -> HTTPResponse {
        struct Envelope: Encodable { struct Detail: Encodable { let error: String; let message: String }; let detail: Detail }
        let data = (try? KitJSON.encoder().encode(Envelope(detail: .init(error: code, message: message)))) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }
    func wire() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable", 504: "Gateway Timeout"]
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

func constantTimeEqual(_ first: String, _ second: String) -> Bool {
    let a = Array(first.utf8), b = Array(second.utf8)
    var difference = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
        difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
    }
    return difference == 0
}
