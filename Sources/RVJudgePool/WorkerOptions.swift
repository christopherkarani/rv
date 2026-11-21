/// The arguments of `rv-judge --worker`, the inverse of
/// `PosixWorkerSpawner.judgeWorkerArguments`. Every option is required.
/// The compiled-model cache is not an argument: workers load through the
/// verified store under the account's `~/.config/rv/cache/laya`, located
/// from the password database, never from argv or `$HOME`.
public struct WorkerOptions: Sendable, Equatable {
    public var compute: WorkerCompute
    public var engine: String
    public var bundle: String

    public init(compute: WorkerCompute, engine: String, bundle: String) {
        self.compute = compute
        self.engine = engine
        self.bundle = bundle
    }

    /// `arguments` excludes `--worker`. Nil on anything unknown, repeated
    /// short, relative or missing.
    public static func parse(_ arguments: [String]) -> WorkerOptions? {
        var compute: WorkerCompute?
        var engine: String?
        var bundle: String?
        var index = 0
        while index + 1 < arguments.count {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--compute": compute = WorkerCompute(rawValue: value)
            case "--engine": engine = ["ft", "laya"].contains(value) ? value : nil
            case "--bundle": bundle = value.hasPrefix("/") ? value : nil
            default: return nil
            }
            index += 2
        }
        guard index == arguments.count, let compute, let engine, let bundle else { return nil }
        return WorkerOptions(compute: compute, engine: engine, bundle: bundle)
    }
}
