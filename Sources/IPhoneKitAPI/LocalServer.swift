import Foundation
@preconcurrency import Network
import IPhoneKitCore

@MainActor
public final class LocalServer {
    public private(set) var port: UInt16
    public private(set) var isRunning = false
    public private(set) var failure: String?
    private let listener: NWListener
    private let router: APIRouter
    private var peers: [UUID: HTTPPeer] = [:]

    public init(controller: any PhoneControlling, port: UInt16 = 8766, token: String) throws {
        guard (32...128).contains(token.utf8.count), let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw KitError("INVALID_SERVER_CONFIG", "Use a 32–128 byte API token and a valid port.")
        }
        self.port = port
        router = APIRouter(controller: controller, token: token)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }

    public func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    port = listener.port?.rawValue ?? port
                    isRunning = true
                case .failed(let error):
                    failure = "Local API unavailable: \(error.localizedDescription)"
                    isRunning = false
                case .cancelled: isRunning = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 128 else { connection.cancel(); return }
        let id = UUID()
        let peer = HTTPPeer(connection: connection, route: { [weak self] request in
            guard let self else { return .error("SERVER_STOPPED", "The Mac app is not running.", status: 503) }
            return await router.handle(request, port: port)
        }, ended: { [weak self] in self?.peers.removeValue(forKey: id) })
        peers[id] = peer
        peer.start()
    }

    public func stop() {
        listener.cancel()
        for peer in Array(peers.values) { peer.close() }
        peers.removeAll()
        isRunning = false
    }
}

@MainActor
private final class HTTPPeer {
    private let connection: NWConnection
    private let route: @MainActor (HTTPRequest) async -> HTTPResponse
    private let ended: @MainActor () -> Void
    private var bytes = Data()
    private var timer: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var closed = false
    init(connection: NWConnection, route: @escaping @MainActor (HTTPRequest) async -> HTTPResponse, ended: @escaping @MainActor () -> Void) {
        self.connection = connection; self.route = route; self.ended = ended
    }
    func start() {
        connection.start(queue: .main)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.close()
        }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in self?.received(data, complete: complete, failed: error != nil) }
        }
    }
    private func received(_ data: Data?, complete: Bool, failed: Bool) {
        guard !closed else { return }
        if let data { bytes.append(data) }
        do {
            if let request = try HTTPParser.parse(bytes) {
                bytes.removeAll()
                timer?.cancel()
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    self?.close()
                }
                operation = Task { [weak self] in
                    guard let self else { return }
                    let response = await route(request)
                    send(response)
                }
            } else if complete || failed { close() }
            else { receive() }
        } catch let error as HTTPFailure {
            send(.error("INVALID_HTTP", error.message, status: error.status))
        } catch { send(.error("INVALID_HTTP", "Invalid request.", status: 400)) }
    }
    private func send(_ response: HTTPResponse) {
        guard !closed else { return }
        connection.send(content: response.wire(), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        operation?.cancel()
        connection.cancel()
        ended()
    }
}
