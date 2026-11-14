import ArgumentParser
import RVDomain

/// `rv workspace run --timeout`: a wall-clock deadline for one runtime.
///
/// The value is whole seconds, or a number with `s`, `m` or `h`. The
/// `limits.timeoutSeconds` policy value in runtime-resources.json is both
/// the default and a ceiling: a flag may shorten it, never extend it. The
/// host applies the smaller of the two whatever this check says; this
/// only turns an over-long request into a clear refusal.
enum WorkspaceRunTimeout {
    static func parse(_ raw: String) -> UInt64? {
        guard let last = raw.last, raw.count <= 16 else { return nil }
        let unit: UInt64
        let digits: Substring
        switch last {
        case "s": unit = 1; digits = raw.dropLast()
        case "m": unit = 60; digits = raw.dropLast()
        case "h": unit = 3_600; digits = raw.dropLast()
        default: unit = 1; digits = Substring(raw)
        }
        guard digits.isEmpty == false, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let value = UInt64(digits)
        else { return nil }
        let (seconds, overflow) = value.multipliedReportingOverflow(by: unit)
        guard overflow == false, RuntimeProcessLimits.timeoutSecondsRange.contains(seconds) else {
            return nil
        }
        return seconds
    }

    /// Validated seconds for a launch, or nil without the flag.
    static func resolve(
        _ raw: String?, microVM: Bool, policy: () -> RuntimeProcessLimits?
    ) throws -> UInt64? {
        guard let raw else { return nil }
        guard microVM == false else {
            throw ValidationError("--timeout applies to Seatbelt runtimes; it cannot be combined with --microvm or --macvm")
        }
        let range = RuntimeProcessLimits.timeoutSecondsRange
        guard let seconds = parse(raw) else {
            throw ValidationError("--timeout must be \(range.lowerBound)-\(range.upperBound) seconds, written as N, Ns, Nm or Nh")
        }
        if let ceiling = policy()?.timeoutSeconds, seconds > ceiling {
            throw ValidationError("--timeout \(raw) exceeds the runtime-resources.json limit of \(ceiling) seconds")
        }
        return seconds
    }
}
