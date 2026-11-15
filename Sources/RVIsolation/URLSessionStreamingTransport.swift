import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession upstream with streaming delivery, no cookies, cache, or redirects.
///
/// One session, made with the transport. A session made on first use was
/// made once by every caller racing to be first; each numbered its tasks
/// from 1, so one request's answer could reach another request's sink and
/// the others waited forever. Requests are keyed by their task object,
/// which no second session could share.
///
/// The sink runs on the thread that called `send`, never on the session's
/// one delegate queue: a sink that blocks, writing to a client that does not
/// read, holds up only its own request. While more than `highWater` bytes
/// wait for a sink its task is suspended, so a slow reader is not buffered
/// without bound.
final class URLSessionStreamingTransport: @unchecked Sendable {
    /// Bytes queued for one sink before its task is suspended.
    static let highWater = 1 << 20

    private let delegate: URLSessionStreamingDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let delegate = URLSessionStreamingDelegate()
        self.delegate = delegate
        // Each request's caller blocks until a callback here reaches it; on
        // GCD's shared pool those callbacks could wait behind the very
        // callers waiting for them.
        session = URLSession(
            configuration: configuration, delegate: delegate,
            delegateQueue: URLSessionDelegateQueue.serial("rv.secrets.gateway.upstream"))
    }

    /// The session holds its delegate until it is invalidated. Every `send`
    /// holds the transport, so none is in flight here.
    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ request: SecretUpstreamRequest, sink: SecretResponseSink) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if request.body.isEmpty == false || ["POST", "PUT", "PATCH"].contains(request.method) {
            urlRequest.httpBody = request.body
        }
        let exchange = URLSessionStreamingExchange(task: session.dataTask(with: urlRequest))
        delegate.register(exchange)
        exchange.task.resume()
        exchange.deliver(to: sink)
    }
}

/// One request's callbacks, queued by the delegate and handed to the sink
/// in order on the caller's thread.
final class URLSessionStreamingExchange: @unchecked Sendable {
    enum Event {
        case head(status: Int, headers: [(name: String, value: String)])
        case body(Data)
        case finish
        case fail(String)
    }

    /// Held so the delegate's key, the task's identity, cannot be reused meanwhile.
    let task: URLSessionDataTask
    private let condition = NSCondition()
    private var events: [Event] = []
    private var queuedBytes = 0
    private var suspended = false

    init(task: URLSessionDataTask) {
        self.task = task
    }

    /// From the delegate queue; never waits for the sink.
    func push(_ event: Event) {
        condition.lock()
        defer { condition.unlock() }
        events.append(event)
        if case .body(let data) = event {
            queuedBytes += data.count
            if queuedBytes > URLSessionStreamingTransport.highWater, suspended == false {
                suspended = true
                task.suspend()
            }
        }
        condition.signal()
    }

    /// Returns once the sink has been finished or failed. A sink that refuses
    /// a body has its task cancelled and hears nothing more until the task's
    /// own end.
    func deliver(to sink: SecretResponseSink) {
        var refused = false
        while true {
            condition.lock()
            while events.isEmpty { condition.wait() }
            let batch = events
            events = []
            queuedBytes = 0
            condition.unlock()
            for event in batch {
                switch event {
                case .head(let status, let headers):
                    if refused == false { sink.head(status: status, headers: headers) }
                case .body(let data):
                    if refused == false, sink.body(data) == false {
                        refused = true
                        task.cancel()
                    }
                case .finish:
                    sink.finish()
                    return
                case .fail(let reason):
                    sink.fail(reason)
                    return
                }
            }
            condition.lock()
            let resume = suspended && refused == false
            if resume { suspended = false }
            condition.unlock()
            if resume { task.resume() }
        }
    }
}

/// The session's delegate: finds each callback's request by its task.
final class URLSessionStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [ObjectIdentifier: URLSessionStreamingExchange] = [:]

    func register(_ exchange: URLSessionStreamingExchange) {
        lock.lock()
        exchanges[ObjectIdentifier(exchange.task)] = exchange
        lock.unlock()
    }

    private func exchange(for task: URLSessionTask) -> URLSessionStreamingExchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[ObjectIdentifier(task)]
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let exchange = exchange(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        }
        exchange.push(.head(status: http.statusCode, headers: headers))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        exchange(for: dataTask)?.push(.body(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let exchange = exchanges.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        exchange?.push(error.map { .fail($0.localizedDescription) } ?? .finish)
    }
}
