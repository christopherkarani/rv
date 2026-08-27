import Foundation
import RVAnalytics
import RVIPC
import RVPolicy
import RVPresentation

protocol InstallAnalyticsCapturing: Sendable {
    func captureInstall(hosts: [String: String])
}

struct SilentInstallAnalytics: InstallAnalyticsCapturing {
    func captureInstall(hosts: [String: String]) {}
}

struct BlockingInstallAnalytics: InstallAnalyticsCapturing {
    var timeoutSeconds: Int
    var makeCoordinator: @Sendable () -> AnalyticsCoordinator?

    init(
        timeoutSeconds: Int = 10,
        makeCoordinator: @escaping @Sendable () -> AnalyticsCoordinator?
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.makeCoordinator = makeCoordinator
    }

    static func live(
        home: HomeDirectory,
        environment: [String: String],
        productVersion: String = ProtocolVersion.serviceSemver
    ) -> BlockingInstallAnalytics {
        var environment = environment
        environment["HOME"] = home.rawValue
        let captured = environment
        return BlockingInstallAnalytics {
            AnalyticsBootstrap.live(productVersion: productVersion, environment: captured)
        }
    }

    func captureInstall(hosts: [String: String]) {
        guard let coordinator = makeCoordinator() else { return }
        let group = DispatchGroup()
        group.enter()
        Task {
            await coordinator.captureInstall(hosts: hosts)
            group.leave()
        }
        _ = group.wait(timeout: .now() + .seconds(timeoutSeconds))
    }
}

enum InstallAnalyticsHosts {
    static func from(_ slots: SetupSlotSnapshot) -> [String: String] {
        [
            "grok": status(slots.grok),
            "pi": status(slots.pi),
            "opencode": status(slots.openCode),
            "claude": status(slots.claude),
            "openclaw": status(slots.openClaw),
            "hermes": status(slots.hermes),
            "codex": status(slots.codex),
        ]
    }

    private static func status(_ kind: SetupSlotKind) -> String {
        switch kind {
        case .pending: "pending"
        case .wired: "wired"
        case .occupied: "occupied"
        }
    }
}
