import Foundation

/// Immutable semantic description of exactly one workspace runtime launch.
///
/// > **Exactly what operation the human will later review and authorize.**
///
/// `WorkspaceLaunchIntent` is the frozen input to the future chain
/// `host preparation -> UI review -> authorization challenge ->
/// WorkspaceOperationPermit -> host redemption -> launch`. Only this first
/// object exists here. Native UI, LocalAuthentication, permits, the challenge
/// state machine, the preparation protocol, issuance, redemption, and launch
/// enablement are explicitly out of scope.
///
/// The intent binds every caller-controlled value that can change the
/// effective launch observed in `WorkspaceHostServer.launchIdentity` ->
/// `AgentLaunchSelection` -> `WorkspaceSessionSupervisor.launchAgent` ->
/// `prepareSeatbelt` -> `spawnSeatbeltProcess`:
///
/// - launch target: named definition (`AgentDefinitionID` + verified
///   `AgentDefinitionRevision` + cross-checked resolved executable) or custom
///   (`executable` + expected content-digest intent)
/// - workspace scope: `WorkspaceSessionID` + POSIX-realpath-resolved cwd
/// - ordered argv, exact bytes, order/duplicates/empties significant
/// - IO mode: discard or pseudo-terminal with initial dimensions
/// - environment policy marker (spec bound, values resolved at preparation)
///
/// A `WorkspaceLaunchIntentDigest` proves object equality and binding. It
/// confers no authority: knowing a digest creates no operator authority, no
/// `AgentInstance`, no `WorkspaceOperationPermit`, and no `RuntimeCapability`.
/// Identity launch remains denied and operator authorization remains absent;
/// this type alone cannot unlock `WorkspaceOperationAuthorization`.
///
/// The canonical projection is encode-only and independent of any `Codable`
/// shape. There is intentionally no wire `Codable` on this type yet: the
/// envelope (prepared-operation identity, host binding, request correlation)
/// is designed in the host-preparation PR, and the codec ships with it.
///
/// Prepared-operation identity (`PreparedLaunchID`, `WorkspaceHostID`,
/// `WorkspaceHostGeneration`, service request identity) is deliberately NOT
/// a field here. The prepared object is created after the intent and binds
/// the intent digest; placing its id inside the intent would be circular
/// (`prepared id -> intent digest -> prepared id`). The future envelope binds
/// `(intentDigest, preparedID, host, generation)` instead. `WorkspaceSessionID`
/// stays in the intent because it scopes *what* runs (which protected
/// workspace's files and containment apply); host identity scopes *who*
/// redeems, which is the envelope's job.
///
/// The intent carries bindings, not trusted content: display and redemption
/// re-resolve the definition from trusted operator state and MUST verify
/// `revision == AgentDefinitionRevision.resolve(definition)` again before
/// showing or honoring anything.
public struct WorkspaceLaunchIntent: Hashable, Sendable, Equatable {
    /// Canonical schema version. Unknown versions fail closed in every
    /// future decoder; a schema change alters the domain string and this
    /// field, so v1 digests can never equal v2 digests.
    public static let schemaVersion = 1

    public let target: WorkspaceLaunchTarget
    public let workspaceSessionID: WorkspaceSessionID
    /// POSIX-realpath-resolved absolute workspace path: the exact value the
    /// spawn body passes to `posix_spawn_file_actions_addchdir`. The host
    /// preparation step MUST supply live `realpath` output here, and
    /// redemption MUST re-verify equality with live `realpath`. Unresolved
    /// spellings (`/tmp/foo` vs `/private/tmp/foo`) are never equated by
    /// this type.
    ///
    /// Construction cannot verify resolution: the domain layer performs no
    /// filesystem access, the redemption host may see a different view, and
    /// the path may not exist at authorization time. An unresolved spelling
    /// therefore still constructs — but it can never redeem, because the
    /// redemption equality check fails closed on any mismatch. One digest
    /// never authorizes two executions. The preparation MUST is a liveness
    /// requirement; safety holds regardless of caller discipline.
    public let workingDirectory: String
    /// Ordered argv. Order, duplicates, and empty arguments are significant
    /// and preserved byte-exact; argv is never sorted, joined, or shell-quoted.
    public let arguments: [String]
    public let io: WorkspaceLaunchIO
    public let environment: WorkspaceLaunchEnvironmentPolicy

