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
    /// The interval is half the value's remaining lifetime at each resolve
    /// (capped by `interval`), so a refresh starts past half-life and a
    /// request waits for one at expiry.
    public var followsExpiry: Bool
    public var resolve: @Sendable () -> Result<SecretRefreshed, SecretResolutionError>

    public init(
        interval: TimeInterval?, marker: String? = nil, probe: (@Sendable () -> String?)? = nil,
        followsExpiry: Bool = false, resolve: @escaping @Sendable () -> Result<SecretRefreshed, SecretResolutionError>
    ) {
        self.interval = interval
        self.marker = marker
        self.probe = probe
        self.followsExpiry = followsExpiry
        self.resolve = resolve
    }
}

/// One refresh in progress. Every request that needs it waits on the same one.
final class SecretRefreshFlight: Sendable {
    private let group = DispatchGroup()

    init() { group.enter() }

    func finish() { group.leave() }

    /// True when the refresh finished within `seconds`.
    func wait(seconds: TimeInterval) -> Bool { group.wait(timeout: .now() + seconds) == .success }
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
    /// A failure is retried no sooner than a quarter interval later. With
    /// `expired`, the value is spent: no grace, the request waits for a refresh.
    func step(now: Date, interval: TimeInterval, expired: Bool = false) -> Step {
        let age = now.timeIntervalSince(resolvedAt)
        guard age >= interval || expired else { return .serve }
        let retry = failedAt.map { now.timeIntervalSince($0) >= interval / 4 } ?? true
        if age < interval * 2, expired == false { return retry && flight == nil ? .background : .serve }
        return retry || flight != nil ? .wait : .refuse
    }
}

extension SecretGateway {
    /// Previous values kept for the response scrubber, as OpenShell keeps 8 generations.
    static let historyDepth = 8
    /// The probe is cheap but runs on the request path, so at most this often per entry.
    static let probeSpacing: TimeInterval = 2
    /// Floor for a lifetime-paced interval, so a nearly spent token is not re-minted per request.
    static let minimumLifetimeInterval: TimeInterval = 15
    /// Pace for a lifetime-paced value that came without an expiry.
    static let unexpiringInterval: TimeInterval = 30 * 60

    /// The refresh interval in force for `entry` now.
    static func refreshInterval(_ entry: Entry) -> TimeInterval? {
        guard let refresh = entry.refresh else { return nil }
        guard refresh.followsExpiry else { return refresh.interval }
        guard let expires = entry.expires, let resolvedAt = entry.rotation?.resolvedAt else {
            return refresh.interval ?? unexpiringInterval
        }
        let half = max(expires.timeIntervalSince(resolvedAt) / 2, minimumLifetimeInterval)
        return min(refresh.interval ?? half, half)
    }

    /// An expired AWS entry is re-read on a request no sooner than this after the last read.
    static let expiredRetrySpacing: TimeInterval = 5
    /// How long a request waits for a refresh: the provider command timeout
    /// (30 s) plus a margin. A refresh that outlasts it counts as failed for
    /// that request, so a provider that never answers cannot pin handler
    /// threads and connection slots.
    static let refreshWaitLimit: TimeInterval = 32

    /// Applies rotation and expiry for one request about to use `token`.
    /// Nil lets it through, with the entry's value as current as the policy requires.
    func prepare(_ token: String) -> GatewayRefusal? {
        if probeChanged(token) {
            refresh(token, restart: true)
        }
        lock.lock()
        let step = rotationStep(token) ?? .serve
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
            // A refresh moves a token's expiry, and with it the interval.
            let after = rotationStep(token)
            lock.unlock()
            if after == .wait || after == .refuse { return .refreshFailed }
        }
        // Past its Expiration an AWS credential set is read again before the
        // request is refused, however long the interval has left to run.
        if expiredAndDue(token) { refresh(token, restart: false) }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token] else { return .unknownPlaceholder }
        if let expires = entry.expires, now() >= expires { return .expired }
        return nil
    }

    /// What a request now must do for `token`. Caller holds `lock`.
    /// A lifetime-paced value past its expiry is spent whatever the pacing floor
    /// says, so the request waits for a fresh one rather than being refused behind
    /// a background refresh. (AWS credentials past expiry have `expiredAndDue`.)
    private func rotationStep(_ token: String) -> SecretRotationState.Step? {
        guard let entry = entries[token], let interval = Self.refreshInterval(entry) else { return nil }
        let at = now()
        let spent = entry.refresh?.followsExpiry == true && entry.expires.map { at >= $0 } == true
        return entry.rotation?.step(now: at, interval: interval, expired: spent)
    }

    /// True for a refreshable AWS entry past its expiry that has not been read
    /// in the last `expiredRetrySpacing`, so a provider that keeps returning
    /// expired credentials is not spawned on every request.
    private func expiredAndDue(_ token: String) -> Bool {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token], entry.signing != nil, entry.refresh != nil, let expires = entry.expires,
            at >= expires, let state = entry.rotation
        else { return false }
        let last = max(state.resolvedAt, state.failedAt ?? state.resolvedAt)
        return at.timeIntervalSince(last) >= Self.expiredRetrySpacing
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
    /// Gives up after `refreshWaitLimit`; the caller's step logic then
    /// treats the entry as unrefreshed.
    private func refresh(_ token: String, restart: Bool) {
        if restart {
            lock.lock()
            let running = entries[token]?.rotation?.flight
            lock.unlock()
            if let running, !running.wait(seconds: refreshWaitLimit) { return }
        }
        lock.lock()
        let flight = beginRefresh(token)
        lock.unlock()
        _ = flight?.wait(seconds: refreshWaitLimit)
    }

    /// The running refresh, or a new one. Caller holds `lock`.
    private func beginRefresh(_ token: String) -> SecretRefreshFlight? {
        guard let refresh = entries[token]?.refresh, let state = entries[token]?.rotation else { return nil }
        if let running = state.flight { return running }
        let flight = SecretRefreshFlight()
        entries[token]?.rotation?.flight = flight
        // Not the global queue: request handlers run there and wait on this
        // refresh, so under load they could occupy every worker it needs.
        let thread = Thread { self.finishRefresh(token, result: refresh.resolve(), flight: flight) }
        thread.qualityOfService = .userInitiated
        thread.start()
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
