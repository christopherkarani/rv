import Foundation

/// Upper bound for a process-request command, in UTF-8 bytes.
/// Must stay equal to `commandByteCap` in RVEngine (asserted there).
public enum AgentRequestLimits {
    public static let maxCommandUTF8Count = 65_536
}

/// Fail-closed validation of an untrusted process request.
public enum AgentRequestValidationError: Error, Sendable, Equatable {
    /// Nil, empty, or whitespace-only command.
    case missingCommand
    /// Command UTF-8 length exceeds `AgentRequestLimits.maxCommandUTF8Count`.
    case commandTooLarge
    /// Hook bridge rejected a file or spend request.
    case unsupportedKind
}

/// Untrusted process-request fields. Holding one never implies a valid session request.
public struct RawAgentProcessRequest: Sendable, Equatable {
    public let host: HookHost
    public let command: String?
    public let workingDirectory: String?
    public let session: String?

    public init(
        host: HookHost,
        command: String?,
        workingDirectory: String? = nil,
        session: String? = nil
    ) {
        self.host = host
        self.command = command
        self.workingDirectory = workingDirectory
        self.session = session
    }
}

/// Untrusted process request before validation. Process is the only inhabited family.
public enum RawAgentRequest: Sendable, Equatable {
    case process(RawAgentProcessRequest)
}

/// Validated process request. Not a policy decision and not a capability.
public struct AgentProcessRequest: Sendable, Equatable {
    public let host: HookHost
    public let command: ShellCommand
    public let workingDirectory: WorkingDirectory?
    public let session: SessionID?

    /// Test seam. Production callers must use `AgentRequest.validate`.
    init(
        host: HookHost,
        command: ShellCommand,
        workingDirectory: WorkingDirectory?,
        session: SessionID?
    ) {
        self.host = host
        self.command = command
        self.workingDirectory = workingDirectory
        self.session = session
    }
}

/// Validated process request the runtime may normalize. File and spend are unrepresentable.
public enum AgentRequest: Sendable, Equatable {
    case process(AgentProcessRequest)

    /// Validates an untrusted process request. Failure produces no `AgentRequest`.
    public static func validate(
        _ raw: RawAgentRequest
    ) -> Result<AgentRequest, AgentRequestValidationError> {
        switch raw {
        case .process(let process):
            return validate(
                host: process.host,
                command: process.command,
                workingDirectory: process.workingDirectory,
                session: process.session
            )
        }
    }

    /// Validates raw strings. Empty cwd/session become `nil` via existing validators.
    public static func validate(
        host: HookHost,
        command: String?,
        workingDirectory: String? = nil,
        session: String? = nil
    ) -> Result<AgentRequest, AgentRequestValidationError> {
        guard let command else {
            return .failure(.missingCommand)
        }
        return validate(
            host: host,
            command: ShellCommand(rawValue: command),
            workingDirectory: workingDirectory.flatMap { WorkingDirectory(validating: $0) },
            session: session.flatMap { SessionID(validating: $0) }
        )
    }

    /// Validates values that already passed hook decode.
    public static func validate(
        host: HookHost,
        command: ShellCommand,
        workingDirectory: WorkingDirectory?,
        session: SessionID?
    ) -> Result<AgentRequest, AgentRequestValidationError> {
        let rawCommand = command.rawValue
        if rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.missingCommand)
        }
        if rawCommand.utf8.count > AgentRequestLimits.maxCommandUTF8Count {
            return .failure(.commandTooLarge)
        }
        return .success(
            .process(
                AgentProcessRequest(
                    host: host,
                    command: command,
                    workingDirectory: workingDirectory,
                    session: session
                )
            )
        )
    }
}