    /// File-private so only the validated factories in this file can build
    /// an intent. No invalid value can reach `canonicalBytes` from anywhere,
    /// including elsewhere in this module.
    fileprivate init(
        target: WorkspaceLaunchTarget,
        workspaceSessionID: WorkspaceSessionID,
        workingDirectory: String,
        arguments: [String],
        io: WorkspaceLaunchIO,
        environment: WorkspaceLaunchEnvironmentPolicy
    ) {
        self.target = target
        self.workspaceSessionID = workspaceSessionID
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.io = io
        self.environment = environment
    }
}

/// Closed launch target: exactly two launch forms. No bag of optionals.
///
/// The variant discriminator enters the canonical bytes, so a named launch
/// can never collide with a custom launch.
public enum WorkspaceLaunchTarget: Hashable, Sendable, Equatable {
    case named(WorkspaceNamedLaunch)
    case custom(WorkspaceCustomLaunch)
}

/// Named-agent launch: immutable trusted selection, not just a name.
///
/// `AgentDefinitionID` alone is insufficient to authorize. The revision is
/// verified at construction against the full trusted definition, so it pins
/// the executable requirement, integration metadata, resolved
/// resource-profile content, credential bindings, required assurance, and
/// authority ceiling (everything `AgentDefinitionRevision` commits).
/// `resolvedExecutable` is cross-checked against the single executable link
/// for this definition id, so redemption can verify the authorized path
/// without trusting re-resolution.
public struct WorkspaceNamedLaunch: Hashable, Sendable, Equatable {
    public let definitionID: AgentDefinitionID
    public let definitionRevision: AgentDefinitionRevision
    /// Absolute executable path resolved from the definition's resource
    /// profile (`executableLinks[name == definitionID]`, exactly one).
    public let resolvedExecutable: String

    fileprivate init(
        definitionID: AgentDefinitionID,
        definitionRevision: AgentDefinitionRevision,
        resolvedExecutable: String
    ) {
        self.definitionID = definitionID
        self.definitionRevision = definitionRevision
        self.resolvedExecutable = resolvedExecutable
    }
}

/// Custom-executable launch: explicit operator selection with no named
/// identity, no credential grants, and no integration metadata.
///
/// `expectedContentDigestSHA256` is an expected-digest *intent*: the digest
/// the operator asks a future phase to verify. It is not measured executed
/// bytes. This type claims no Phase 4 executable measurement, no verified
/// signer, and no content attestation beyond `launchObserved`.
///
/// The ad-hoc snapshot revision (`AdHocAgentSnapshot`) is a pure function of
/// this digest over a fixed template, so binding the digest binds the
/// snapshot revision transitively without duplicating the template.
/// A custom launch always implies the base fence (nil resource profile);
/// the variant discriminator carries that, so no profile field is needed.
public struct WorkspaceCustomLaunch: Hashable, Sendable, Equatable {
    /// Absolute executable intent. The launch performs no executable-path
    /// normalization today, so the exact string is bound as given.
    public let executable: String
    /// Expected SHA-256 content digest as 64 lowercase hex digits. Intent,
    /// not evidence.
    public let expectedContentDigestSHA256: String

    fileprivate init(executable: String, expectedContentDigestSHA256: String) {
        self.executable = executable
        self.expectedContentDigestSHA256 = expectedContentDigestSHA256
    }
}

/// Closed IO modes for an authorized launch.
///
/// `.discard` drops output (`/dev/null` stdio). `.pseudoTerminal` keeps a
/// host-owned PTY whose slave is the child's stdin/stdout/stderr; rows and
/// columns are the *initial* window only. Post-launch resize is a separate
/// operation and is not part of this authorization.
///
/// There is no `.inherit`: descriptor inheritance is the in-process
/// host-launch door, never an authorizable workspace launch shape.
///
/// Dimensions are validated when an intent is built (1...512 per side);
/// only validated IO can enter canonical bytes.
public enum WorkspaceLaunchIO: Hashable, Sendable, Equatable {
    case discard
    case pseudoTerminal(rows: Int, columns: Int)
}

