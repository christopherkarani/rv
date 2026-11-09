import Foundation

public enum MicroVMOptionError: Error, Sendable, Equatable, CustomStringConvertible {
    case rootMustBeAbsolute
    case relayDirectoryMustBeAbsolute(String)
    case workspaceMustBeAbsolute
    case commandMissing
    case commandMustBeAbsolute(String)
    case containsNUL
    case invalidImage(String)
    case cpusOutOfRange(Int, maximum: Int)
    case memoryOutOfRange(Int, minimum: Int, maximum: Int)
    case invalidRelayPort(Int)
    case duplicateRelayPort(Int)
    case tooManyRelayPorts(Int)
    case invalidEnvironmentName(String)
    case duplicateEnvironmentName(String)
    case handshakeIncomplete
    case invalidNonce
    case invalidHandshakeDescriptor(Int32)
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .rootMustBeAbsolute: "--root must be an absolute path"
        case .relayDirectoryMustBeAbsolute(let path): "relay directory must be an absolute path: \(path)"
        case .workspaceMustBeAbsolute: "--workspace must be an absolute path"
        case .commandMissing: "no guest command after --"
        case .commandMustBeAbsolute(let exe): "guest executable must be an absolute path inside the image: \(exe)"
        case .containsNUL: "arguments must not contain NUL"
        case .invalidImage(let ref): "invalid image reference: \(ref)"
        case .cpusOutOfRange(let n, let max): "--cpus \(n) is out of range 1...\(max)"
        case .memoryOutOfRange(let n, let min, let max): "--memory-mib \(n) is out of range \(min)...\(max)"
        case .invalidRelayPort(let p): "--relay-port \(p) is out of range 1...65535"
        case .duplicateRelayPort(let p): "--relay-port \(p) is given twice"
        case .tooManyRelayPorts(let n): "\(n) relay ports exceed the limit of \(RunOptions.maxRelayPorts)"
        case .invalidEnvironmentName(let n): "--forward-env \(n) is not a valid environment variable name"
        case .duplicateEnvironmentName(let n): "--forward-env \(n) is given twice"
        case .handshakeIncomplete: "--handshake-fd and --nonce must be given together"
        case .invalidNonce: "--nonce must be 1...128 ASCII letters or digits"
        case .invalidHandshakeDescriptor(let fd): "--handshake-fd \(fd) must be 3 or greater"
        case .socketPathTooLong(let path): "relay socket path is too long for AF_UNIX: \(path)"
        }
    }
}

/// Validated `rv-microvm run` request. Construction is `validate`.
public struct RunOptions: Sendable, Equatable {
    /// Matches RV_RELAY_MAX_PAIRS in rv_guest_relay.c.
    public static let maxRelayPorts = 8
    public static let minimumMemoryMiB = 256
    public static let defaultCPUs = 2
    public static let defaultMemoryMiB = 2048

    public let layout: MicroVMLayout
    /// Fully qualified OCI reference (see `ImageReference.normalize`).
    public let image: String
    public let workspace: String
    public let cpus: Int
    public let memoryMiB: Int
    public let relayPorts: [Int]
    public let forwardedEnvironment: [String]
    public let command: [String]
    public let handshake: Handshake?

    public struct Handshake: Sendable, Equatable {
        public let descriptor: Int32
        public let nonce: String
    }

