import Foundation
import Network

/// The local HTTP control API's transport: an `NWListener` bound to `127.0.0.1` only (never the
/// network), handing each connection's request to `APIRouter`. Off by default — start/stop are
/// driven by `AppSettings.apiEnabled`/`apiPort` (see `AppDelegate`).
public final class APIServer {
    private let coordinator: DrawSessionCoordinator
    private let queue = DispatchQueue(label: "io.mcdev.tapink.api")
    private var listener: NWListener?

    public init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
    }

    public func start(port: Int) {
        stop()
        guard let portValue = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            NSLog("TapInk: invalid API port \(port)")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // This is what actually makes the server local-only, not just an assumption: it
        // constrains the bind address, not merely the port.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        // The port is already fully specified via `requiredLocalEndpoint` above — passing it
        // again via `NWListener(using:on:)` makes Network.framework refuse to bind at all
        // ("Local endpoint has port set, cannot override"), so the plain `using:` initializer
        // is required here, not the `on:`-taking one.
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            NSLog("TapInk: failed to start API server on port \(port): \(error)")
            return
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
        listener = newListener
        NSLog("TapInk: API server listening on 127.0.0.1:\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// One request per connection: read until `HTTPRequest.parse` has enough bytes (it returns
    /// `nil` for "keep receiving"), respond, then close. No keep-alive/pipelining — see
    /// `HTTPRequest`'s doc comment for why that's a deliberate simplification here.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let request = HTTPRequest.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        Task { @MainActor [coordinator] in
            let router = APIRouter(coordinator: coordinator)
            let response = await router.handle(request)
            connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
