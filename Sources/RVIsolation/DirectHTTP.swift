import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// One synchronous request. The status is the first response; redirects are not followed.
public enum DirectHTTP {
    public enum Outcome: Sendable {
        case status(Int)
        case failed(String)
    }

    public static func send(_ request: URLRequest) -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = NoRedirects()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let outcome = Mutex<Outcome?>(nil)
        session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                outcome.withLock { $0 = .status(http.statusCode) }
            } else if let error {
                outcome.withLock { $0 = .failed(error.localizedDescription) }
            }
            done.signal()
        }.resume()
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        guard done.wait(timeout: .now() + timeout) == .success else { return .failed("no response") }
        return outcome.withLock { $0 } ?? .failed("no response")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