    public static func validate(
        root: String,
        image: String,
        workspace: String,
        cpus: Int,
        memoryMiB: Int,
        relayPorts: [Int],
        forwardedEnvironment: [String],
        command: [String],
        handshakeDescriptor: Int32?,
        nonce: String?,
        hostCPUs: Int,
        hostMemoryMiB: Int,
        imageNormalizer: (String) -> Result<String, MicroVMOptionError> = ImageReference.normalize,
        minimumMemoryMiB: Int = RunOptions.minimumMemoryMiB
    ) -> Result<RunOptions, MicroVMOptionError> {
        let all = [root, image, workspace] + command + forwardedEnvironment + [nonce ?? ""]
        guard all.allSatisfy({ !$0.contains("\0") }) else { return .failure(.containsNUL) }
        guard root.hasPrefix("/") else { return .failure(.rootMustBeAbsolute) }
        guard workspace.hasPrefix("/") else { return .failure(.workspaceMustBeAbsolute) }
        guard let executable = command.first else { return .failure(.commandMissing) }
        guard executable.hasPrefix("/") else { return .failure(.commandMustBeAbsolute(executable)) }
        let normalized: String
        switch imageNormalizer(image) {
        case .failure(let error): return .failure(error)
        case .success(let reference): normalized = reference
        }
        let cpuLimit = max(1, hostCPUs)
        guard (1...cpuLimit).contains(cpus) else { return .failure(.cpusOutOfRange(cpus, maximum: cpuLimit)) }
        let memoryLimit = max(minimumMemoryMiB, hostMemoryMiB)
        guard (minimumMemoryMiB...memoryLimit).contains(memoryMiB) else {
            return .failure(.memoryOutOfRange(memoryMiB, minimum: minimumMemoryMiB, maximum: memoryLimit))
        }
        guard relayPorts.count <= maxRelayPorts else { return .failure(.tooManyRelayPorts(relayPorts.count)) }
        var seenPorts = Set<Int>()
        for port in relayPorts {
            guard (1...65535).contains(port) else { return .failure(.invalidRelayPort(port)) }
            guard seenPorts.insert(port).inserted else { return .failure(.duplicateRelayPort(port)) }
        }
        var seenNames = Set<String>()
        for name in forwardedEnvironment {
            guard GuestEnvironment.isValidName(name) else { return .failure(.invalidEnvironmentName(name)) }
            guard seenNames.insert(name).inserted else { return .failure(.duplicateEnvironmentName(name)) }
        }
        let handshake: Handshake?
        switch (handshakeDescriptor, nonce) {
        case (nil, nil):
            handshake = nil
        case (let fd?, let value?):
            guard fd >= 3 else { return .failure(.invalidHandshakeDescriptor(fd)) }
            guard (1...128).contains(value.utf8.count),
                value.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
            else { return .failure(.invalidNonce) }
            handshake = Handshake(descriptor: fd, nonce: value)
        default:
            return .failure(.handshakeIncomplete)
        }
        return .success(
            RunOptions(
                layout: MicroVMLayout(root: URL(fileURLWithPath: root, isDirectory: true)),
                image: normalized,
                workspace: workspace,
                cpus: cpus,
                memoryMiB: memoryMiB,
                relayPorts: relayPorts,
                forwardedEnvironment: forwardedEnvironment,
                command: command,
                handshake: handshake
            )
        )
    }
}

/// Environment of the guest command.
public enum GuestEnvironment {
    /// rv passes each forwarded value as `RV_GUEST_<NAME>` so a guest value
    /// never configures this entitled host process under its own name
    /// (`SSL_CERT_FILE`, `DYLD_*`, `CFNETWORK_*`, ...).
    public static let forwardedPrefix = "RV_GUEST_"

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 256 else { return false }
        let head = first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        return head && name.unicodeScalars.allSatisfy {
            $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }

    /// Image environment, then rv defaults for names the image leaves unset,
    /// then the forwarded values (read from `RV_GUEST_<NAME>`). Forwarded
    /// names missing on the host are skipped. Later entries win; the result
    /// has one entry per name.
    public static func build(
        image: [String],
        forwarded names: [String],
        host: [String: String],
        terminal: Bool,
        defaults base: [(String, String)] = [
            ("PATH", MicroVMGuest.defaultPath),
            ("HOME", MicroVMGuest.home),
            ("LANG", "C.UTF-8"),
        ]
    ) -> [String] {
        var order: [String] = []
        var values: [String: String] = [:]
        func set(_ name: String, _ value: String) {
            if values[name] == nil { order.append(name) }
            values[name] = value
        }
        for entry in image {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            guard isValidName(name) else { continue }
            set(name, String(entry[entry.index(after: equals)...]))
        }
        var defaults = base
        if terminal { defaults.append(("TERM", "xterm-256color")) }
        for (name, value) in defaults where values[name] == nil {
            set(name, value)
        }
        for name in names {
            guard let value = host[forwardedPrefix + name], !value.contains("\0") else { continue }
            set(name, value)
        }
        return order.map { "\($0)=\(values[$0]!)" }
    }
}

