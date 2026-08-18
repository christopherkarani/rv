import Foundation

@objc public protocol RVEvaluateXPC {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public final class XPCConnectionSession: NSObject, RVEvaluateXPC, @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let lock = NSLock()
    private var handshakeOK = false

    public init(runtime: ServiceRuntime) {
        self.runtime = runtime
        super.init()
    }

    public func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let accepted = lock.withLock { handshakeOK }
        let replyBox = UncheckedReply(reply: reply)
        Task {
            let (data, ok) = await runtime.handleIncoming(request, handshakeOK: accepted)
            self.lock.withLock { self.handshakeOK = ok }
            replyBox.send(data)
        }
    }
}

struct UncheckedReply: @unchecked Sendable {
    let reply: (Data) -> Void
    func send(_ data: Data) { reply(data) }
}

public final class XPCEvaluateListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let listener: NSXPCListener

    public init(runtime: ServiceRuntime, machServiceName: String = RVService.machServiceName) {
        self.runtime = runtime
        self.listener = NSXPCListener(machServiceName: machServiceName)
        super.init()
        listener.delegate = self
    }

    public func start() {
        listener.resume()
    }

    public func stop() {
        listener.invalidate()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: RVEvaluateXPC.self)
        newConnection.exportedObject = XPCConnectionSession(runtime: runtime)
        newConnection.resume()
        return true
    }
}
