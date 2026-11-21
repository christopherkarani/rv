import Foundation

/// The compute units the judge loads its Core ML model with.
public enum JudgeComputeUnits: String, Sendable, Codable, Equatable {
    /// GPU (MPSGraph) and CPU: the fast default.
    case cpuAndGPU
    /// CPU only: no MPSGraph, after repeated crashes inside Core ML.
    case cpuOnly
}

/// What rvd remembers about Core ML crashes across restarts.
public struct CoreMLCrashState: Sendable, Codable, Equatable {
    /// When each recent crash was noticed (at the next start).
    public var crashes: [Date]
    /// The GPU stays off until this instant once the policy trips.
    public var cpuOnlyUntil: Date?

    public init(crashes: [Date] = [], cpuOnlyUntil: Date? = nil) {
        self.crashes = crashes
        self.cpuOnlyUntil = cpuOnlyUntil
    }
}

/// Crash-aware compute-unit policy. Pure: the caller reads the leftover
/// in-flight marker and the persisted state, and stores what comes back.
///
/// A leftover marker means the previous process died while Core ML was
/// loading or predicting (an MPSGraph assertion abort, an LLVM I/O abort).
/// `crashLimit` such deaths inside `window` switch the judge to CPU only
/// for `cooldown`, so a GPU path that keeps aborting stops taking rvd down
/// with it. CPU only is slower, never weaker: the judge still scores every
/// call it scored before.
public enum CoreMLCrashPolicy {
    public static let crashLimit = 2
    public static let window: TimeInterval = 24 * 3600
    public static let cooldown: TimeInterval = 7 * 24 * 3600

    public static func recover(
        _ state: CoreMLCrashState,
        previousRunCrashed: Bool,
        now: Date
    ) -> (state: CoreMLCrashState, units: JudgeComputeUnits) {
        // Records from the future (clock moved back) and expired ones drop.
        var crashes = state.crashes.filter { $0 <= now && now.timeIntervalSince($0) < window }
        if previousRunCrashed { crashes.append(now) }
        // A stored deadline is capped at one cooldown from now, so a clock
        // that moved back cannot pin CPU only for longer than that.
        var until = state.cpuOnlyUntil.flatMap { $0 > now ? min($0, now.addingTimeInterval(cooldown)) : nil }
        if crashes.count >= crashLimit {
            until = max(until ?? now, now.addingTimeInterval(cooldown))
        }
        let next = CoreMLCrashState(crashes: crashes, cpuOnlyUntil: until)
        return (next, until == nil ? .cpuAndGPU : .cpuOnly)
    }
}