/// Closed environment policy bound by the intent.
///
/// `.containedProjectionV1` names the current spawn contract
/// (`ContainedEnvironmentPolicy.project` ambient projection plus
/// runtime-owned values plus profile environment entries plus keychain
/// staging, where keychain staging is rejected for identity launches until
/// Secrets exists). The intent binds the *specification*: the projection
/// policy marker plus the profile environment entries committed by the
/// verified definition revision (which host variables are read, which
/// literals apply).
///
/// Environment *values* from live host state (ambient projection, host
/// variables) resolve at host preparation/redemption from trusted-host
/// state and are frozen by the future prepared operation, which the permit
/// then binds. No secret value ever enters the intent, its canonical bytes,
/// its digest, or its logs: credential-bearing definition shapes are
/// rejected at construction.
public enum WorkspaceLaunchEnvironmentPolicy: Hashable, Sendable, Equatable {
    case containedProjectionV1
}

/// Typed construction failure. Invalid intents fail here, before any digest
/// exists that could later be authorized.
public enum WorkspaceLaunchIntentError: Error, Hashable, Sendable, Equatable {
    /// Definition id fails `AgentTagValidator` (empty, over 32 bytes, or
    /// outside `[A-Za-z0-9._-]`).
    case invalidDefinitionID
    /// The ad-hoc snapshot id is reserved for custom launches and can never
    /// name a trusted definition.
    case reservedDefinitionID
    /// Revision is not 64 lowercase hex digits.
    case invalidRevisionDigest
    /// Revision does not equal `AgentDefinitionRevision.resolve(definition)`:
    /// the definition content is not the content the revision pins.
    case revisionMismatch
    /// Executable is not a strict absolute path (must start with `/`, must
    /// not be `/`, at most 1024 bytes, no NUL/CR/LF, no empty/`.`/`..`
    /// segments).
    case invalidExecutable
    /// The definition's resource profile does not carry exactly one
    /// executable link for the definition id, or that link target differs
    /// from the bound executable.
    case executableNotAuthorizedByRevision
    /// Expected custom digest is not 64 lowercase hex digits.
    case invalidExpectedDigest
    /// The definition stages credentials (credential bindings, profile
    /// credentials, or profile keychain entries). Secrets integration is
    /// deferred; such shapes cannot be authorized yet.
    case credentialStagingNotSupported
    /// Working directory is not a strict absolute path (same rules as
    /// executables). Callers must pass POSIX-realpath-resolved paths.
    case invalidWorkingDirectory
    /// More than 64 arguments (control-protocol bound).
    case tooManyArguments
    /// An argument carries NUL or exceeds 8192 bytes. Empty arguments are
    /// valid and significant; newlines, tabs, and Unicode are bound exact.
    case invalidArgument
    /// Terminal dimensions outside 1...512 per side.
    case invalidTerminalDimensions
}

extension WorkspaceLaunchIntent {
    /// Builds a named-agent intent from the trusted definition snapshot the
    /// host holds. The revision is verified against the definition, the
    /// executable is cross-checked against the revision-pinned link, and
    /// credential-bearing shapes are rejected. Validation order is fixed:
    /// definition id, reserved id, revision format, revision match,
    /// executable format, executable authorization, credential gate, working
    /// directory, argument count, argument values, IO.
    public static func makeNamed(
        definition: AgentDefinition,
        revision: AgentDefinitionRevision,
        resolvedExecutable: String,
        workspaceSessionID: WorkspaceSessionID,
        workingDirectory: String,
        arguments: [String],
        io: WorkspaceLaunchIO
    ) -> Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError> {
        guard AgentDefinitionID(validating: definition.id.rawValue) != nil else {
            return .failure(.invalidDefinitionID)
        }
        guard definition.id.rawValue != WorkspaceLaunchLimits.reservedSnapshotID else {
            return .failure(.reservedDefinitionID)
        }
        guard WorkspaceLaunchLimits.isSHA256HexDigest(revision.digestHex) else {
            return .failure(.invalidRevisionDigest)
        }
        guard revision == AgentDefinitionRevision.resolve(definition) else {
            return .failure(.revisionMismatch)
        }
        guard WorkspaceLaunchLimits.isStrictAbsolutePath(resolvedExecutable) else {
            return .failure(.invalidExecutable)
        }
        let links = definition.resourceProfile.executableLinks.filter {
            $0.name == definition.id.rawValue
        }
        guard links.count == 1, let link = links.first, link.target == resolvedExecutable else {
            return .failure(.executableNotAuthorizedByRevision)
        }
        guard definition.credentialBindings.isEmpty,
            definition.resourceProfile.credentials.isEmpty,
            definition.resourceProfile.keychain.isEmpty
        else {
            return .failure(.credentialStagingNotSupported)
        }
        return makeCommon(
            target: .named(
                WorkspaceNamedLaunch(
                    definitionID: definition.id,
                    definitionRevision: revision,
                    resolvedExecutable: resolvedExecutable
                )
            ),
            workspaceSessionID: workspaceSessionID,
            workingDirectory: workingDirectory,
            arguments: arguments,
            io: io
        )
    }

