#if canImport(SwiftUI) && canImport(AppKit) && canImport(XPC)
import AppKit
import Foundation
import RVCLI
import RVDomain
import RVGlance
import RVGlanceUI
import RVIPC
import RVPolicy
import SwiftUI

/// rv in the menu bar (K1, Glyph and Glance): the diamond and the Glance
/// popover. No Dock icon. It reads rvd's live events and the pending list;
/// it holds no key and can't answer an ask or loosen a rule.
@main
struct RVMenuApplication: App {
    @State private var model = GlanceModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Intents get their own read-only reader and no freeze until rvd has the verb.
        GlanceIntentEnvironment.services = GlanceIntentServices(reader: GlanceReader(wire: XPCGlanceWire())) {
            GlancePosture(config: GuardConfig.read(home: HomeDirectory.process()))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            GlancePopover(state: model.state, now: model.now, calendar: model.calendar) {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            GlanceMenuLabel(glyph: model.glyph, waiting: model.state.pending.count)
                .task { startOnce() }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func startOnce() {
        guard !Self.started else { return }
        Self.started = true
        let reader = GlanceReader(wire: XPCGlanceWire())
        model.start(reader: reader) {
            GlancePosture(config: GuardConfig.read(home: HomeDirectory.process()))
        }
    }

    @MainActor private static var started = false
}

/// The diamond, plus the count of waiting asks beside it.
struct GlanceMenuLabel: View {
    let glyph: GlanceGlyph
    let waiting: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: GlanceGlyphImage.make(glyph))
            if glyph == .needsYou, waiting > 0 {
                Text("\(waiting)").monospacedDigit()
            }
        }
        .accessibilityLabel(Text(waiting > 0 ? "rv: \(glyph.title), \(waiting) waiting" : "rv: \(glyph.title)"))
    }
}

/// rvd's XPC transport, on a long-poll channel of its own so a parked
/// `events` poll never holds the connection a pending read uses.
struct XPCGlanceWire: GlanceWire {
    private let transport: any ServiceTransport

    init() {
        transport = XPCServiceTransport(connectTimeoutMs: 500, requestTimeoutMs: 2_000).longPollChannel()
    }

    func hello() async throws -> Bool {
        try await transport.hello(clientSemver: ProtocolVersion.serviceSemver).status == .ok
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        try await transport.send(body, timeoutMs: timeoutMs)
    }

    func invalidate() {
        transport.invalidate()
    }
}
#else
import Foundation

@main
struct RVMenuApplication {
    static func main() {
        FileHandle.standardError.write(Data("rv-menu requires macOS\n".utf8))
        exit(1)
    }
}
#endif
