import Foundation

public enum AnalyticsDecisionKind: String, Sendable, Equatable {
    case allow
    case deny
    case indeterminate
}

struct AnalyticsCounterState: Sendable, Equatable, Codable {
    var allowCount: Int
    var denyCount: Int
    var indeterminateCount: Int
    var lastFlushDay: String
    var enabledPackIDs: [String]
    var hosts: [String: String]

    static let empty = AnalyticsCounterState(
        allowCount: 0,
        denyCount: 0,
        indeterminateCount: 0,
        lastFlushDay: "",
        enabledPackIDs: [],
        hosts: [:]
    )
}

public actor AnalyticsCoordinator {
    private let paths: AnalyticsPaths
    private let preferences: AnalyticsPreferences
    private let identity: AnalyticsIdentity
    private let sink: any AnalyticsSink
    private let productVersion: String
    private let platform: PlatformSnapshot
    private var state: AnalyticsCounterState
    private var installSent: Bool

    public init(
        paths: AnalyticsPaths,
        preferences: AnalyticsPreferences,
        identity: AnalyticsIdentity,
        sink: any AnalyticsSink,
        productVersion: String,
        platform: PlatformSnapshot
    ) {
        self.paths = paths
        self.preferences = preferences
        self.identity = identity
        self.sink = sink
        self.productVersion = productVersion
        self.platform = platform
        self.state = Self.loadState(paths: paths)
        self.installSent = FileManager.default.fileExists(atPath: paths.installSentFile.path)
        if state.hosts.isEmpty {
            state.hosts = Self.loadHosts(paths: paths)
        }
    }

    public var isEnabled: Bool { preferences.isEnabled }

    public func recordDecision(_ kind: AnalyticsDecisionKind) {
        guard preferences.isEnabled else { return }
        switch kind {
        case .allow: state.allowCount += 1
        case .deny: state.denyCount += 1
        case .indeterminate: state.indeterminateCount += 1
        }
        persistState()
    }

    public func noteEnabledPacks(_ ids: [String]) {
        guard preferences.isEnabled else { return }
        state.enabledPackIDs = ids.sorted()
        persistState()
    }

    public func noteHosts(_ hosts: [String: String]) {
        guard preferences.isEnabled else { return }
        state.hosts = hosts
        persistHosts(hosts)
        persistState()
    }

    public func captureInstall(hosts: [String: String]) async {
        guard preferences.isEnabled else { return }
        guard installSent == false else {
            noteHosts(hosts)
            return
        }
        noteHosts(hosts)
        let delivered = await sink.capture(
            makePayload(event: AnalyticsPayload.installEvent, extra: [:])
        )
        guard delivered else { return }
        installSent = true
        try? Data("1".utf8).write(to: paths.installSentFile, options: .atomic)
    }

    /// Emits `daily_active` at most once per calendar day (local), then resets counters.
    /// On transport failure, counters are kept and the day is still stamped so rvd does
    /// not retry on every evaluate; residual counts ride the next successful flush day.
    public func flushDailyIfNeeded(now: Date = Date()) async {
        guard preferences.isEnabled else { return }
        let day = Self.dayString(now)
        guard state.lastFlushDay != day else { return }
        var extra: [String: AnalyticsPropertyValue] = [
            "allow_count": .int(state.allowCount),
            "deny_count": .int(state.denyCount),
            "indeterminate_count": .int(state.indeterminateCount),
            "enabled_packs": .strings(state.enabledPackIDs),
        ]
        for (host, status) in state.hosts {
            extra["host_\(host)"] = .string(status)
        }
        let delivered = await sink.capture(
            makePayload(event: AnalyticsPayload.dailyActiveEvent, extra: extra)
        )
        state.lastFlushDay = day
        if delivered {
            state.allowCount = 0
            state.denyCount = 0
            state.indeterminateCount = 0
        }
        persistState()
    }

    private func makePayload(
        event: String,
        extra: [String: AnalyticsPropertyValue]
    ) -> AnalyticsPayload {
        var properties: [String: AnalyticsPropertyValue] = [
            "rv_version": .string(productVersion),
            "macos_version": .string(platform.macosVersion),
            "macos_build": .string(platform.macosBuild),
        ]
        for (key, value) in extra {
            properties[key] = value
        }
        return AnalyticsPayload(
            event: event,
            distinctID: identity.distinctID,
            properties: properties
        )
    }

    private func persistState() {
        try? FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: paths.countersFile, options: .atomic)
    }

    private func persistHosts(_ hosts: [String: String]) {
        try? FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(hosts),
              let data = try? JSONSerialization.data(withJSONObject: hosts)
        else { return }
        try? data.write(to: paths.hostsFile, options: .atomic)
    }

    private static func loadState(paths: AnalyticsPaths) -> AnalyticsCounterState {
        guard let data = FileManager.default.contents(atPath: paths.countersFile.path),
              let decoded = try? JSONDecoder().decode(AnalyticsCounterState.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    private static func loadHosts(paths: AnalyticsPaths) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: paths.hostsFile.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return [:]
        }
        return object
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum AnalyticsBootstrap {
    /// Live coordinator for setup / rvd. Returns nil when HOME is missing or analytics is opted out.
    public static func live(
        productVersion: String,
        sink: (any AnalyticsSink)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AnalyticsCoordinator? {
        guard let paths = AnalyticsPaths.liveFromEnvironment(environment: environment) else {
            return nil
        }
        let preferences = AnalyticsPreferences.load(from: paths)
        guard preferences.isEnabled else {
            return nil
        }
        let identity: AnalyticsIdentity
        do {
            identity = try AnalyticsIdentity.loadOrCreate(in: paths)
        } catch {
            return nil
        }
        let resolvedSink: any AnalyticsSink
        if let sink {
            resolvedSink = sink
        } else {
            let key = AnalyticsCredentials.apiKey(environment: environment)
            if key.isEmpty {
                resolvedSink = NoOpAnalyticsSink()
            } else {
                resolvedSink = PostHogSink(
                    apiKey: key,
                    host: AnalyticsCredentials.host(environment: environment),
                    poster: URLSessionHTTPPoster()
                )
            }
        }
        return AnalyticsCoordinator(
            paths: paths,
            preferences: preferences,
            identity: identity,
            sink: resolvedSink,
            productVersion: productVersion,
            platform: .live()
        )
    }
}
