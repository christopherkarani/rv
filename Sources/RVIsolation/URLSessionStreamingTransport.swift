import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession upstream with streaming delivery, no cookies, cache, or redirects.
///
/// Each request in flight has a session of its own, with its own serial
/// delegate queue, so a callback that waits holds up only its own request.
/// Callbacks are keyed by their task object, which no other session could
/// share: a session made on first use was once made by every caller racing
/// to be first, and one request's answer reached another request's sink.
///
/// The sink runs on the thread that called `send`, never on a delegate
/// queue. What the upstream has sent and the sink has not yet taken waits
/// in memory, bounded by `Limits`.
///
/// Darwin's session stops reading from the upstream while its delegate's
/// callback has not returned, so there the callback waits whenever more than
/// `Limits.handoff` bytes wait for the sink: the upstream is slowed to the
/// client's pace instead of cut off. Idle sessions are kept for later
/// requests, so sequential requests still reuse connections.
///
/// corelibs-foundation goes on reading while a callback waits, queuing what
/// arrives without bound, so on Linux nothing waits and a request whose
/// reader falls further behind than `perRequest`, or behind others' backlog
/// past `total`, fails: its sink hears `fail`, never `finish`. A Linux
/// session serves one request and is then invalidated: libcurl sends a
/// request again, on a new connection, when a reused connection drops
/// before an answer, and without its body, which then hung its slot.
///
/// Tasks are never suspended. corelibs-foundation's `suspend` drops the
/// transfer and its `resume` sends the request again, credential and all.
/// Darwin's session goes on reading a suspended task, so it bounded nothing,
/// and it held more memory while suspended: 16 stalled 64 MiB answers
/// peaked at 311 MiB resident with it, 91 MiB without.
final class URLSessionStreamingTransport: @unchecked Sendable {
    /// How many bytes may wait for sinks before a callback waits or a request fails.
    struct Limits: Sendable {
        /// Waiting for one sink; past this its request fails.
        var perRequest = 64 << 20
        /// Waiting for all sinks together, beyond the first `exempt` bytes
        /// of each; past this the request holding the most fails.
        var total = Self.defaultTotal
        /// Bytes of each request not counted toward `total`, so a request
        /// keeping up is never failed for others' backlog.
        var exempt = 1 << 20
        /// When set, a callback bringing more waits while more than this
        /// waits for the sink; one body of any size is always taken.
        var handoff: Int? = Self.defaultHandoff
        /// Whether a session that served a request cleanly serves another.
        var reuseSessions = Self.defaultReuse

        #if canImport(Darwin)
        static let defaultTotal = Int.max
        static let defaultHandoff: Int? = 256 << 10
        static let defaultReuse = true
        #else
        static let defaultTotal = 256 << 20
        static let defaultHandoff: Int? = nil
        static let defaultReuse = false
        #endif
    }

    /// Idle sessions kept for reuse, at most the gateway's connection cap.
    static let idleSessions = 64

    let limits: Limits
    let budget: URLSessionStreamingBudget
    private let lock = NSLock()
    private var idle: [URLSessionStreamingSession] = []
    private var made = 0
    private var invalidated = 0

    /// Test seam: the most bytes that have waited for sinks at once.
    var peakQueuedBytes: Int { budget.peak }

    /// Test seam: sessions made, and sessions made but not yet invalidated.
    var sessionCounts: (made: Int, live: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (made, made - invalidated)
    }

    init(limits: Limits = Limits()) {
        self.limits = limits
        budget = URLSessionStreamingBudget(limits)
    }

    /// An idle session holds its delegate until it is invalidated. Every
    /// `send` holds the transport, so none is in flight here.
    deinit {
        for session in idle { session.session.invalidateAndCancel() }
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
        let session = take()
        let exchange = URLSessionStreamingExchange(
            task: session.session.dataTask(with: urlRequest), budget: budget, handoff: limits.handoff)
        session.delegate.register(exchange)
        exchange.task.resume()
        let clean = exchange.deliver(to: sink)
        give(session, clean: clean)
    }

    private func take() -> URLSessionStreamingSession {
        lock.lock()
        if let session = idle.popLast() {
            lock.unlock()
            return session
        }
        made += 1
        lock.unlock()
        return URLSessionStreamingSession { [weak self] in self?.noteInvalidated() }
    }

    /// Keeps a session that served its request to the end, with nothing
    /// cancelled or refused; invalidates any other.
    private func give(_ session: URLSessionStreamingSession, clean: Bool) {
        lock.lock()
        if clean, limits.reuseSessions, idle.count < Self.idleSessions {
            idle.append(session)
            lock.unlock()
            return
        }
        lock.unlock()
        session.session.invalidateAndCancel()
    }

