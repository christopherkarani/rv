#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Synchronization
import Testing
import RVGlance
@testable import RVGlanceUI

/// A stopped menu bar posts nothing it planned before the stop.
@MainActor
struct GlanceModelDeliveryTests {
    private final class Recorder: GlanceNoticeSink, Sendable {
        let delivered = Mutex<[[GlanceNoticeAction]]>([])
        func deliver(_ actions: [GlanceNoticeAction]) async {
            delivered.withLock { $0.append(actions) }
        }
        var all: [[GlanceNoticeAction]] { delivered.withLock { $0 } }
    }

    private let banner = GlanceNoticeAction.remove(["rv.ask.claude"])
    private let down = GlanceNoticeAction.remove(["rv.rvd-down"])

    /// Waits (up to 2 s) until `recorder` holds `count` deliveries.
    private func settle(_ recorder: Recorder, count: Int) async {
        for _ in 0..<200 where recorder.all.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func queuedDeliveriesAreDroppedOnStop() async {
        let recorder = Recorder()
        let model = GlanceModel()
        model.notices = recorder
        model.notify([banner])
        model.notify([banner])
        model.stop()
        // Planned after the stop, so it is delivered; it also proves the
        // dropped links ahead of it have finished.
        model.notify([down])
        await settle(recorder, count: 1)
        #expect(recorder.all == [[down]])
        withExtendedLifetime(model) {}
    }

    @Test func deliveriesRunInOrderWhileRunning() async {
        let recorder = Recorder()
        let model = GlanceModel()
        model.notices = recorder
        model.notify([banner])
        model.notify([down])
        await settle(recorder, count: 2)
        #expect(recorder.all == [[banner], [down]])
        withExtendedLifetime(model) {}
    }
}
#endif
