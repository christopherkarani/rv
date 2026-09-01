import Foundation
import RVDomain

public enum PackRegistry {
    public static func loadIndex() throws -> PackIndex {
        try loadIndex(from: .module)
    }

    public static func loadIndex(from bundle: Bundle) throws -> PackIndex {
        let data = try resourceData(named: "index", extension: "json", bundle: bundle)
        return try PackIndexJSON.decode(data)
    }

    public static func loadDayOne() throws -> [PackSnapshot] {
        try loadDayOne(from: .module)
    }

    public static func loadDayOne(from bundle: Bundle) throws -> [PackSnapshot] {
        let names = dayOnePackIDs.map(\.rawValue)
        var snapshots: [PackSnapshot] = []
        for name in names {
            let document = try loadDocument(id: name, from: bundle)
            if document.safe.isEmpty && document.destructive.isEmpty {
                throw PackLoadError.emptyCorePack(name)
            }
            snapshots.append(document.snapshot)
        }
        return snapshots.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public static func loadAll() throws -> [PackSnapshot] {
        try loadAllDocuments().map(\.snapshot)
    }

    public static func loadAllDocuments() throws -> [PackDocument] {
        try loadAllDocuments(from: .module)
    }

    public static func loadAllDocuments(from bundle: Bundle) throws -> [PackDocument] {
        let index = try loadIndex(from: bundle)
        var documents: [PackDocument] = []
        documents.reserveCapacity(index.packCount)
        for id in index.packIDs {
            documents.append(try loadDocument(id: id.rawValue, from: bundle))
        }
        return documents
    }

    public static func loadDocument(id: String) throws -> PackDocument {
        try loadDocument(id: id, from: .module)
    }

    public static func loadDocument(id: String, from bundle: Bundle) throws -> PackDocument {
        let data = try resourceData(named: id, extension: "json", bundle: bundle)
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
