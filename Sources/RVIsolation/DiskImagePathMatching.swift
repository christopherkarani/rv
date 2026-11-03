#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// `/var` and `/private/var` are the same image, and so are `/tmp` and
/// `/private/tmp`, and a `/System/Volumes/Data` firmlink of either. Folding
/// is string work. It does not `lstat`, `stat`, or resolve symlinks.
/// `standardizedFileURL` stats a `/private/` path through `fileExists`.
/// This collapses `.` and `..` in the string instead.
/// A path that still differs matches the same `rv-inode-` file name.
/// Exact string equality is not what `hdiutil info` returns.
func diskImageCanonicalPath(_ path: String) -> String {
    diskImageFoldVolumeAlias(diskImageLexicalPath(path))
}

/// Lexical `.` / `..` collapse. Does not touch the filesystem.
func diskImageLexicalPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." {
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if absolute == false {
                parts.append("..")
            }
            continue
        }
        parts.append(String(part))
    }
    if absolute {
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/")
    }
    if parts.isEmpty { return "." }
    return parts.joined(separator: "/")
}

func diskImagePathTail(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    let tail = path[path.index(after: slash)...]
    if tail.isEmpty { return path == "/" ? "/" : String(path[..<slash]) }
    return String(tail)
}

func diskImageFoldVolumeAlias(_ path: String) -> String {
    let data = "/System/Volumes/Data"
    var text = path
    if text == data {
        text = "/"
    } else if text.hasPrefix(data + "/") {
        text = String(text.dropFirst(data.count))
        if text.isEmpty { text = "/" }
    }
    return diskImageFoldPrivatePrefix(text)
}

func diskImageFoldPrivatePrefix(_ path: String) -> String {
    if path == "/private/var" { return "/var" }
    if path == "/private/tmp" { return "/tmp" }
    let variable = "/private/var/"
    if path.hasPrefix(variable) {
        return "/var/" + path.dropFirst(variable.count)
    }
    let temporary = "/private/tmp/"
    if path.hasPrefix(temporary) {
        return "/tmp/" + path.dropFirst(temporary.count)
    }
    return path
}

func diskImageFoldPrivateVar(_ path: String) -> String {
    diskImageFoldPrivatePrefix(path)
}

func diskImageSameWorkspaceImageName(_ lhs: String, _ rhs: String) -> Bool {
    let left = diskImagePathTail(diskImageLexicalPath(lhs))
    let right = diskImagePathTail(diskImageLexicalPath(rhs))
    guard left == right, left.hasPrefix("rv-inode-"), left.hasSuffix(".sparseimage") else {
        return false
    }
    return left.count > "rv-inode-.sparseimage".count
}

func diskImageSamePath(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    if diskImageCanonicalPath(lhs) == diskImageCanonicalPath(rhs) { return true }
    return diskImageSameWorkspaceImageName(lhs, rhs)
}

func diskImageSameDevice(_ lhs: String, _ rhs: String) -> Bool {
    final class Pair: @unchecked Sendable {
        var left = stat()
        var right = stat()
    }
    let pair = Pair()
    let statedLeft = diskImagePerformWithinCopyClock {
        lhs.withCString { stat($0, &pair.left) == 0 }
    }
    let statedRight = diskImagePerformWithinCopyClock {
        rhs.withCString { stat($0, &pair.right) == 0 }
    }
    guard statedLeft == true, statedRight == true else { return false }
    return pair.left.st_dev == pair.right.st_dev
}

/// An empty `hdiutil info`, or a mount point hdiutil does not report, is
/// not proof the disk is gone. `nil` keeps `diskImageCanStillAppear` true.
/// A non-empty listing that omits an image path is the only false result.
/// The same image under `/var` and `/private/var` is still listed.
func diskImageInfoListingShowsImage(
    parsedImageCount: Int,
    identity: String,
    imagePaths: [String],
    mountPoints: [String] = []
) -> Bool? {
    if parsedImageCount == 0 { return nil }
    let isImage = identity.contains("rv-inode-") && identity.hasSuffix(".sparseimage")
    if isImage {
        return imagePaths.contains { diskImageSamePath($0, identity) }
    }
    if mountPoints.contains(where: { diskImageSamePath($0, identity) }) { return true }
    if imagePaths.contains(where: { diskImageSamePath($0, identity) }) { return true }
    return nil
}
