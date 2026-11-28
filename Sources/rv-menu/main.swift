#if canImport(SwiftUI) && canImport(AppKit) && canImport(XPC)
import AppKit
import Foundation
import RVDomain
import RVGlance
import RVGlanceUI
import RVIPC
import RVOperatorUI
import RVPolicy
import RVXPC
import SwiftUI
import UserNotifications

/// rv in the menu bar (K1, Glyph and Glance): the diamond and the Glance
/// popover. No Dock icon. It reads rvd's live events and the pending list;
/// it holds no key and can't loosen a rule. One thing it can answer (K2):
/// a stop's allow-once code, over the operator-UI channel, after a fresh
/// Touch ID (or login password) prompt for that one answer.
@main
struct RVMenuApplication: App {
    @State private var model = GlanceModel()
    @State private var unlocks = UnlockReviewModel(
        bridge: MenuUnlockBridge(), authenticator: MenuUnlockAuthenticator())

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Intents get their own read-only reader and no freeze until rvd has the verb.
        GlanceIntentEnvironment.services = GlanceIntentServices(reader: GlanceReader(wire: XPCGlanceWire())) {
            GlancePosture(config: GuardConfig.read(home: HomeDirectory.process()))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            GlancePopover(
                state: model.state, now: model.now, calendar: model.calendar, plain: model.lastStopPlain?.text,
                unlocks: unlocks
            ) {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            GlanceMenuLabel(glyph: model.glyph, waiting: model.state.waitingCount)
                .task { startOnce() }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func startOnce() {
        guard !Self.started else { return }
        Self.started = true
        let reader = GlanceReader(wire: XPCGlanceWire())
        model.start(reader: reader, notices: UserNotificationSink()) {
            GlancePosture(config: GuardConfig.read(home: HomeDirectory.process()))
        }
        let model = model
        let unlocks = unlocks
        unlocks.onAsksChanged = { asks in model.setUnlocks(asks) }
        unlocks.start()
        UnlockBannerRouter.shared.unlocks = unlocks
        if UserNotificationSink.canNotify {
            UNUserNotificationCenter.current().delegate = UnlockBannerRouter.shared
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

/// rvd's unlock review over the operator-UI XPC client: one persistent,
/// registered connection that rvd admits only for the pinned operator UI
/// running as the owner. An unpinned build is refused and shows no asks.
struct MenuUnlockBridge: UnlockBridge {
    private let client = XPCOperatorUIClient()

    func list() async throws -> UIUnlockListDTO { try await client.unlockList() }
    func bind(codeHash: String) async throws -> UIUnlockChallengeBundleDTO {
        try await client.unlockBind(codeHash: codeHash)
    }
    func complete(_ completion: UIUnlockCompletion) async throws -> UIUnlockStatusDTO {
        try await client.unlockComplete(completion)
    }
    func release(codeHash: String) async throws -> UIUnlockStatusDTO {
        try await client.unlockRelease(codeHash: codeHash)
    }
}

/// A fresh `LAContext` per answer (`OperatorAuthenticator`, reuse 0).
struct MenuUnlockAuthenticator: UnlockAuthenticator {
    private let authenticator = OperatorAuthenticator()

    func authenticate(reason: String) async -> UIAuthenticationOutcome {
        await MainActor.run { NSApplication.shared.activate() }
        return await authenticator.authenticate(reason: reason)
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
