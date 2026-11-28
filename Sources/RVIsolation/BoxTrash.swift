import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `rv box tidy`'s trash: leftovers wait here for `BoxTidy.trashDays`
/// before they are emptied, so anything tidy moved can be put back.
///
/// Each leftover gets an entry folder of its own,
/// `<root>/<seconds since 1970>-<uuid>/`, holding the file under its own
/// name and `origin.json` (where it came from). Moves are a `rename(2)`
/// only: a leftover on another volume stays where it is rather than be
/// copied, and nothing is deleted outside the trash.
public struct BoxTrash: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<rv config>/box-trash`.
    public init(configDirectory: URL) {
        self.init(root: configDirectory.appendingPathComponent("box-trash", isDirectory: true))
    }

    public enum MoveFailure: Error, Sendable, Equatable {
        /// Not a plain file (a folder, a link, or gone).
        case notAFile
        /// The trash folder could not be made.
        case trashUnavailable
        /// `rename` refused (another volume, permissions).
        case notMoved(String)
    }

    struct Origin: Codable, Equatable {
        var from: String
        var trashedAt: Date
    }

    /// Moves one leftover file into a new entry. Returns the entry.
    public func move(_ path: String, now: Date) -> Result<BoxTrashEntry, MoveFailure> {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return .failure(.notAFile) }
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.trashUnavailable)
        }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let entry = root.appendingPathComponent("\(seconds)-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: entry, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            let origin = try JSONEncoder.trash.encode(Origin(from: path, trashedAt: now))
            try origin.write(to: entry.appendingPathComponent("origin.json"), options: .withoutOverwriting)
        } catch {
            try? manager.removeItem(at: entry)
            return .failure(.trashUnavailable)
        }
        let target = entry.appendingPathComponent((path as NSString).lastPathComponent).path
        guard rename(path, target) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: entry)
            return .failure(.notMoved(reason))
        }
        // Dated as `entries()` will read it back: whole seconds.
        return .success(BoxTrashEntry(path: entry.path, trashedAt: Date(timeIntervalSince1970: TimeInterval(seconds))))
    }

    /// Every entry, dated by its folder name. A folder whose name is not
    /// an entry's is not tidy's and is never listed (or emptied).
    public func entries() -> [BoxTrashEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard let date = Self.entryDate(name) else { return nil }
            return BoxTrashEntry(path: root.appendingPathComponent(name, isDirectory: true).path, trashedAt: date)
        }.sorted { $0.path < $1.path }
    }

    /// Where an entry's file came from, when its `origin.json` reads.
    public func origin(of entry: BoxTrashEntry) -> String? {
        let url = URL(fileURLWithPath: entry.path).appendingPathComponent("origin.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder.trash.decode(Origin.self, from: data))?.from
    }

    /// Empties one entry for good. Only a real folder directly inside the
    /// trash whose name is an entry's; anything else is left alone. An
    /// entry holding a file that is attached now (by file name, from
    /// `attachedNames`) stays, and so does every entry when
    /// `attachedNames` is nil (rv could not tell what is attached).
    @discardableResult
    public func empty(_ entry: BoxTrashEntry, attachedNames: Set<String>?) -> Bool {
        let url = URL(fileURLWithPath: entry.path)
        guard let attachedNames,
            url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
            Self.entryDate(url.lastPathComponent) != nil,
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            let contents = try? FileManager.default.contentsOfDirectory(atPath: entry.path),
            contents.contains(where: attachedNames.contains) == false
        else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// `<seconds>-<uuid>` → the time it was trashed.
    static func entryDate(_ name: String) -> Date? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let seconds = Int64(parts[0]), seconds >= 0,
            UUID(uuidString: String(parts[1])) != nil
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

private extension JSONEncoder {
    static var trash: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var trash: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
