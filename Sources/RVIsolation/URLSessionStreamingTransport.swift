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
/// read, holds up only its own request. What the upstream has sent and the
/// sink has not yet taken waits in memory, bounded by `Limits`: a request
/// whose reader falls further behind than that fails, and its sink hears
/// `fail`, never `finish`.
///
/// On Darwin a task with more than `highWater` bytes waiting is also
/// suspended until its sink is back under `lowWater`. That only slows the
/// upstream: the session goes on delivering what it had already read, so it
/// is not the bound. Elsewhere tasks are never suspended:
/// corelibs-foundation's `suspend` drops the transfer and `resume` sends the
/// request again, with its credential.
final class URLSessionStreamingTransport: @unchecked Sendable {
    /// On Darwin, bytes waiting for one sink past which its task is suspended.
    static let highWater = 1 << 20
    /// On Darwin, bytes waiting at or under which a suspended task resumes.
    static let lowWater = highWater / 2

    /// How many bytes may wait for sinks before requests fail.
    struct Limits: Sendable {
        /// Waiting for one sink; past this its request fails.
        var perRequest = 8 << 20
        /// Waiting for all sinks together, beyond the first `exempt` bytes
        /// of each; past this the request that would add more fails.
        var total = 64 << 20
        /// Bytes of each request not counted toward `total`, so a request
        /// keeping up is never failed for others' backlog.
        var exempt = 1 << 20
    }

    private let delegate: URLSessionStreamingDelegate
    private let session: URLSession
    let budget: URLSessionStreamingBudget

    /// Test seam: the most bytes that have waited for sinks at once.
    var peakQueuedBytes: Int { budget.peak }

    init(limits: Limits = Limits()) {
        budget = URLSessionStreamingBudget(limits)
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
        let exchange = URLSessionStreamingExchange(task: session.dataTask(with: urlRequest), budget: budget)
        delegate.register(exchange)
        exchange.task.resume()
        exchange.deliver(to: sink)
    }
}

/// Bytes waiting for sinks, across every request of one transport.
final class URLSessionStreamingBudget: @unchecked Sendable {
    let limits: URLSessionStreamingTransport.Limits
    private let lock = NSLock()
    private var queued = 0
    /// Sum over requests of what each holds beyond `limits.exempt`.
    private var counted = 0
    private var peakQueued = 0

    init(_ limits: URLSessionStreamingTransport.Limits) {
        self.limits = limits
    }

    /// Takes `count` more bytes for a request already holding `held`, or
    /// refuses them when that would pass either limit.
    func admit(_ count: Int, holding held: Int) -> Bool {
        guard held + count <= limits.perRequest else { return false }
        let more = excess(held + count) - excess(held)
        lock.lock()
        defer { lock.unlock() }
        guard counted + more <= limits.total else { return false }
        counted += more
        queued += count
        peakQueued = max(peakQueued, queued)
        return true
    }

    /// Gives back `count` of the `held` bytes a request had taken.
    func release(_ count: Int, holding held: Int) {
        guard count > 0 else { return }
        let less = excess(held) - excess(held - count)
        lock.lock()
        counted -= less
        queued -= count
        lock.unlock()
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakQueued
    }

    private func excess(_ held: Int) -> Int {
        max(held - limits.exempt, 0)
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
    private let budget: URLSessionStreamingBudget
    private let condition = NSCondition()
    private var events: [Event] = []
    /// Admitted to the budget and not yet given back: queued, or being handed to the sink.
    private var queuedBytes = 0
    private var suspended = false
    /// Bodies are no longer taken: the sink refused one, or the request overflowed.
    private var dropping = false
    private var overflowed = false

    init(task: URLSessionDataTask, budget: URLSessionStreamingBudget) {
        self.task = task
        self.budget = budget
    }

    var overflowReason: String {
        "the client fell too far behind the upstream: more than \(budget.limits.perRequest >> 20) MiB "
            + "waited for it, or more than \(budget.limits.total >> 20) MiB for all clients"
    }

    /// From the delegate queue; never waits for the sink.
    func push(_ event: Event) {
        var cancel = false
        condition.lock()
        switch event {
        case .head:
            events.append(event)
        case .body(let data):
            guard dropping == false else { break }
            guard budget.admit(data.count, holding: queuedBytes) else {
                overflowed = true
                cancel = true
                stopTaking()
                break
            }
            queuedBytes += data.count
            events.append(event)
            #if canImport(Darwin)
            // Under the lock, so a resume never overtakes the suspend it undoes.
            if queuedBytes > URLSessionStreamingTransport.highWater, suspended == false {
                suspended = true
                task.suspend()
            }
            #endif
        case .finish, .fail:
            events.append(overflowed ? .fail(overflowReason) : event)
        }
        condition.signal()
        condition.unlock()
        if cancel { task.cancel() }
    }

    /// Returns once the sink has been finished or failed. A sink that refuses
    /// a body has its task cancelled and hears nothing more until the task's
    /// own end; so does an overflowed request, whose sink then hears `fail`.
    func deliver(to sink: SecretResponseSink) {
        defer { releaseAll() }
        var refused = false
        while true {
            condition.lock()
            while events.isEmpty { condition.wait() }
            let batch = events
            events = []
            condition.unlock()
            for event in batch {
                switch event {
                case .head(let status, let headers):
                    if refused == false { sink.head(status: status, headers: headers) }
                case .body(let data):
                    if refused == false, isDropping == false, sink.body(data) == false {
                        refused = true
                        condition.lock()
                        stopTaking()
                        condition.unlock()
                        task.cancel()
                    }
                    delivered(data.count)
                case .finish:
                    sink.finish()
                    return
                case .fail(let reason):
                    sink.fail(reason)
                    return
                }
            }
        }
    }

    private var isDropping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return dropping
    }

    /// Under the lock: takes no more bodies and gives back those queued.
    private func stopTaking() {
        dropping = true
        events = events.filter { event in
            guard case .body(let data) = event else { return true }
            budget.release(data.count, holding: queuedBytes)
            queuedBytes -= data.count
            return false
        }
    }

    private func delivered(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        budget.release(count, holding: queuedBytes)
        queuedBytes -= count
        #if canImport(Darwin)
        if suspended, dropping == false, queuedBytes <= URLSessionStreamingTransport.lowWater {
            suspended = false
            task.resume()
        }
        #endif
    }

    private func releaseAll() {
        condition.lock()
        budget.release(queuedBytes, holding: queuedBytes)
        queuedBytes = 0
        condition.unlock()
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