    private func noteInvalidated() {
        lock.lock()
        invalidated += 1
        lock.unlock()
    }
}

/// One URLSession with its own delegate and serial delegate queue.
final class URLSessionStreamingSession: @unchecked Sendable {
    let session: URLSession
    let delegate: URLSessionStreamingDelegate

    init(onInvalidated: @escaping @Sendable () -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let delegate = URLSessionStreamingDelegate(onInvalidated: onInvalidated)
        self.delegate = delegate
        // The caller blocks until a callback here reaches it; on GCD's
        // shared pool those callbacks could wait behind the very callers
        // waiting for them.
        session = URLSession(
            configuration: configuration, delegate: delegate,
            delegateQueue: URLSessionDelegateQueue.serial("rv.secrets.gateway.upstream"))
    }
}

/// Bytes waiting for sinks, across every request of one transport.
final class URLSessionStreamingBudget: @unchecked Sendable {
    enum Admission {
        case taken
        /// Past `perRequest`, or the asker holds the most of a full `total`.
        case refused
        /// `total` is full and this other request holds the most: it fails
        /// first, and the asker asks again.
        case evict(URLSessionStreamingExchange)
    }

    private struct Holder {
        weak var exchange: URLSessionStreamingExchange?
        var bytes = 0
        /// Already named to fail; never named again.
        var evicted = false
    }

    let limits: URLSessionStreamingTransport.Limits
    private let lock = NSLock()
    private var holders: [ObjectIdentifier: Holder] = [:]
    private var queued = 0
    /// Sum over requests of what each holds beyond `limits.exempt`.
    private var counted = 0
    private var peakQueued = 0

    init(_ limits: URLSessionStreamingTransport.Limits) {
        self.limits = limits
    }

    /// Takes `count` more bytes for `exchange`, or says who should fail.
    func admit(_ count: Int, for exchange: URLSessionStreamingExchange) -> Admission {
        let key = ObjectIdentifier(exchange)
        lock.lock()
        defer { lock.unlock() }
        let held = holders[key]?.bytes ?? 0
        guard held + count <= limits.perRequest else { return .refused }
        let more = excess(held + count) - excess(held)
        if more <= limits.total - counted {
            counted += more
            queued += count
            peakQueued = max(peakQueued, queued)
            holders[key, default: Holder(exchange: exchange)].bytes = held + count
            return .taken
        }
        let largest = holders.filter { $0.key != key && $0.value.evicted == false && $0.value.exchange != nil }
            .max { $0.value.bytes < $1.value.bytes }
        guard let largest, largest.value.bytes > held + count, let victim = largest.value.exchange else {
            return .refused
        }
        holders[largest.key]?.evicted = true
        return .evict(victim)
    }

