import Foundation
import RVDomain
import Synchronization

/// Dials the address already stored on an authorized HTTPS GET.
///
/// The contained process is not given a socket. This type does not choose
/// policy. A name is not resolved again here.
enum HTTPDirectExecutor {
    static func perform(
        _ action: HTTPAction,
        cancellation: HTTPCancellation,
        shouldStop: @escaping @Sendable () -> Bool
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        #if os(macOS)
        return openAndExchange(action, cancellation: cancellation, shouldStop: shouldStop)
        #else
        _ = action
        _ = cancellation
        _ = shouldStop
        return .failure(.notOpened(.unavailable))
        #endif
    }
}

#if os(macOS)
import Network
import Security

/// Values copied into `NWParameters` for one direct TLS connection.
struct HTTPTransportConfiguration: Equatable {
    var preferNoProxies: Bool
    var includePeerToPeer: Bool
    var minimumTLS12: Bool
    var alpn: [String]
    var serverName: String
    var peer: String
    var port: Int
    var usesURLSession: Bool
    var sendsAmbientCredentials: Bool
}

enum DirectHTTPConnection {
    static func configuration(
        address: HTTPIPAddress,
        port: Int,
        serverName: String
    ) -> HTTPTransportConfiguration {
        HTTPTransportConfiguration(
            preferNoProxies: true,
            includePeerToPeer: false,
            minimumTLS12: true,
            alpn: ["http/1.1"],
            serverName: serverName,
            peer: address.presentation,
            port: port,
            usesURLSession: false,
            sendsAmbientCredentials: false
        )
    }

    static func makeParameters(_ configuration: HTTPTransportConfiguration) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        configuration.serverName.withCString { name in
            sec_protocol_options_set_tls_server_name(security, name)
        }
        if configuration.minimumTLS12 {
            sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        }
        for proto in configuration.alpn {
            proto.withCString { name in
                sec_protocol_options_add_tls_application_protocol(security, name)
            }
        }
        let parameters = NWParameters(tls: tls)
        parameters.preferNoProxies = configuration.preferNoProxies
        parameters.includePeerToPeer = configuration.includePeerToPeer
        return parameters
    }

    static func endpoint(address: HTTPIPAddress, port: Int) -> NWEndpoint? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        switch address.family {
        case .ipv4:
            guard address.bytes.count == 4, let ip = IPv4Address(Data(address.bytes)) else {
                return nil
            }
            return .hostPort(host: .ipv4(ip), port: nwPort)
        case .ipv6:
            guard address.bytes.count == 16, let ip = IPv6Address(Data(address.bytes)) else {
                return nil
            }
            return .hostPort(host: .ipv6(ip), port: nwPort)
        }
    }

    /// True only when the connected path is still the address we authorized.
    static func peerMatches(_ endpoint: NWEndpoint?, address: HTTPIPAddress, port: Int) -> Bool {
        guard case .hostPort(let host, let endpointPort) = endpoint else { return false }
        guard Int(endpointPort.rawValue) == port else { return false }
        switch host {
        case .ipv4(let peer):
            return Array(peer.rawValue) == address.bytes
        case .ipv6(let peer):
            return Array(peer.rawValue) == address.bytes
        case .name:
            return false
        @unknown default:
            return false
        }
    }
}

private func openAndExchange(
    _ action: HTTPAction,
    cancellation: HTTPCancellation,
    shouldStop: @escaping @Sendable () -> Bool
) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
    guard action.destination.isPublicPinned, let address = action.destination.address else {
        return .failure(.notOpened(.forbiddenDestination))
    }
    if shouldStop() || cancellation.isCancelled {
        return .failure(.notOpened(.cancelled))
    }
    let deadline = Date().addingTimeInterval(
        TimeInterval(HTTPEgressLimits.requestTimeoutMilliseconds) / 1_000
    )
    let connectDeadline = min(
        deadline,
        Date().addingTimeInterval(TimeInterval(HTTPEgressLimits.connectTimeoutMilliseconds) / 1_000)
    )
    let configuration = DirectHTTPConnection.configuration(
        address: address,
        port: action.destination.port,
        serverName: action.destination.host
    )
    guard configuration.preferNoProxies, configuration.sendsAmbientCredentials == false,
        configuration.usesURLSession == false,
        let endpoint = DirectHTTPConnection.endpoint(address: address, port: action.destination.port)
    else {
        return .failure(.notOpened(.unavailable))
    }
    switch PinnedTLSConnection.open(
        endpoint: endpoint,
        parameters: DirectHTTPConnection.makeParameters(configuration),
        address: address,
        port: action.destination.port,
        deadline: connectDeadline,
        shouldStop: shouldStop
    ) {
    case .failure(let failure):
        return .failure(failure)
    case .success(let transfer):
        return HTTPExchange.perform(
            destination: action.destination,
            transfer: transfer,
            deadline: deadline,
            shouldStop: shouldStop
        )
    }
}

