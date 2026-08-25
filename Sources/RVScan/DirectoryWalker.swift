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

/// Result of a bounded directory walk (discovery only; no extract).
public struct DirectoryWalkResult: Sendable, Equatable {
    public var fileURLs: [URL]
    public var warnings: [ScanWarning]
    public var filesVisited: Int
    public var bytesAccounted: Int64

    public init(
        fileURLs: [URL] = [],
        warnings: [ScanWarning] = [],
        filesVisited: Int = 0,
        bytesAccounted: Int64 = 0
    ) {
        self.fileURLs = fileURLs
        self.warnings = warnings
        self.filesVisited = filesVisited
        self.bytesAccounted = bytesAccounted
    }
}

/// Walks a tree under `ScanBounds`, emitting structured cap warnings.
public struct DirectoryWalker: Sendable {
    public var bounds: ScanBounds

    public init(bounds: ScanBounds = .default) {
        self.bounds = bounds
    }

    public func walk(root: URL, fileManager: FileManager = .default) -> DirectoryWalkResult {
        let root = root.standardizedFileURL
        var fileURLs: [URL] = []
        var warnings: [ScanWarning] = []
        var bytesAccounted: Int64 = 0
        var stopped = false
        var depthWarned = false
        var bytesWarned = false
        var filesWarned = false

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
                    continue
                }

                if values.isSymbolicLink == true {
                    continue
                }

                if values.isDirectory == true {
                    queue.append((item.standardizedFileURL, childDepth))
                    continue
                }

                guard values.isRegularFile == true else { continue }

                let size = Int64(values.fileSize ?? 0)
                if size > bounds.maxFileBytes {
                    warnings.append(
                        ScanWarning(
                            code: "cap.file-size",
                            message: "Skipped file over \(bounds.maxFileBytes) bytes"
                        )
                    )
                    continue
                }

                if fileURLs.count >= bounds.maxFiles {
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
                bytesAccounted += size
            }
        }

        return DirectoryWalkResult(
            fileURLs: fileURLs,
            warnings: warnings,
            filesVisited: fileURLs.count,
            bytesAccounted: bytesAccounted
        )
    }
}
