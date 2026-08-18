import Foundation
import Testing
@testable import RVService

struct OnceResumeTests {
    @Test func secondResumeIsIgnored() async throws {
        let value = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let once = OnceResume(cont)
            once.resume(returning: 1)
            once.resume(returning: 2)
            once.resume(throwing: XPCEvaluateClientError.connectFailed)
        }
        #expect(value == 1)
    }

    @Test func concurrentResumeDeliversExactlyOnce() async {
        let result: Result<Int, any Error> = await withCheckedContinuation { done in
            Task {
                let outcome: Result<Int, any Error>
                do {
                    let value = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                        let once = OnceResume(cont)
                        DispatchQueue.concurrentPerform(iterations: 32) { i in
                            if i.isMultiple(of: 2) {
                                once.resume(returning: 7)
                            } else {
                                once.resume(throwing: XPCEvaluateClientError.connectFailed)
                            }
                        }
                    }
                    outcome = .success(value)
                } catch {
                    outcome = .failure(error)
                }
                done.resume(returning: outcome)
            }
        }
        switch result {
        case .success(let value):
            #expect(value == 7)
        case .failure(let error):
            #expect(error is XPCEvaluateClientError)
        }
    }

    @Test func cancelBeforeInstallResumesOnce() async {
        let once = OnceResume<Int>()
        once.resume(throwing: XPCEvaluateClientError.cancelled)
        once.resume(throwing: XPCEvaluateClientError.connectFailed)
        await #expect(throws: XPCEvaluateClientError.cancelled) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                #expect(once.install(cont))
            }
        }
    }

    @Test func cancellationHandlerResumesWithoutProducer() async {
        let once = OnceResume<Data>()
        let task = Task {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    if once.install(cont) { return }
                }
            } onCancel: {
                once.resume(throwing: XPCEvaluateClientError.cancelled)
            }
        }
        task.cancel()
        await #expect(throws: XPCEvaluateClientError.cancelled) {
            try await task.value
        }
    }

    @Test func cancelledPerformDoesNotWaitForXPC() async {
        let client = XPCEvaluateClient(serviceName: "dev.rv.evaluate.once-resume-test")
        defer { client.invalidate() }
        let task = Task {
            try await client.perform(Data())
        }
        task.cancel()
        await #expect(throws: XPCEvaluateClientError.cancelled) {
            try await task.value
        }
    }

    @Test func invalidateAndOpenedCountAreSafeConcurrently() {
        let client = XPCEvaluateClient(serviceName: "dev.rv.evaluate.lock-test")
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            if i.isMultiple(of: 2) {
                client.invalidate()
            } else {
                _ = client.openedConnectionCount
            }
        }
        client.invalidate()
        #expect(client.openedConnectionCount == 0)
    }
}
