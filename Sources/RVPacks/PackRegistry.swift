import Foundation
import RVDomain

public enum PackRegistry {
    public static func loadDayOne() throws -> [PackSnapshot] {
        try loadDayOne(from: .module)
    }

    public static func loadDayOne(from bundle: Bundle) throws -> [PackSnapshot] {
        let names = ["core.filesystem", "core.git"]
        var snapshots: [PackSnapshot] = []
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: "json")
                    ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "packs")
            else {
                throw PackLoadError.missingResource(name)
            }
            let data = try Data(contentsOf: url)
            let snapshot = try PackJSON.decode(data)
            if snapshot.safe.isEmpty && snapshot.destructive.isEmpty {
                throw PackLoadError.emptyCorePack(name)
            }
            snapshots.append(snapshot)
        }
        return snapshots.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
