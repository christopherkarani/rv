import Foundation

/// What an action does, from a fixed list. The on-device model picks one
/// of these and, optionally, an object copied from the command; the line
/// is then built here. The model never writes the sentence, so it has no
/// way to say "safe", "fine to run" or anything an agent planted for it.
public enum PlainEffect: String, Sendable, CaseIterable {
    case deletesFiles
    case overwritesFiles
    case changesPermissions
    case changesGitHistory
    case deletesResources
    case changesResources
    case deletesDatabaseData
    case sendsDataOut
    case downloadsFiles
    case installsSoftware
    case stopsServices
    case changesSystemSettings
    case readsFiles
    case runsAProgram

    /// The verb phrase, and the noun used when there is no object.
    var phrase: (verb: String, fallback: String) {
        switch self {
        case .deletesFiles: ("Would delete", "files")
        case .overwritesFiles: ("Would overwrite", "files")
        case .changesPermissions: ("Would change who can access", "files")
        case .changesGitHistory: ("Would rewrite git history in", "this repository")
        case .deletesResources: ("Would delete resources in", "a service")
        case .changesResources: ("Would change resources in", "a service")
        case .deletesDatabaseData: ("Would delete data from", "a database")
        case .sendsDataOut: ("Would send data to", "another computer")
        case .downloadsFiles: ("Would download", "files from the internet")
        case .installsSoftware: ("Would install", "software")
        case .stopsServices: ("Would stop", "a running service")
        case .changesSystemSettings: ("Would change system settings for", "this Mac")
        case .readsFiles: ("Would read", "files")
        case .runsAProgram: ("Would run", "a program")
        }
    }

    /// The line for this effect. `object` is kept only when it is a short
    /// run of characters copied exactly from `command` (comments removed)
    /// and says nothing about a decision; otherwise the generic noun is used.
    public func line(object: String?, command: String) -> PlainLine {
        let (verb, fallback) = phrase
        let noun = Self.copied(object, from: PlainShell.strippingComments(command)) ?? fallback
        return PlainLine(text: PlainText.clamp("\(verb) \(noun)"), source: .onDevice)
    }

    static let maxObjectLength = 40

    static func copied(_ object: String?, from command: String) -> String? {
        guard let object = object?.trimmingCharacters(in: .whitespacesAndNewlines), !object.isEmpty,
              object.count <= maxObjectLength,
              object == PlainSanitizer.normalized(object),
              command.contains(object),
              !object.contains(where: \.isNewline),
              !PlainSanitizer.claimsADecision(object) else { return nil }
        return object
    }
}
