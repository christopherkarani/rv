import Foundation
import RVDomain

public struct ScanWarning: Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Fail-closed when the walk root cannot be listed.
public enum DirectoryWalkError: Error, Sendable, Equatable {
    case listingFailed(String)
}

/// Result of a bounded directory walk (discovery only; no extract).
public struct DirectoryWalkResult: Sendable, Equatable {
    public var fileURLs: [URL]
    public var warnings: [ScanWarning]
    public var filesVisited: Int
    public var bytesAccounted: Int64
    public var skippedOversize: Int

    public init(
        fileURLs: [URL] = [],
        warnings: [ScanWarning] = [],
        filesVisited: Int = 0,
        bytesAccounted: Int64 = 0,
        skippedOversize: Int = 0
    ) {
        self.fileURLs = fileURLs
        self.warnings = warnings
        self.filesVisited = filesVisited
        self.bytesAccounted = bytesAccounted
        self.skippedOversize = skippedOversize
    }
}

/// Walks a tree under `ScanBounds`, emitting structured cap warnings.
public struct DirectoryWalker: Sendable {
    public var bounds: ScanBounds

    public init(bounds: ScanBounds = .default) {
        self.bounds = bounds
    }

    public func walk(root: URL, fileManager: FileManager = .default) throws -> DirectoryWalkResult {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DirectoryWalkError.listingFailed(root.path)
        }

        var fileURLs: [URL] = []
        var warnings: [ScanWarning] = []
        var bytesAccounted: Int64 = 0
        var filesVisited = 0
        var skippedOversize = 0
        var stopped = false
        var depthWarned = false
        var bytesWarned = false
        var filesWarned = false
        var fileSizeWarned = false

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
        ]

        var queue: [(url: URL, depth: Int)] = [(root, 0)]

        while queue.isEmpty == false, stopped == false {
            let (directory, depth) = queue.removeFirst()
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                )
            } catch {
                if depth == 0 {
                    throw DirectoryWalkError.listingFailed(directory.path)
                }
                warnings.append(
                    ScanWarning(
                        code: "io.list",
                        message: "Failed to list \(directory.path)"
                    )
                )
                continue
            }

            for item in contents.sorted(by: { $0.path < $1.path }) {
                if stopped { break }

                let childDepth = depth + 1
                if childDepth > bounds.maxDepth {
                    if depthWarned == false {
                        warnings.append(
                            ScanWarning(
                                code: "cap.depth",
                                message: "Stopped descending past depth \(bounds.maxDepth)"
                            )
                        )
                        depthWarned = true
                    }
                    continue
                }

                let values: URLResourceValues
                do {
                    values = try item.resourceValues(forKeys: keys)
                } catch {
                    warnings.append(
                        ScanWarning(
                            code: "io.stat",
                            message: "Failed to read metadata for \(item.path)"
                        )
                    )
                    continue
                }

                if values.isSymbolicLink == true {
                    continue
                }

                if values.isDirectory == true {
                    queue.append((item.standardizedFileURL, childDepth))
                    continue
                }

                if values.isRegularFile != true {
                    if values.isSymbolicLink == nil,
                       values.isDirectory == nil,
                       values.isRegularFile == nil {
                        warnings.append(
                            ScanWarning(
                                code: "io.stat",
                                message: "Failed to read metadata for \(item.path)"
                            )
                        )
                    }
                    continue
                }

                if filesVisited >= bounds.maxFiles {
                    if filesWarned == false {
                        warnings.append(
                            ScanWarning(
                                code: "cap.files",
                                message: "Stopped after \(bounds.maxFiles) files"
                            )
                        )
                        filesWarned = true
                    }
                    stopped = true
                    break
                }

                let size = Int64(values.fileSize ?? 0)
                if size > bounds.maxFileBytes {
                    if fileSizeWarned == false {
                        warnings.append(
                            ScanWarning(
                                code: "cap.file-size",
                                message: "Skipped file over \(bounds.maxFileBytes) bytes"
                            )
                        )
                        fileSizeWarned = true
                    }
                    skippedOversize += 1
                    filesVisited += 1
                    continue
                }

                if bytesAccounted + size > bounds.maxTotalBytes {
                    if bytesWarned == false {
                        warnings.append(
                            ScanWarning(
                                code: "cap.bytes",
                                message: "Stopped after \(bounds.maxTotalBytes) total bytes"
                            )
                        )
                        bytesWarned = true
                    }
                    stopped = true
                    break
                }

                fileURLs.append(item.standardizedFileURL)
                filesVisited += 1
                bytesAccounted += size
            }
        }

        return DirectoryWalkResult(
            fileURLs: fileURLs,
            warnings: warnings,
            filesVisited: filesVisited,
            bytesAccounted: bytesAccounted,
            skippedOversize: skippedOversize
        )
    }
}
