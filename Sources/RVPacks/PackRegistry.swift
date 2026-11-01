import Foundation
import RVDomain

public enum PackRegistry {
    public static func loadIndex() throws -> PackIndex {
        try loadIndex(from: PackResourceBundle.require(PackResourceBundle.located))
    }

    public static func loadIndex(from bundle: Bundle) throws -> PackIndex {
        let data = try resourceData(named: "index", extension: "json", bundle: bundle)
        return try PackIndexJSON.decode(data)
    }

    public static func loadDayOne() throws -> [PackSnapshot] {
        try loadDayOne(from: PackResourceBundle.require(PackResourceBundle.located))
    }

    public static func loadDayOne(from bundle: Bundle) throws -> [PackSnapshot] {
        var snapshots: [PackSnapshot] = []
        for id in dayOnePackIDs {
            let document = try loadDocument(id, from: bundle)
            if document.safe.isEmpty && document.destructive.isEmpty {
                throw PackLoadError.emptyCorePack(id.rawValue)
            }
            snapshots.append(document.snapshot)
        }
        return snapshots.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public static func loadAll() throws -> [PackSnapshot] {
        try loadAllDocuments().map(\.snapshot)
    }

    public static func loadAllDocuments() throws -> [PackDocument] {
        try loadAllDocuments(from: PackResourceBundle.require(PackResourceBundle.located))
    }

    public static func loadAllDocuments(from bundle: Bundle) throws -> [PackDocument] {
        let index = try loadIndex(from: bundle)
        var documents: [PackDocument] = []
        documents.reserveCapacity(index.packCount)
        for id in index.packIDs {
            documents.append(try loadDocument(id, from: bundle))
        }
        return documents
    }

    public static func loadDocument(_ id: PackID) throws -> PackDocument {
        try loadDocument(id, from: PackResourceBundle.require(PackResourceBundle.located))
    }

    public static func loadDocument(_ id: PackID, from bundle: Bundle) throws -> PackDocument {
        let data = try resourceData(named: id.rawValue, extension: "json", bundle: bundle)
        return try PackJSON.decodeDocument(data)
    }

    private static func resourceData(named name: String, extension ext: String, bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "packs")
        else {
            throw PackLoadError.missingResource(name)
        }
        return try Data(contentsOf: url)
    }
}

/// Non-trapping stand-in for SwiftPM's generated `Bundle.module`.
///
/// The generated accessor traps when `rv_RVPacks.bundle` is missing next to
/// the binary; under launchd that is a crash loop in which
/// every hook is blocked. This lookup searches the same candidates the
/// generated accessor does and returns nil instead, so callers throw
/// `PackLoadError.missingResource` and `rvd` reports core packs unavailable
/// through the Hello skew path. When the bundle exists the result is the
/// same bundle the accessor would return.
enum PackResourceBundle {
    static let bundleName = "rv_RVPacks"

    static let located: Bundle? = locate(lazyCandidates: defaultCandidates())

    static func require(_ bundle: Bundle?) throws -> Bundle {
        guard let bundle else { throw PackLoadError.missingResource(bundleName) }
        return bundle
    }

    static func locate(candidates: [URL?]) -> Bundle? {
        locate(lazyCandidates: candidates.map { candidate in { candidate } })
    }

    /// Candidates are evaluated in order and only until one matches: the
    /// framework probe enumerates loaded bundles and is not free.
    private static func locate(lazyCandidates: [() -> URL?]) -> Bundle? {
        for candidate in lazyCandidates {
            guard let url = candidate()?.appendingPathComponent(bundleDirectoryName) else { continue }
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    #if canImport(Darwin)
    private static let bundleDirectoryName = bundleName + ".bundle"
    #else
    private static let bundleDirectoryName = bundleName + ".resources"
    #endif

    /// Mirrors `resource_bundle_accessor.swift`: the DEBUG-only
    /// `PACKAGE_RESOURCE_BUNDLE_PATH` / `_URL` override, then the main
    /// bundle's resources (app), this module's bundle (framework), and the
    /// main bundle URL (command-line tools: the executable's directory).
    /// Linux SwiftPM looks for `<name>.resources` beside the executable.
    private static func defaultCandidates() -> [() -> URL?] {
        var overrides: [() -> URL?] = []
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            overrides = [{ URL(fileURLWithPath: override) }]
        }
        #endif
        #if canImport(Darwin)
        return overrides + [
            { Bundle.main.resourceURL },
            { imageBundle().resourceURL },
            { Bundle.main.bundleURL },
        ]
        #else
        return overrides + [{ Bundle.main.bundleURL }]
        #endif
    }

    #if canImport(Darwin)
    /// `Bundle(for: SomeClassInThisModule.self)` without a class: the bundle
    /// whose executable is the image this code is linked into, else main.
    private static func imageBundle() -> Bundle {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return .main }
        let image = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
        let owner = (Bundle.allFrameworks + Bundle.allBundles).first {
            $0.executableURL?.resolvingSymlinksInPath() == image
        }
        return owner ?? .main
    }
    #endif
}
