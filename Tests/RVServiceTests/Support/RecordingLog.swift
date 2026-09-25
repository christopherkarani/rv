import Synchronization

@testable import RVService

final class RecordingLog: ServiceLog, Sendable {
    private let box = Mutex<[ServiceLogEvent]>([])

    func record(_ event: ServiceLogEvent) {
        box.withLock { $0.append(event) }
    }

    var snapshot: [ServiceLogEvent] { box.withLock { $0 } }
}
