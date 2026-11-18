/// Operator caps for every Seatbelt-caged runtime and admission one-shot,
/// stored under `limits` in `runtime-resources.json`.
///
/// Absent fields take the defaults in `CageProcessLimits` (RVIsolation).
/// Core dumps are always disabled and are not configurable: a core file
/// can hold injected secrets or gateway placeholders. A cap only ever
/// lowers the limit the runtime inherits; it never raises one.
///
/// Decoding is strict: an unknown key refuses the whole document, so a
/// misspelled cap cannot silently fall back to the default.
public struct RuntimeProcessLimits: Codable, Sendable, Equatable {
    /// `RLIMIT_NOFILE`: open descriptors per process.
    public var openFiles: UInt64?
    /// `RLIMIT_FSIZE`: largest file a process may write, in bytes.
    public var fileSizeBytes: UInt64?
    /// `RLIMIT_CPU`: CPU seconds per process. Off unless set.
    public var cpuSeconds: UInt64?
    /// Wall-clock lifetime of one runtime, in seconds: the default for
    /// `rv workspace run`, and the ceiling `--timeout` may only shorten.
    public var timeoutSeconds: UInt64?

    public static let openFilesRange: ClosedRange<UInt64> = 64...1_048_576
    public static let fileSizeBytesRange: ClosedRange<UInt64> = 1_048_576...(1 << 50)
    public static let cpuSecondsRange: ClosedRange<UInt64> = 1...31_536_000
    public static let timeoutSecondsRange: ClosedRange<UInt64> = 1...604_800

    public init(
        openFiles: UInt64? = nil,
        fileSizeBytes: UInt64? = nil,
        cpuSeconds: UInt64? = nil,
        timeoutSeconds: UInt64? = nil
    ) {
        self.openFiles = openFiles
        self.fileSizeBytes = fileSizeBytes
        self.cpuSeconds = cpuSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case openFiles, fileSizeBytes, cpuSeconds, timeoutSeconds
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let raw = try decoder.container(keyedBy: AnyKey.self)
        guard raw.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown limits key")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openFiles = try container.decodeIfPresent(UInt64.self, forKey: .openFiles)
        fileSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .fileSizeBytes)
        cpuSeconds = try container.decodeIfPresent(UInt64.self, forKey: .cpuSeconds)
        timeoutSeconds = try container.decodeIfPresent(UInt64.self, forKey: .timeoutSeconds)
    }

    /// Every set field lies in its range.
    public var isValid: Bool {
        Self.fits(openFiles, Self.openFilesRange)
            && Self.fits(fileSizeBytes, Self.fileSizeBytesRange)
            && Self.fits(cpuSeconds, Self.cpuSecondsRange)
            && Self.fits(timeoutSeconds, Self.timeoutSecondsRange)
    }

    private static func fits(_ value: UInt64?, _ range: ClosedRange<UInt64>) -> Bool {
        value.map(range.contains) ?? true
    }
}
