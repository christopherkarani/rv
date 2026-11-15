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
final class URLSessionStreamingTransport: @unchecked Sendable {
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
        // Each request's handler blocks until a callback here signals it; on
        // GCD's shared pool those callbacks could wait behind the very
        // handlers waiting for them.
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
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: urlRequest)
        delegate.register(task, sink: sink, done: done)
        task.resume()
        done.wait()
    }
}

/// The session's delegate: finds each callback's request by its task.
final class URLSessionStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange {
        /// Held so the key, the task's identity, cannot be reused meanwhile.
        let task: URLSessionTask
        let sink: SecretResponseSink
        let done: DispatchSemaphore
    }

    private let lock = NSLock()
    private var exchanges: [ObjectIdentifier: Exchange] = [:]

    func register(_ task: URLSessionTask, sink: SecretResponseSink, done: DispatchSemaphore) {
        lock.lock()
        exchanges[ObjectIdentifier(task)] = Exchange(task: task, sink: sink, done: done)
        lock.unlock()
    }

    private func sink(for task: URLSessionTask) -> SecretResponseSink? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[ObjectIdentifier(task)]?.sink
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
        guard let http = response as? HTTPURLResponse, let sink = sink(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        }
        sink.head(status: http.statusCode, headers: headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sink(for: dataTask) else { return }
        if sink.body(data) == false { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = exchanges.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.sink.fail(error.localizedDescription)
        } else {
            entry.sink.finish()
        }
        entry.done.signal()
    }
}
