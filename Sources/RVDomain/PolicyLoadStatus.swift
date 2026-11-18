/// Whether evaluation can load typed policy for one (config dir,
/// workspace), and which documents it loads. Produced by running the load
/// evaluation runs (`PolicyWorkspace.loadStatus`), in rvd for
/// `rv policy status`.
///
/// rvd re-reads `policy.toml` and `ceiling.toml` on every evaluation; it
/// holds no policy cache. `loaded` means the next evaluation sees these
/// documents. `failed` means every evaluation denies with
/// `typed-rules-invalid` until the file is fixed. rv never falls back to an
/// earlier policy: a last-good fallback would let a policy the owner
/// replaced keep allowing.
public struct PolicyLoadStatus: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Equatable, Codable {
        case loaded
        case failed
    }

    /// The load step that threw. Load stops at the first failure, as
    /// evaluation does.
    public enum Failure: String, Sendable, Equatable, Codable {
        /// Machine `policy.toml` cannot be read or parsed.
        case machineInvalid = "machine-invalid"
        /// Repo `.rv/policy.toml` cannot be read or parsed.
        case repoInvalid = "repo-invalid"
        /// `ceiling.toml` exists but cannot be read or parsed.
        case ceilingInvalid = "ceiling-invalid"
    }

    /// Why the failing step's file was refused. A fixed set, never file
    /// content or a free-text error.
    public enum Problem: String, Sendable, Equatable, Codable, Error {
        /// A FIFO, device, directory or other non-regular file: never
        /// read, so it cannot block evaluation.
        case notRegularFile = "not-regular-file"
        /// A symlink where none is followed (`ceiling.toml`).
        case symlink
        /// Past the size cap (1 MiB per layer, 256 KiB for the ceiling).
        case tooLarge = "too-large"
        case notUTF8 = "not-utf8"
        /// Open or read failed (permissions, I/O).
        case unreadable
        /// Read, but not a valid document.
        case unparseable
    }

    /// One loaded layer document.
    public struct Layer: Sendable, Equatable, Codable {
        /// `PolicyRevisionIdentity.hash` of the document; a revision log
        /// entry with this hash is the revision being enforced. A missing
        /// file loads as the empty document and hashes as one.
        public var hash: String
        public var ruleCount: Int
        /// A deny or ask rule in the layer is weaker than the owner's
        /// ceiling (a hand edit past the save gate). It still loads: the
        /// ceiling's verdict wins at evaluation.
        public var exceedsCeiling: Bool

        public init(hash: String, ruleCount: Int, exceedsCeiling: Bool) {
            self.hash = hash
            self.ruleCount = ruleCount
            self.exceedsCeiling = exceedsCeiling
        }
    }

    public var state: State
    public var failure: Failure?
    /// Why the failing step's file was refused; nil when loaded.
    public var problem: Problem?
    /// Nil without a machine config directory (no HOME), or when loading failed.
    public var machine: Layer?
    /// Nil without a workspace, or when loading failed.
    public var repo: Layer?
    /// Rules in `ceiling.toml`; nil when there is none or loading failed.
    public var ceilingRuleCount: Int?
    /// Merged typed rules evaluation enforces; nil when loading failed.
    public var effectiveRuleCount: Int?
    /// The machine config directory this load read.
    public var configDirectory: String?
    /// The workspace whose `.rv/policy.toml` this load read.
    public var workspace: String?

    public init(
        state: State,
        failure: Failure? = nil,
        problem: Problem? = nil,
        machine: Layer? = nil,
        repo: Layer? = nil,
        ceilingRuleCount: Int? = nil,
        effectiveRuleCount: Int? = nil,
        configDirectory: String? = nil,
        workspace: String? = nil
    ) {
        self.state = state
        self.failure = failure
        self.problem = problem
        self.machine = machine
        self.repo = repo
        self.ceilingRuleCount = ceilingRuleCount
        self.effectiveRuleCount = effectiveRuleCount
        self.configDirectory = configDirectory
        self.workspace = workspace
    }
}
