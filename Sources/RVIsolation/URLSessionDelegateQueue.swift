import Foundation

package enum URLSessionDelegateQueue {
    /// A serial URLSession delegate queue on a dispatch queue of its own. By
    /// default an `OperationQueue` runs on GCD's shared global queues, whose
    /// threads a busy process can all hold: the request still went out, but
    /// its answer waited for one of them, as long as they were held (measured
    /// on macOS and on Linux). A queue made with a label is served even then.
    package static func serial(_ label: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // Retained by the operation queue (the property is "assign, actually retain").
        let underlying = DispatchQueue(label: label)
        queue.underlyingQueue = underlying
        return queue
    }
}
