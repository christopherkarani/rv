import Foundation

/// A prepared macOS guest image name: a lowercase slug, so it is always a
/// single safe path component.
public struct MacVMImageName: Sendable, Equatable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public static func validate(_ raw: String) -> MacVMImageName? {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        guard let first = raw.unicodeScalars.first, raw.utf8.count <= 63, first != "-",
            raw.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return nil }
        return MacVMImageName(value: raw)
    }

    /// `RunOptions.validate` image normalizer for macOS guests.
    public static func normalize(_ raw: String) -> Result<String, MicroVMOptionError> {
        validate(raw).map { .success($0.value) } ?? .failure(.invalidImage(raw))
    }
}

public enum MacVMRun {
    /// Apple's macOS guests need 4 GiB; Xcode builds want more.
    public static let minimumMemoryMiB = 4096
    public static let defaultCPUs = 4
    public static let defaultMemoryMiB = 8192
    /// Boot to agent-ready. A cold macOS boot takes about 30 seconds.
    public static let agentTimeoutSeconds = 180
}

/// `rv-macvm` state: `images/<name>/` holds one prepared image, `runs/`
/// the per-run clones (deleted when the run ends), `cache/` restore images.
public struct MacVMLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var images: URL { root.appendingPathComponent("images", isDirectory: true) }
    public var runs: URL { root.appendingPathComponent("runs", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    public func image(_ name: MacVMImageName) -> URL {
        images.appendingPathComponent(name.value, isDirectory: true)
    }

    public static let diskName = "disk.img"
    public static let auxiliaryStorageName = "aux.img"
    public static let recordName = "image.json"

    public func disk(_ name: MacVMImageName) -> URL { image(name).appendingPathComponent(Self.diskName) }
    public func auxiliaryStorage(_ name: MacVMImageName) -> URL { image(name).appendingPathComponent(Self.auxiliaryStorageName) }
    public func record(_ name: MacVMImageName) -> URL { image(name).appendingPathComponent(Self.recordName) }
}

/// `image.json`: written last by `prepare`, so its presence means the image
/// is complete.
public struct MacVMImageRecord: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    /// `VZMacHardwareModel.dataRepresentation`.
    public let hardwareModel: Data
    public let osVersion: String
    public let osBuild: String
    /// sha256 of the agent installed in the image, verified at prepare.
    /// `run` relies on the protocol version for compatibility instead, so an
    /// rv update does not force a 25 GB re-prepare; `status` reports an
    /// agent that is not this rv's (see `agentUpdateNote`).
    public let agentSHA256: String
    public let user: String

    public init(hardwareModel: Data, osVersion: String, osBuild: String, agentSHA256: String, user: String) {
        self.version = Self.currentVersion
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.agentSHA256 = agentSHA256
        self.user = user
    }

    /// Nil when the image runs this rv's agent; otherwise how to update it.
    /// Agent fixes reach an existing image only through a new prepare.
    public func agentUpdateNote(image: MacVMImageName, currentAgentSHA256: String) -> String? {
        guard agentSHA256 != currentAgentSHA256 else { return nil }
        return "image \(image) has a guest agent from another rv build; "
            + "to update it: rv-macvm prepare --image \(image) --replace"
    }

    private enum CodingKeys: String, CodingKey {
        case version, hardwareModel, osVersion, osBuild, agentSHA256, user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "image format \(version) is not supported"
            )
        }
        hardwareModel = try container.decode(Data.self, forKey: .hardwareModel)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        osBuild = try container.decode(String.self, forKey: .osBuild)
        agentSHA256 = try container.decode(String.self, forKey: .agentSHA256)
        user = try container.decode(String.self, forKey: .user)
    }
}