    /// Gives back `count` of the bytes `exchange` had taken.
    func release(_ count: Int, for exchange: URLSessionStreamingExchange) {
        guard count > 0 else { return }
        let key = ObjectIdentifier(exchange)
        lock.lock()
        defer { lock.unlock() }
        let held = holders[key]?.bytes ?? 0
        let given = min(count, held)
        counted -= excess(held) - excess(held - given)
        queued -= given
        if held - given == 0 {
            holders[key] = nil
        } else {
            holders[key]?.bytes = held - given
        }
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
/// in order, one at a time, on the caller's thread.
final class URLSessionStreamingExchange: @unchecked Sendable {
    enum Event {
        case head(status: Int, headers: [(name: String, value: String)])
        case body(Data)
        case finish
        case fail(String)
    }

    /// The most of one body handed to the sink at once.
    static let slice = 256 << 10

    /// Held so the delegate's key, the task's identity, cannot be reused meanwhile.
    let task: URLSessionDataTask
    private let budget: URLSessionStreamingBudget
    private let handoff: Int?
    private let condition = NSCondition()
    private var events: [Event] = []
    /// Index of the next event to hand over; earlier slots are spent.
    private var next = 0
    /// Admitted to the budget and not yet given back: queued, or being handed to the sink.
    private var queuedBytes = 0
    /// Bodies are no longer taken: the sink refused one, or the request overflowed.
    private var dropping = false
    private var overflowed = false

    init(task: URLSessionDataTask, budget: URLSessionStreamingBudget, handoff: Int?) {
        self.task = task
        self.budget = budget
        self.handoff = handoff
    }

    var overflowReason: String {
        "the client fell too far behind the upstream: more than \(budget.limits.perRequest >> 20) MiB "
            + "waited for it, or it held the most when more than \(budget.limits.total >> 20) MiB "
            + "waited for all clients"
    }

    /// From the delegate queue. With a `handoff`, a body waits there while
    /// more than that waits for the sink; otherwise nothing waits.
    func push(_ event: Event) {
        var cancel = false
        condition.lock()
        switch event {
        case .head:
            append(event)
        case .body(let data):
            cancel = takeBody(data)
            // Queued first, so a blocked callback holds no second body.
            if let handoff {
                while dropping == false, queuedBytes > handoff { condition.wait() }
            }
        case .finish, .fail:
            append(overflowed ? .fail(overflowReason) : event)
        }
        condition.unlock()
        if cancel { task.cancel() }
    }

    /// Under the lock: admits a body, failing whoever the budget names.
    /// True when this request overflowed and its task is to be cancelled.
    private func takeBody(_ data: Data) -> Bool {
        while dropping == false {
            switch budget.admit(data.count, for: self) {
            case .taken:
                queuedBytes += data.count
                append(.body(data))
                return false
            case .refused:
                return overflow()
            case .evict(let victim):
                // Never two exchanges' locks at once.
                condition.unlock()
                victim.evicted()
                condition.lock()
            }
        }
        return false
    }

    /// The budget named this request as holding the most of a full total.
    func evicted() {
        condition.lock()
        let cancel = overflow()
        condition.unlock()
        if cancel { task.cancel() }
    }

    /// Under the lock: fails the request with `overflowReason`. True when
    /// it had not failed already; the caller then cancels the task, outside
    /// the lock.
    private func overflow() -> Bool {
        guard dropping == false else { return false }
        overflowed = true
        stopTaking()
        // Another request's body can name this one after its upstream has
        // finished: the end already queued must not finish a cut answer.
        for index in events.indices {
            if case .finish = events[index] { events[index] = .fail(overflowReason) }
        }
        return true
    }

    private func append(_ event: Event) {
        events.append(event)
        condition.broadcast()
    }

    /// Returns once the sink has been finished or failed: true when it was
    /// finished with every body taken. A sink that refuses a body has its
    /// task cancelled and hears nothing more until the task's own end; so
    /// does an overflowed request, whose sink then hears `fail`.
    func deliver(to sink: SecretResponseSink) -> Bool {
        defer { releaseAll() }
        var refused = false
        while true {
            switch take() {
            case .head(let status, let headers):
                if refused == false { sink.head(status: status, headers: headers) }
            case .body(let data):
                // Darwin hands over up to 4 MiB at once; in slices, the sink
                // copies a slice at a time and the callback waiting on this
                // body resumes before its last bytes are written.
                var start = data.startIndex
                while start < data.endIndex {
                    let end = data.index(start, offsetBy: Self.slice, limitedBy: data.endIndex) ?? data.endIndex
                    if refused == false, sink.body(data[start..<end]) == false {
                        refused = true
                        condition.lock()
                        stopTaking()
                        condition.unlock()
                        task.cancel()
                    }
                    delivered(end - start)
                    start = end
                }
            case .finish:
                sink.finish()
                return refused == false
            case .fail(let reason):
                sink.fail(reason)
                return false
            }
        }
    }

    /// The next event, its slot emptied so a delivered body is freed with it.
    private func take() -> Event {
        condition.lock()
        defer { condition.unlock() }
        while next == events.count { condition.wait() }
        let event = events[next]
        events[next] = .finish
        next += 1
        if next == events.count {
            events.removeAll(keepingCapacity: true)
            next = 0
        } else if next >= 1_024, next * 2 >= events.count {
            events.removeFirst(next)
            next = 0
        }
        return event
    }

    /// Under the lock: takes no more bodies and gives back those queued.
    private func stopTaking() {
        dropping = true
        var kept: [Event] = []
        for event in events[next...] {
            if case .body(let data) = event {
                budget.release(data.count, for: self)
                queuedBytes -= data.count
            } else {
                kept.append(event)
            }
        }
        events = kept
        next = 0
        condition.broadcast()
    }

    private func delivered(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        budget.release(count, for: self)
        queuedBytes -= count
        condition.broadcast()
    }

    private func releaseAll() {
        condition.lock()
        budget.release(queuedBytes, for: self)
        queuedBytes = 0
        condition.unlock()
    }
}

/// A session's delegate: finds each callback's request by its task.
final class URLSessionStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [ObjectIdentifier: URLSessionStreamingExchange] = [:]
    private let onInvalidated: @Sendable () -> Void

    init(onInvalidated: @escaping @Sendable () -> Void = {}) {
        self.onInvalidated = onInvalidated
    }

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

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        onInvalidated()
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