    /// Builds a custom-executable intent. The digest is validated for form
    /// only; it states intent, never measured evidence. Validation order is
    /// fixed: executable, digest, working directory, argument count,
    /// argument values, IO.
    public static func makeCustom(
        executable: String,
        expectedContentDigestSHA256: String,
        workspaceSessionID: WorkspaceSessionID,
        workingDirectory: String,
        arguments: [String],
        io: WorkspaceLaunchIO
    ) -> Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError> {
        guard WorkspaceLaunchLimits.isStrictAbsolutePath(executable) else {
            return .failure(.invalidExecutable)
        }
        guard WorkspaceLaunchLimits.isSHA256HexDigest(expectedContentDigestSHA256) else {
            return .failure(.invalidExpectedDigest)
        }
        return makeCommon(
            target: .custom(
                WorkspaceCustomLaunch(
                    executable: executable,
                    expectedContentDigestSHA256: expectedContentDigestSHA256
                )
            ),
            workspaceSessionID: workspaceSessionID,
            workingDirectory: workingDirectory,
            arguments: arguments,
            io: io
        )
    }

    private static func makeCommon(
        target: WorkspaceLaunchTarget,
        workspaceSessionID: WorkspaceSessionID,
        workingDirectory: String,
        arguments: [String],
        io: WorkspaceLaunchIO
    ) -> Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError> {
        guard WorkspaceLaunchLimits.isStrictAbsolutePath(workingDirectory) else {
            return .failure(.invalidWorkingDirectory)
        }
        guard arguments.count <= WorkspaceLaunchLimits.maxArguments else {
            return .failure(.tooManyArguments)
        }
        for argument in arguments {
            guard WorkspaceLaunchLimits.isValidArgument(argument) else {
                return .failure(.invalidArgument)
            }
        }
        guard WorkspaceLaunchLimits.isValidIO(io) else {
            return .failure(.invalidTerminalDimensions)
        }
        return .success(
            WorkspaceLaunchIntent(
                target: target,
                workspaceSessionID: workspaceSessionID,
                workingDirectory: workingDirectory,
                arguments: arguments,
                io: io,
                environment: .containedProjectionV1
            )
        )
    }
}

/// Bounds and predicates shared by both factories.
///
/// Several bounds mirror launch-path constants owned elsewhere
/// (`WorkspaceControlLimits`, `TerminalStreamLimits`,
/// `AgentLaunchSelection.validExecutable`, `AgentDefinitionStore` digest and
/// reserved-id rules). The mirrors are behavioral, not aliased: RVDomain
/// owns no launch code, and coupling tests in RVPolicyTests/RVIsolationTests
/// pin agreement at the boundaries so a drift on either side fails loudly.
enum WorkspaceLaunchLimits {
    static let maxPathBytes = 1_024
    static let maxArgumentBytes = 8_192
    static let maxArguments = 64
    static let minTerminalDimension = 1
    static let maxTerminalDimension = 512
    static let reservedSnapshotID = "adhoc"

    static func isStrictAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value != "/"
            && value.utf8.count <= maxPathBytes
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
            && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isSHA256HexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func isValidArgument(_ value: String) -> Bool {
        value.utf8.count <= maxArgumentBytes && !value.contains("\0")
    }

    static func isValidIO(_ io: WorkspaceLaunchIO) -> Bool {
        switch io {
        case .discard:
            true
        case .pseudoTerminal(let rows, let columns):
            (minTerminalDimension...maxTerminalDimension).contains(rows)
                && (minTerminalDimension...maxTerminalDimension).contains(columns)
        }
    }
}