/// Loopback services relayed into the guest: host TCP port ↔ host unix
/// socket ↔ vsock ↔ guest unix socket ↔ guest 127.0.0.1 on the same port.
public struct RelayPlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let port: Int
        public let hostSocket: String
        public let guestSocket: String
    }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the NUL.
    public static let maxSocketPathBytes = 103

    public let entries: [Entry]

    public static func make(ports: [Int], hostDirectory: String) -> Result<RelayPlan, MicroVMOptionError> {
        guard hostDirectory.hasPrefix("/") else { return .failure(.relayDirectoryMustBeAbsolute(hostDirectory)) }
        var entries: [Entry] = []
        for port in ports {
            let host = "\(hostDirectory)/p\(port).sock"
            guard host.utf8.count <= maxSocketPathBytes else { return .failure(.socketPathTooLong(host)) }
            entries.append(Entry(port: port, hostSocket: host, guestSocket: "\(MicroVMGuest.socketDirectory)/p\(port).sock"))
        }
        return .success(RelayPlan(entries: entries))
    }

    /// argv for `rv-guest-relay`. With no entries the relay only idles,
    /// which keeps the guest init process image-independent.
    public var guestArguments: [String] {
        [MicroVMGuest.relayPath] + entries.map { "\($0.port)=\($0.guestSocket)" }
    }
}

/// Docker-style image reference normalization:
/// `alpine` → `docker.io/library/alpine:latest`.
public enum ImageReference {
    public static func normalize(_ raw: String) -> Result<String, MicroVMOptionError> {
        let reference = raw.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, reference.utf8.count <= 512,
            reference.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .failure(.invalidImage(raw)) }

        var remainder = reference
        var digest: String?
        if let at = remainder.firstIndex(of: "@") {
            digest = String(remainder[remainder.index(after: at)...])
            remainder = String(remainder[..<at])
            guard let value = digest, MicroVMDigest.hex(value) != nil else { return .failure(.invalidImage(raw)) }
        }
        var tag: String?
        if let colon = remainder.lastIndex(of: ":"), !remainder[colon...].contains("/") {
            tag = String(remainder[remainder.index(after: colon)...])
            remainder = String(remainder[..<colon])
            guard let value = tag, isValidTag(value) else { return .failure(.invalidImage(raw)) }
        }
        var components = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty }) else { return .failure(.invalidImage(raw)) }
        var domain = "docker.io"
        if components.count > 1, let first = components.first, isRegistryHost(first) {
            domain = first
            components.removeFirst()
        }
        if domain == "docker.io", components.count == 1 {
            components.insert("library", at: 0)
        }
        guard components.allSatisfy(isValidPathComponent) else { return .failure(.invalidImage(raw)) }
        var normalized = "\(domain)/\(components.joined(separator: "/"))"
        if let tag {
            normalized += ":\(tag)"
        } else if digest == nil {
            normalized += ":latest"
        }
        if let digest { normalized += "@\(digest)" }
        return .success(normalized)
    }

    /// `host`, `host.domain`, `localhost`, each optionally with a numeric `:port`.
    private static func isRegistryHost(_ component: String) -> Bool {
        let parts = component.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return false }
        if parts.count == 2 {
            let port = parts[1]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else {
                return false
            }
        }
        let hostAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard host.unicodeScalars.allSatisfy({ $0.isASCII && hostAllowed.contains($0) }) else { return false }
        return host.contains(".") || host == "localhost" || parts.count == 2
    }

    private static func isValidTag(_ tag: String) -> Bool {
        guard let first = tag.unicodeScalars.first, tag.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return first != "." && first != "-" && tag.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isValidPathComponent(_ component: String) -> Bool {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "._-"))
        guard let first = component.unicodeScalars.first, let last = component.unicodeScalars.last else { return false }
        let edge = CharacterSet.lowercaseLetters.union(.decimalDigits)
        return edge.contains(first) && edge.contains(last)
            && component.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
