import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain
import RVEngine

/// Path / cwd / repo I/O for the filesystem analyzer. Classification stays pure.
enum FilesystemLiveProbe {
    static let symlinkHopLimit = 8

    static func context(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        homeDirectory: String?
    ) -> FilesystemAnalysisContext {
        let working = cwd?.rawValue
        let paths = filesystemApparentPaths(command)
        guard paths.isEmpty == false else {
            return FilesystemAnalysisContext(
                workingDirectory: cwd,
                homeDirectory: homeDirectory
            )
        }
        let facts = paths.map { apparent in
            resolve(
                apparent: apparent,
                workingDirectory: working,
                homeDirectory: homeDirectory
            )
        }
        return FilesystemAnalysisContext(
            workingDirectory: cwd,
            repositoryRoot: working.flatMap(discoverRepositoryRoot(from:)),
            homeDirectory: homeDirectory,
            catalog: .dayOne,
            facts: facts
        )
    }

    static func discoverRepositoryRoot(from cwd: String) -> RepositoryRoot? {
        var path = cwd
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        var seen = Set<String>()
        while seen.insert(path).inserted {
            let git = path == "/" ? "/.git" : path + "/.git"
            if FileManager.default.fileExists(atPath: git) {
                return RepositoryRoot(validating: path)
            }
            if path == "/" { break }
            path = lexicalParent(path)
        }
        return nil
    }

    static func resolve(
        apparent: String,
        workingDirectory: String?,
        homeDirectory: String?
    ) -> FilesystemPathFact {
        let started = lexicalFilesystemPath(
            apparent,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
        return follow(
            path: started,
            apparent: apparent,
            hops: 0,
            visited: [],
            followedSymlink: false
        )
    }
}

private enum LstatKind {
    case missing
    case symlink
    case other
    case error
}

private func follow(
    path: String,
    apparent: String,
    hops: Int,
    visited: Set<String>,
    followedSymlink: Bool
) -> FilesystemPathFact {
    if hops > FilesystemLiveProbe.symlinkHopLimit {
        return FilesystemPathFact(
            apparent: apparent,
            canonical: path,
            followedSymlink: followedSymlink,
            resolution: .uncertain
        )
    }

    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var resolved = path.hasPrefix("/") ? "/" : ""
    var hopsUsed = hops
    var visitedPaths = visited
    var followed = followedSymlink
    var index = 0
    while index < parts.count {
        let part = parts[index]
        let candidate: String
        if resolved.isEmpty {
            candidate = part
        } else if resolved == "/" {
            candidate = "/" + part
        } else {
            candidate = resolved + "/" + part
        }

        switch lstatKind(candidate) {
        case .missing:
            let remainder = parts[index...].joined(separator: "/")
            let lexical = resolved.isEmpty
                ? remainder
                : (resolved == "/" ? "/" + remainder : resolved + "/" + remainder)
            return FilesystemPathFact(
                apparent: apparent,
                canonical: collapseMissing(lexical),
                followedSymlink: followed,
                resolution: .lexical
            )
        case .error:
            return FilesystemPathFact(
                apparent: apparent,
                canonical: candidate,
                followedSymlink: followed,
                resolution: .uncertain
            )
        case .other:
            resolved = candidate
            index += 1
        case .symlink:
            if visitedPaths.contains(candidate) {
                return FilesystemPathFact(
                    apparent: apparent,
                    canonical: candidate,
                    followedSymlink: true,
                    resolution: .uncertain
                )
            }
            hopsUsed += 1
            if hopsUsed > FilesystemLiveProbe.symlinkHopLimit {
                return FilesystemPathFact(
                    apparent: apparent,
                    canonical: candidate,
                    followedSymlink: true,
                    resolution: .uncertain
                )
            }
            visitedPaths.insert(candidate)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
            else {
                return FilesystemPathFact(
                    apparent: apparent,
                    canonical: candidate,
                    followedSymlink: true,
                    resolution: .uncertain
                )
            }
            followed = true
            let destAbsolute: String
            if dest.hasPrefix("/") {
                destAbsolute = dest
            } else {
                destAbsolute = joinLive(lexicalParent(candidate), dest)
            }
            let destFact = follow(
                path: destAbsolute,
                apparent: apparent,
                hops: hopsUsed,
                visited: visitedPaths,
                followedSymlink: true
            )
            switch destFact.resolution {
            case .uncertain:
                return destFact
            case .resolved, .lexical:
                resolved = destFact.canonical
                index += 1
            }
        }
    }
    return FilesystemPathFact(
        apparent: apparent,
        canonical: resolved.isEmpty ? (path.hasPrefix("/") ? "/" : "") : resolved,
        followedSymlink: followed,
        resolution: followed ? .resolved : .lexical
    )
}

private func lstatKind(_ path: String) -> LstatKind {
    var info = stat()
    if lstat(path, &info) != 0 {
        return errno == ENOENT ? .missing : .error
    }
    if (info.st_mode & S_IFMT) == S_IFLNK {
        return .symlink
    }
    return .other
}

private func lexicalParent(_ path: String) -> String {
    if path == "/" { return "/" }
    var trimmed = path
    if trimmed.count > 1, trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard let slash = trimmed.lastIndex(of: "/") else { return "." }
    if slash == trimmed.startIndex { return "/" }
    return String(trimmed[..<slash])
}

private func joinLive(_ left: String, _ right: String) -> String {
    if right.hasPrefix("/") { return right }
    if left == "/" { return "/" + right }
    if left.hasSuffix("/") { return left + right }
    return left + "/" + right
}

private func collapseMissing(_ path: String) -> String {
    lexicalFilesystemPath(path, workingDirectory: nil, homeDirectory: nil)
}
