/// An operator-authored resource grant. Names describe UI choices only; they
/// never select authority from the executable basename or a detected agent.
public struct RuntimeResourceProfile: Codable, Sendable, Equatable {
    public struct Credential: Codable, Sendable, Equatable {
        public var source: String
        public var destination: String
        /// Agent hook names this credential stages for. Nil or empty
        /// means every launch; otherwise only launches whose hook name
        /// matches. Hook-less launches (shells) stage only unfiltered
        /// credentials, so agent secrets never land in a plain shell.
        public var agents: [String]?

        public init(source: String, destination: String, agents: [String]? = nil) {
            self.source = source
            self.destination = destination
            self.agents = agents
        }
    }

    public struct Environment: Codable, Sendable, Equatable {
        public var name: String
        /// Name of a variable in the trusted host's environment.
        public var hostVariable: String?
        /// Explicit non-secret constant, such as a gateway placeholder or
        /// a tool self-update disable flag.
        public var literalValue: String?

        public init(name: String, hostVariable: String) {
            self.name = name
            self.hostVariable = hostVariable
            self.literalValue = nil
        }

        public init(name: String, literalValue: String) {
            self.name = name
            self.hostVariable = nil
            self.literalValue = literalValue
        }
    }

    public struct ExecutableLink: Codable, Sendable, Equatable {
        public var name: String
        public var target: String

        public init(name: String, target: String) {
            self.name = name
            self.target = target
        }
    }

    /// A host-keychain secret the unsandboxed host reads at launch and
    /// injects as one environment variable. The sandbox never touches
    /// the keychain. `field` selects a string from a JSON secret;
    /// without it the whole secret must decode as UTF-8 text.
    public struct KeychainEntry: Codable, Sendable, Equatable {
        public var service: String
        public var account: String
        public var field: String?
        public var env: String
        /// Agent hook names this entry injects for. Nil or empty means
        /// every launch; otherwise only launches whose agent tag matches.
        public var agents: [String]?

        public init(
            service: String, account: String, field: String? = nil,
            env: String, agents: [String]? = nil
        ) {
            self.service = service
            self.account = account
            self.field = field
            self.env = env
            self.agents = agents
        }
    }

    public var id: String
    /// Canonical original project paths. Empty means no project is eligible.
    public var projects: [String]
    /// Agent launcher ids this profile serves (e.g. "muse", "codex").
    /// Empty means legacy behavior: serves entries matching its executableLink names.
    public var agents: [String]
    public var executableLinks: [ExecutableLink]
    public var readFiles: [String]
    public var readTrees: [String]
    public var writeTrees: [String]
    public var credentials: [Credential]
    public var environment: [Environment]
    public var keychain: [KeychainEntry]

    public init(
        id: String,
        projects: [String],
        agents: [String] = [],
        executableLinks: [ExecutableLink] = [],
        readFiles: [String] = [],
        readTrees: [String] = [],
        writeTrees: [String] = [],
        credentials: [Credential] = [],
        environment: [Environment] = [],
        keychain: [KeychainEntry] = []
    ) {
        self.id = id
        self.projects = projects
        self.agents = agents
        self.executableLinks = executableLinks
        self.readFiles = readFiles
        self.readTrees = readTrees
        self.writeTrees = writeTrees
        self.credentials = credentials
        self.environment = environment
        self.keychain = keychain
    }

    private enum CodingKeys: String, CodingKey {
        case id, projects, agents, executableLinks, readFiles, readTrees
        case writeTrees, credentials, environment, keychain
    }

    /// Backward compatible: documents written before `agents` existed decode
    /// with an empty mark list, preserving legacy link-name behavior.
    /// Documents written before `keychain` decode with no keychain entries.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projects = try container.decode([String].self, forKey: .projects)
        agents = try container.decodeIfPresent([String].self, forKey: .agents) ?? []
        executableLinks = try container.decode([ExecutableLink].self, forKey: .executableLinks)
        readFiles = try container.decode([String].self, forKey: .readFiles)
        readTrees = try container.decode([String].self, forKey: .readTrees)
        writeTrees = try container.decode([String].self, forKey: .writeTrees)
        credentials = try container.decode([Credential].self, forKey: .credentials)
        environment = try container.decode([Environment].self, forKey: .environment)
        keychain = try container.decodeIfPresent([KeychainEntry].self, forKey: .keychain) ?? []
    }
}

/// Fallback launcher agent ids, offered as direct host-PATH rows when no
/// policy entry covers them. Profile `agents` marks accept any identifier;
/// marked names derive their own rows, so new agents never need source edits.
public enum RuntimeAgentEntries {
    public static let known: [String] = ["claude", "codex", "opencode", "muse"]
}

public struct RuntimeResourcePolicy: Codable, Sendable, Equatable {
    public var version: Int
    public var profiles: [RuntimeResourceProfile]
    /// Operator-declared default shell profile id. The TUI attaches it to
    /// the auto-opened shell; the host still requires every launch to
    /// name its profile explicitly and never consults this field.
    public var defaultProfile: String?

    public init(
        version: Int = 1,
        profiles: [RuntimeResourceProfile] = [],
        defaultProfile: String? = nil
    ) {
        self.version = version
        self.profiles = profiles
        self.defaultProfile = defaultProfile
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, defaultProfile
    }

    /// Backward compatible: documents written before `defaultProfile` existed
    /// decode with no default, preserving today's behavior exactly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        profiles = try container.decode([RuntimeResourceProfile].self, forKey: .profiles)
        defaultProfile = try container.decodeIfPresent(String.self, forKey: .defaultProfile)
    }

    public static let empty = RuntimeResourcePolicy()

    public func profile(id: String, project: String) -> RuntimeResourceProfile? {
        profiles.first { $0.id == id && $0.projects.contains(project) }
    }
}