/// SHA-256 over the canonical bytes, as 64 lowercase hex digits.
///
/// Naming a digest neither computes one nor grants anything. Only
/// `WorkspaceLaunchIntent.canonicalDigest` computes this value, and the
/// result proves object equality/binding only: it is not an authorization
/// credential.
public struct WorkspaceLaunchIntentDigest: Hashable, Sendable, Equatable, Codable {
    public let sha256Hex: String

    public init(sha256Hex: String) {
        self.sha256Hex = sha256Hex
    }
}

extension WorkspaceLaunchIntent {
    /// Deterministic canonical bytes. Encode-only: no decoder exists, and
    /// none is needed, because intents are built by validated factories, not
    /// parsed. The layout is injective over valid intents: distinct intents
    /// always produce distinct bytes.
    ///
    /// Framing rules:
    /// - `str`  = u32 big-endian UTF-8 byte count, then exact UTF-8 bytes.
    ///            No escaping, no normalization, no sorting, no joining.
    /// - `u32`  = 4 bytes big-endian. `u8` = 1 byte. `uuid16` = the 16
    ///            RFC 4122 bytes in order.
    /// - fixed field order; every field self-delimiting (length-prefixed).
    ///
    /// Layout:
    /// ```
    /// str    domain              // "RV.WorkspaceLaunchIntent.v1"
    /// u32    schemaVersion       // 1
    /// u8     target              // 0x00 named, 0x01 custom
    /// named:  str definitionID, str revisionDigestHex, str resolvedExecutable
    /// custom: str executable, str expectedDigestHex
    /// uuid16 workspaceSessionID
    /// str    workingDirectory
    /// u32    argc, then argc x str, in order
    /// u8     io                  // 0x00 discard, 0x01 pseudoTerminal
    /// pty:   u32 rows, u32 columns
    /// u8     environment         // 0x00 containedProjectionV1
    /// ```
    ///
    /// Audit-relevant distinctions, all preserved:
    /// - argv order, duplicates, and empty arguments: `["a","b"]`,
    ///   `["b","a"]`, `["a","a"]`, `["a"]`, `[""]`, and `[]` all differ.
    /// - nil vs empty vs default: every bound field is non-optional, so
    ///   absence is unrepresentable and no absent/empty collision exists.
    ///   (IO `discard` vs `pseudoTerminal` is a closed discriminator, not an
    ///   optional size.)
    /// - Unicode: exact Swift string bytes; precomposed vs decomposed,
    ///   bidi controls, zero-width characters, newlines, and tabs all differ.
    /// - no delimiter concatenation anywhere: values containing separators,
    ///   newlines, or domain-looking text cannot collide.
    public var canonicalBytes: [UInt8] {
        var out: [UInt8] = []
        WorkspaceLaunchCanonical.appendString(&out, WorkspaceLaunchCanonical.domain)
        WorkspaceLaunchCanonical.appendU32(&out, UInt32(WorkspaceLaunchIntent.schemaVersion))
        switch target {
        case .named(let named):
            out.append(WorkspaceLaunchCanonical.targetNamed)
            WorkspaceLaunchCanonical.appendString(&out, named.definitionID.rawValue)
            WorkspaceLaunchCanonical.appendString(&out, named.definitionRevision.digestHex)
            WorkspaceLaunchCanonical.appendString(&out, named.resolvedExecutable)
        case .custom(let custom):
            out.append(WorkspaceLaunchCanonical.targetCustom)
            WorkspaceLaunchCanonical.appendString(&out, custom.executable)
            WorkspaceLaunchCanonical.appendString(&out, custom.expectedContentDigestSHA256)
        }
        WorkspaceLaunchCanonical.appendUUID(&out, workspaceSessionID.rawValue)
        WorkspaceLaunchCanonical.appendString(&out, workingDirectory)
        WorkspaceLaunchCanonical.appendU32(&out, UInt32(arguments.count))
        for argument in arguments {
            WorkspaceLaunchCanonical.appendString(&out, argument)
        }
        switch io {
        case .discard:
            out.append(WorkspaceLaunchCanonical.ioDiscard)
        case .pseudoTerminal(let rows, let columns):
            out.append(WorkspaceLaunchCanonical.ioPseudoTerminal)
            WorkspaceLaunchCanonical.appendU32(&out, UInt32(rows))
            WorkspaceLaunchCanonical.appendU32(&out, UInt32(columns))
        }
        switch environment {
        case .containedProjectionV1:
            out.append(WorkspaceLaunchCanonical.environmentContainedProjectionV1)
        }
        return out
    }