private final class PinnedTLSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "rv.http.direct")
    private let lock = NSLock()
    private var stopped = false
    private var inbound = Data()
    private var ended = false
    private var failed = false
    private var waiter: (() -> Void)?

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    static func open(
        endpoint: NWEndpoint,
        parameters: NWParameters,
        address: HTTPIPAddress,
        port: Int,
        deadline: Date,
        shouldStop: @escaping @Sendable () -> Bool
    ) -> Result<HTTPTransfer, HTTPEgressFailure> {
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "rv.http.connect")
        let state = ConnectState()
        connection.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.finish(.ready)
            case .failed:
                state.finish(.failed)
            case .cancelled:
                state.finish(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
        while Date() < deadline {
            if shouldStop() {
                connection.cancel()
                return .failure(.opened(.cancelled))
            }
            if let ready = state.poll() {
                switch ready {
                case .ready:
                    guard DirectHTTPConnection.peerMatches(
                        connection.currentPath?.remoteEndpoint,
                        address: address,
                        port: port
                    ) else {
                        connection.cancel()
                        return .failure(.opened(.transport))
                    }
                    let pinned = PinnedTLSConnection(connection)
                    pinned.startReceive()
                    return .success(pinned.transfer())
                case .failed:
                    connection.cancel()
                    return .failure(.opened(.transport))
                case .cancelled:
                    return .failure(.opened(.cancelled))
                }
            }
            usleep(UInt32(HTTPEgressLimits.readSliceMilliseconds) * 1_000)
        }
        connection.cancel()
        return .failure(.opened(.timedOut))
    }

    func transfer() -> HTTPTransfer {
        HTTPTransfer(
            write: { [self] data in
                self.write(data)
            },
            read: { [self] maximum, wait in
                self.read(maximumBytes: maximum, waitMilliseconds: wait)
            },
            stop: { [self] in
                self.stop()
            }
        )
    }

    private func write(_ data: Data) -> Result<Void, HTTPTransferFault> {
        if stopped { return .failure(.failed) }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Mutex(false)
        connection.send(content: data, completion: .contentProcessed { error in
            outcome.withLock { $0 = error == nil }
            semaphore.signal()
        })
        semaphore.wait()
        return outcome.withLock { $0 } ? .success(()) : .failure(.failed)
    }

    private func read(maximumBytes: Int, waitMilliseconds: Int) -> Result<HTTPTransferRead, HTTPTransferFault> {
        let deadline = Date().addingTimeInterval(TimeInterval(waitMilliseconds) / 1_000)
        while Date() < deadline {
            let next = lock.withLock { () -> HTTPTransferRead? in
                if failed { return nil }
                if inbound.isEmpty == false {
                    let count = min(maximumBytes, inbound.count)
                    let chunk = inbound.prefix(count)
                    inbound.removeFirst(count)
                    return .bytes(Data(chunk))
                }
                if ended { return .end }
                return .waiting
            }
            if failed { return .failure(.failed) }
            if let next, case .waiting = next {
                usleep(1_000)
                continue
            }
            if let next { return .success(next) }
        }
        return .success(.waiting)
    }

    private func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        connection.cancel()
    }

    private func startReceive() {
        receiveMore()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data, data.isEmpty == false {
                self.inbound.append(data)
            }
            if error != nil {
                self.failed = true
            }
            if isComplete {
                self.ended = true
            }
            let keepGoing = self.stopped == false && self.failed == false && self.ended == false
            self.lock.unlock()
            if keepGoing {
                self.receiveMore()
            }
        }
    }
}

private final class ConnectState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConnectValue?

    func finish(_ value: ConnectValue) {
        lock.lock()
        if self.value == nil {
            self.value = value
        }
        lock.unlock()
    }

    func poll() -> ConnectValue? {
        lock.lock()
        let value = self.value
        lock.unlock()
        return value
    }
}

private enum ConnectValue {
    case ready
    case failed
    case cancelled
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
#endif
