import Foundation
import RVDomain

/// Caller-selected micro-VM launch: an OCI image and optional VM size.
///
/// The guest is a fresh Linux VM (`rv-microvm`): no network interface, the
/// protected workspace volume shared at the same path, and only the
/// runtime's egress proxy and secret gateway relayed to guest loopback.
/// Unset sizes take `rv-microvm`'s defaults.
public struct MicroVMLaunchOptions: Sendable, Equatable, Codable {
    public static let cpuRange = 1...64
    public static let memoryRangeMiB = 256...1_048_576
    public static let maxImageBytes = 512

    public let image: String
    public let cpus: Int?
    public let memoryMiB: Int?

    /// Nil for an image that is empty, too long, not printable ASCII, or
    /// starts with `-`, or for a size out of range. `rv-microvm` performs
    /// the full reference grammar check; this only keeps the argv sane.
    public init?(image: String, cpus: Int? = nil, memoryMiB: Int? = nil) {
        guard Self.isAcceptableImage(image),
            cpus.map(Self.cpuRange.contains) ?? true,
            memoryMiB.map(Self.memoryRangeMiB.contains) ?? true
        else { return nil }
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
    }

    private enum CodingKeys: String, CodingKey {
        case image, cpus, memoryMiB
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(keys).isSubset(of: ["image", "cpus", "memoryMiB"]),
            let options = MicroVMLaunchOptions(
                image: try container.decode(String.self, forKey: .image),
                cpus: try container.decodeIfPresent(Int.self, forKey: .cpus),
                memoryMiB: try container.decodeIfPresent(Int.self, forKey: .memoryMiB)
            )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid micro-VM options")
            )
        }
        self = options
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(image, forKey: .image)
        try container.encodeIfPresent(cpus, forKey: .cpus)
        try container.encodeIfPresent(memoryMiB, forKey: .memoryMiB)
    }

    private static func isAcceptableImage(_ image: String) -> Bool {
        guard let first = image.unicodeScalars.first, first != "-",
            image.utf8.count <= maxImageBytes
        else { return false }
        return image.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Prepared micro-VM launch: the strictly resolved workspace it shares and
/// the caller's options.
struct MicroVMProfile: Sendable, Equatable {
    let workspacePath: String
    let options: MicroVMLaunchOptions
}

/// `rv-microvm`: location and state root.
public enum MicroVMHelper {
    public static let executableName = "rv-microvm"

    /// `~/.config/rv/microvm`: kernel, init filesystem, image cache.
    public static func stateRoot(home: String) -> String {
        "\(home)/.config/rv/microvm"
    }

    /// Same rules as `rv-pty-claim`: next to the running binary or in a
    /// build tree, never an environment override, never in the workspace.
    public static func locate(workspace: String) -> String? {
        resolvedHelperPath(named: executableName, workspace: workspace)
    }
}

/// Contained launch in a micro-VM. Pure checks first, then the same
/// workspace resolution and inode-alias scan the Seatbelt path runs.
///
/// Resource profiles may carry environment, keychain and secret entries,
/// which reach the guest as environment. Grants of host paths (links,
/// read/write trees, credential files) are refused: the guest sees only
/// the workspace.
func prepareMicroVM(
    _ plan: IsolationPlan,
    _ command: IsolatedCommand,
    options: MicroVMLaunchOptions,
    resourceProfile: RuntimeResourceProfile? = nil
) -> Result<IsolatedLaunchRequest, IsolationApplyError> {
    guard case .contained = plan.mode else {
        return .failure(.profileNotApplicable)
    }
    if let profile = resourceProfile {
        let grantsHostPaths = profile.executableLinks.isEmpty == false
            || profile.readFiles.isEmpty == false
            || profile.readTrees.isEmpty == false
            || profile.writeTrees.isEmpty == false
            || profile.credentials.isEmpty == false
        if grantsHostPaths {
            return .failure(.resourceStagingFailed(
                "resource profile \(profile.id) grants host paths, which micro-VM launches cannot share"
            ))
        }
    }
    guard let workspace = plan.workspace else {
        return .failure(.containedGuaranteesUnsupported)
    }
    let resolved: String
    switch existingResolvedWorkspacePath(workspace) {
    case .failure(let error):
        return .failure(error)
    case .success(let path):
        resolved = path
    }
    // The guest writes the shared tree directly; a hard link to an outside
    // inode would let it write that file too.
    if case .failure(let error) = rejectWorkspaceInodeAlias(resolved) {
        return .failure(error)
    }
    guard
        let request = IsolatedLaunchRequest(
            plan: plan,
            command: command,
            launch: .microvm(MicroVMProfile(workspacePath: resolved, options: options)),
            resources: resourceProfile.map(RuntimeResourceManifest.init),
            legacyAgentIntegration: false
        )
    else {
        return .failure(.backendMismatch)
    }
    return .success(request)
}

struct MicroVMSpawnCommand: Equatable {
    let path: String
    let arguments: [String]
}

/// argv that starts one `rv-microvm run`. A terminal launch goes through
/// the claim helper exactly like Seatbelt. Guest environment values never
/// appear here: only their names (`--forward-env`).
func microVMSpawnCommand(
    helper: String,
    claim: (path: String, slave: String)?,
    profile: MicroVMProfile,
    stateRoot: String,
    relayPorts: [Int],
    forwardedNames: [String],
    nonce: String,
    command: IsolatedCommand
) -> MicroVMSpawnCommand {
    var arguments: [String] = []
    let path: String
    if let claim {
        path = claim.path
        arguments = [claim.path, claim.slave]
    } else {
        path = helper
    }
    arguments += [
        helper, "run",
        "--root", stateRoot,
        "--image", profile.options.image,
        "--workspace", profile.workspacePath,
    ]
    if let cpus = profile.options.cpus { arguments += ["--cpus", String(cpus)] }
    if let memory = profile.options.memoryMiB { arguments += ["--memory-mib", String(memory)] }
    for port in relayPorts { arguments += ["--relay-port", String(port)] }
    for name in forwardedNames { arguments += ["--forward-env", name] }
    arguments += ["--handshake-fd", "3", "--nonce", nonce, "--", command.executable]
    arguments += command.arguments
    return MicroVMSpawnCommand(path: path, arguments: arguments)
}

/// Must match `GuestEnvironment.forwardedPrefix` in `Packages/rv-microvm`.
let microVMForwardedPrefix = "RV_GUEST_"

struct MicroVMRuntimeEnvironment: Equatable {
    /// envp of the `rv-microvm` process.
    let environment: [String]
    /// Names `rv-microvm` copies into the guest.
    let forwardedNames: [String]
}

/// Environment for `rv-microvm`: its own minimal host environment plus the
/// guest values it forwards by name. Guest values are the runtime's proxy
/// binding, resource-profile environment, and keychain/secret entries,
/// under the same name and value rules as the Seatbelt cage: a staged
/// keychain/secret entry replaces a profile value of the same name, so the
/// guest receives the staged value rather than a host copy. Runtime-managed
/// names (PATH, HOME, ...) and other proxy names are never forwarded: the
/// guest image defines them. Each guest value travels as
/// `RV_GUEST_<NAME>` so it never configures the entitled helper itself.
func microVMRuntimeEnvironment(
    hostEnvironment: [String: String],
    resources: RuntimeResourceManifest?,
    egressProxyPort: Int?,
    egressProxyCredential: EgressProxyCredential?,
    keychain: [(name: String, value: String)]
) -> MicroVMRuntimeEnvironment {
    var guest: [(String, String)] = []
    var profileNames = Set<String>()
    var stagedNames = Set<String>()
    func acceptable(_ name: String, _ value: String) -> Bool {
        ContainedEnvironmentPolicy.isValidName(name)
            && ContainedEnvironmentPolicy.isSaneValue(value)
            && value.utf8.count <= 8_192
            && ContainedEnvironmentPolicy.isManagedByRuntime(name) == false
            && name.uppercased().hasSuffix("_PROXY") == false
    }
    func forward(_ name: String, _ value: String) {
        guard acceptable(name, value), profileNames.insert(name).inserted else { return }
        guest.append((name, value))
    }
    for entry in resources?.profile.environment ?? [] {
        switch entry.resolvedSource {
        case .hostVariable(let variable):
            if let value = hostEnvironment[variable] { forward(entry.name, value) }
        case .literal(let literal):
            forward(entry.name, literal)
        case nil:
            continue
        }
    }
    for entry in keychain {
        guard acceptable(entry.name, entry.value), stagedNames.insert(entry.name).inserted else { continue }
        guest.removeAll { $0.0 == entry.name }
        guest.append((entry.name, entry.value))
    }
    if let port = egressProxyPort, (1...65535).contains(port) {
        let proxy = egressProxyURL(port: port, credential: egressProxyCredential)
        for name in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] {
            guest.append((name, proxy))
        }
        guest.append(("NO_PROXY", "localhost,127.0.0.1,::1"))
        guest.append(("no_proxy", "localhost,127.0.0.1,::1"))
    }
    var environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    if let home = hostEnvironment["HOME"], home.hasPrefix("/"), home.contains("\0") == false {
        environment.append("HOME=\(home)")
    }
    environment += guest.map { "\(microVMForwardedPrefix)\($0.0)=\($0.1)" }
    return MicroVMRuntimeEnvironment(environment: environment, forwardedNames: guest.map(\.0))
}
