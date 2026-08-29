#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

func matchesIncludeGlob(fileURL: URL, scanRoot: URL, patterns: [String]) -> Bool {
    guard patterns.isEmpty == false else { return false }
    let relative = relativePath(fileURL: fileURL, to: scanRoot)
    let name = fileURL.lastPathComponent
    for pattern in patterns {
        if posixFnmatch(pattern, relative, flags: FNM_PATHNAME) { return true }
        if posixFnmatch(pattern, name, flags: 0) { return true }
    }
    return false
}

/// POSIX `fnmatch` via Darwin or Glibc.
private func posixFnmatch(_ pattern: String, _ name: String, flags: Int32) -> Bool {
    pattern.withCString { patternC in
        name.withCString { nameC in
            fnmatch(patternC, nameC, flags) == 0
        }
    }
}

private func relativePath(fileURL: URL, to root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
    var suffix = String(filePath.dropFirst(rootPath.count))
    if suffix.hasPrefix("/") {
        suffix.removeFirst()
    }
    return suffix.isEmpty ? fileURL.lastPathComponent : suffix
}
