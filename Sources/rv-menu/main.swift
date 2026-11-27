#if canImport(SwiftUI) && canImport(AppKit) && canImport(XPC)
import AppKit
import Foundation
import RVDomain
import RVGlance
import RVGlanceUI
import RVIPC
import RVPolicy
import RVXPC
import SwiftUI

/// rv in the menu bar (K1, Glyph and Glance): the diamond and the Glance
/// popover. No Dock icon. It reads rvd's live events and the pending list;
/// it holds no key and can't answer an ask or loosen a rule.
@main
struct RVMenuApplication: App {
    @State private var model = GlanceModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
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

/// rvd over RVXPC's client, which proves the daemon's identity on every
/// reply. The menu bar's own connection: GlanceReader decides what it may
/// ask (events and the pending list), this only carries the bytes.
struct XPCGlanceWire: GlanceWire {
    static let helloTimeoutMs = 500
    private let client = XPCEvaluateClient()

    func hello() async throws -> Bool {
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: ProtocolVersion.serviceSemver)
        let reply = try await send(try IPCJSON.encode(hello), timeoutMs: Self.helloTimeoutMs)
        return try IPCJSON.decode(HelloAck.self, from: reply).status == .ok
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        let client = client
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await client.perform(body) }
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                throw XPCGlanceWireTimeout()
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw XPCGlanceWireTimeout() }
                return first
            } catch {
                client.invalidate()
                throw error
            }
        }
    }

    func invalidate() {
        client.invalidate()
    }
}

struct XPCGlanceWireTimeout: Error {}
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
