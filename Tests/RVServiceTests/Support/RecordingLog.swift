@testable import RVService

final class RecordingLog: ServiceLog, @unchecked Sendable {
    nonisolated(unsafe) private var events: [ServiceLogEvent] = []

    func record(_ event: ServiceLogEvent) {
        events.append(event)
    }

    var snapshot: [ServiceLogEvent] { events }
}