    /// SHA-256 of `canonicalBytes` via the project's audited hash
    /// (`HTTPDigest`, also used by `AgentDefinitionRevision`). Stable across
    /// runs and platforms for equal intents. Grants nothing.
    public var canonicalDigest: WorkspaceLaunchIntentDigest {
        WorkspaceLaunchIntentDigest(sha256Hex: HTTPDigest.sha256Hex(canonicalBytes))
    }

    /// Safe descriptive projection for the future review UI. Structured:
    /// arguments stay `[String]` and are never reconstructed into one shell
    /// command. Sensitive: argument values may carry operator secrets, so
    /// this projection must never be logged wholesale; presentation escaping
    /// and redaction are later UI concerns and never alter canonical bytes.
    public var auditSummary: WorkspaceLaunchIntentSummary {
        switch target {
        case .named(let named):
            WorkspaceLaunchIntentSummary(
                kind: .named,
                definitionID: named.definitionID.rawValue,
                definitionRevisionDigest: named.definitionRevision.digestHex,
                executable: named.resolvedExecutable,
                expectedContentDigestSHA256: nil,
                workspaceSessionID: workspaceSessionID,
                workingDirectory: workingDirectory,
                arguments: arguments,
                io: io,
                environment: environment
            )
        case .custom(let custom):
            WorkspaceLaunchIntentSummary(
                kind: .custom,
                definitionID: nil,
                definitionRevisionDigest: nil,
                executable: custom.executable,
                expectedContentDigestSHA256: custom.expectedContentDigestSHA256,
                workspaceSessionID: workspaceSessionID,
                workingDirectory: workingDirectory,
                arguments: arguments,
                io: io,
                environment: environment
            )
        }
    }
}

/// Canonical framing constants and writers. Single authoritative encoder;
/// nothing else in the tree may produce these bytes.
enum WorkspaceLaunchCanonical {
    static let domain = "RV.WorkspaceLaunchIntent.v1"
    static let targetNamed: UInt8 = 0x00
    static let targetCustom: UInt8 = 0x01
    static let ioDiscard: UInt8 = 0x00
    static let ioPseudoTerminal: UInt8 = 0x01
    static let environmentContainedProjectionV1: UInt8 = 0x00

    static func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    static func appendString(_ out: inout [UInt8], _ value: String) {
        let bytes = Array(value.utf8)
        appendU32(&out, UInt32(bytes.count))
        out.append(contentsOf: bytes)
    }

    static func appendUUID(_ out: inout [UInt8], _ value: UUID) {
        let u = value.uuid
        out.append(
            contentsOf: [
                u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
            ]
        )
    }
}

/// Display discriminator for `WorkspaceLaunchIntentSummary`.
public enum WorkspaceLaunchKind: String, Hashable, Sendable, Equatable {
    case named
    case custom
}

/// Structured, UI-bound projection of an intent. Separate from canonical
/// execution bytes by construction: nothing here is hashed, parsed, or
/// executed. Arguments stay `[String]`; never join them into shell text.
/// Sensitive as a whole: never log wholesale.
public struct WorkspaceLaunchIntentSummary: Hashable, Sendable, Equatable {
    public let kind: WorkspaceLaunchKind
    public let definitionID: String?
    public let definitionRevisionDigest: String?
    public let executable: String
    public let expectedContentDigestSHA256: String?
    public let workspaceSessionID: WorkspaceSessionID
    public let workingDirectory: String
    public let arguments: [String]
    public let io: WorkspaceLaunchIO
    public let environment: WorkspaceLaunchEnvironmentPolicy

    fileprivate init(
        kind: WorkspaceLaunchKind,
        definitionID: String?,
        definitionRevisionDigest: String?,
        executable: String,
        expectedContentDigestSHA256: String?,
        workspaceSessionID: WorkspaceSessionID,
        workingDirectory: String,
        arguments: [String],
        io: WorkspaceLaunchIO,
        environment: WorkspaceLaunchEnvironmentPolicy
    ) {
        self.kind = kind
        self.definitionID = definitionID
        self.definitionRevisionDigest = definitionRevisionDigest
        self.executable = executable
        self.expectedContentDigestSHA256 = expectedContentDigestSHA256
        self.workspaceSessionID = workspaceSessionID
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.io = io
        self.environment = environment
    }
}
