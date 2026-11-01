import Dispatch
import Foundation

/// A provider's current value for a gateway entry, plus the expiry now on file.
public struct SecretRefreshed: Sendable {
    public var value: SecretValue
    public var fingerprint: String?
    public var expires: Date?

    public init(value: SecretValue, fingerprint: String?, expires: Date?) {
        self.value = value
        self.fingerprint = fingerprint
        self.expires = expires
    }
}

/// How a gateway entry's value stays current while its runtime lives.
///
/// Past `interval` the next request starts a refresh in the background and
/// is served the current value. Past twice the interval (the grace) a
/// request waits for a refresh and is refused if it fails. A `probe` marker
/// that differs from the last one (a Keychain item's modification date)
/// makes the next request wait for a refresh, so `rv secrets set` reaches
/// running sessions without a restart.
public struct SecretRefreshPolicy: Sendable {
    /// Nil refreshes only when the probe reports a change.
    public var interval: TimeInterval?
    /// The probe's marker when the launch value was read.
    public var marker: String?
    public var probe: (@Sendable () -> String?)?
    public var resolve: @Sendable () -> Result<SecretRefreshed, SecretResolutionError>

    public init(
        interval: TimeInterval?, marker: String? = nil, probe: (@Sendable () -> String?)? = nil,
        resolve: @escaping @Sendable () -> Result<SecretRefreshed, SecretResolutionError>
    ) {
        self.interval = interval
        self.marker = marker
        self.probe = probe
        self.resolve = resolve
    }
}

/// One refresh in progress. Every request that needs it waits on the same one.
final class SecretRefreshFlight: Sendable {
    private let group = DispatchGroup()

    init() { group.enter() }

    func finish() { group.leave() }

    func wait() { group.wait() }
}

struct SecretRotationState: Sendable {
    enum Step: Equatable {
        case serve
        /// Serve the current value and refresh behind it.
        case background
        /// Refresh before serving.
        case wait
        case refuse
    }

    /// Last successful resolve.
    var resolvedAt: Date
    /// Last failed refresh since `resolvedAt`.
    var failedAt: Date?
    var probedAt: Date?
    var marker: String?
    var flight: SecretRefreshFlight?

    /// What a request at `now` must do for an entry refreshed every `interval`.
    /// A failure is retried no sooner than a quarter interval later.
    func step(now: Date, interval: TimeInterval) -> Step {
        let age = now.timeIntervalSince(resolvedAt)
        guard age >= interval else { return .serve }
        let retry = failedAt.map { now.timeIntervalSince($0) >= interval / 4 } ?? true
        if age < interval * 2 { return retry && flight == nil ? .background : .serve }
        return retry || flight != nil ? .wait : .refuse
    }
}

extension SecretGateway {
    /// Previous values kept for the response scrubber, as OpenShell keeps 8 generations.
    static let historyDepth = 8
    /// The probe is cheap but runs on the request path, so at most this often per entry.
    static let probeSpacing: TimeInterval = 2

    /// Applies rotation and expiry for one request about to use `token`.
    /// Nil lets it through, with the entry's value as current as the policy requires.
    func prepare(_ token: String) -> GatewayRefusal? {
        if probeChanged(token) {
            refresh(token, restart: true)
        }
        lock.lock()
        let interval = entries[token]?.refresh?.interval
        let step = interval.flatMap { entries[token]?.rotation?.step(now: now(), interval: $0) } ?? .serve
        lock.unlock()
        switch step {
        case .serve:
            break
        case .background:
            lock.lock()
            _ = beginRefresh(token)
            lock.unlock()
        case .refuse:
            return .refreshFailed
        case .wait:
            refresh(token, restart: false)
            lock.lock()
            let after = interval.flatMap { entries[token]?.rotation?.step(now: now(), interval: $0) }
            lock.unlock()
            if after == .wait || after == .refuse { return .refreshFailed }
        }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token] else { return .unknownPlaceholder }
        if let expires = entry.expires, now() >= expires { return .expired }
        return nil
    }

    /// True when the probe, if due, reports a marker other than the last one.
    private func probeChanged(_ token: String) -> Bool {
        let at = now()
        lock.lock()
        guard let probe = entries[token]?.refresh?.probe, let state = entries[token]?.rotation,
            state.probedAt.map({ at.timeIntervalSince($0) >= Self.probeSpacing }) ?? true
        else {
            lock.unlock()
            return false
        }
        entries[token]?.rotation?.probedAt = at
        lock.unlock()
        let marker = probe()
        lock.lock()
        defer { lock.unlock() }
        guard entries[token]?.rotation != nil, entries[token]?.rotation?.marker != marker else { return false }
        // Recorded before the refresh, so a failed read is not retried until the next change.
        entries[token]?.rotation?.marker = marker
        return true
    }

    /// Runs or joins this entry's refresh and waits for it. With `restart`, a
    /// refresh already running may have read the value before the change, so
    /// a new one follows it.
    private func refresh(_ token: String, restart: Bool) {
        if restart {
            lock.lock()
            let running = entries[token]?.rotation?.flight
            lock.unlock()
            running?.wait()
        }
        lock.lock()
        let flight = beginRefresh(token)
        lock.unlock()
        flight?.wait()
    }

    /// The running refresh, or a new one. Caller holds `lock`.
    private func beginRefresh(_ token: String) -> SecretRefreshFlight? {
        guard let refresh = entries[token]?.refresh, let state = entries[token]?.rotation else { return nil }
        if let running = state.flight { return running }
        let flight = SecretRefreshFlight()
        entries[token]?.rotation?.flight = flight
        DispatchQueue.global(qos: .userInitiated).async {
            self.finishRefresh(token, result: refresh.resolve(), flight: flight)
        }
        return flight
    }

    private func finishRefresh(
        _ token: String, result: Result<SecretRefreshed, SecretResolutionError>, flight: SecretRefreshFlight
    ) {
        defer { flight.finish() }
        let at = now()
        lock.lock()
        // Revoked, or stopped and re-registered, while the provider was read.
        guard var entry = entries[token], entry.rotation?.flight === flight else {
            lock.unlock()
            return
        }
        entry.rotation?.flight = nil
        var record: (activity: SecretGatewayActivity, reason: String)?
        switch result {
        case .success(let refreshed):
            if refreshed.value != entry.value {
                entry.previous = Array(([entry.value] + entry.previous).prefix(Self.historyDepth))
                entry.value = refreshed.value
                entry.generation += 1
                record = (.refreshed, "value rotated from the provider (generation \(entry.generation))")
            }
            entry.fingerprint = refreshed.fingerprint
            entry.expires = refreshed.expires
            entry.rotation?.resolvedAt = at
            entry.rotation?.failedAt = nil
        case .failure(let error):
            entry.rotation?.failedAt = at
            record = (.refreshFailed, "refresh failed: \(error.message)")
        }
        entries[token] = entry
        lock.unlock()
        guard let record else { return }
        _ = audit(SecretUseRecord(
            secret: entry.secret, runtime: entry.runtime, upstreamHost: entry.upstream.host, method: "", path: "",
            status: 0, upstreamStatus: nil, activity: record.activity, refusal: nil, reason: record.reason,
            surfaces: [], fingerprint: entry.fingerprint, responseBytes: 0, durationMilliseconds: 0, stage: .complete))
    }
}
