import Foundation
import RVDomain

/// Persistent runner config the script gate cannot model: a key that swaps
/// the shell every script runs under or preloads code into it (`.npmrc`
/// `script-shell` / `node-options`, `.yarnrc.yml` `shell`, `bunfig.toml`
/// `preload`). A command line can set these once (`npm config set`) and a
/// later, innocent-looking `npm test` runs under them, so a runner whose
/// package (or an ancestor, or the home directory) carries one is
/// unresolved. A file the scan cannot read counts as carrying one.
enum RunnerConfigScan {
    static let fileNames = [".npmrc", ".yarnrc", ".yarnrc.yml", "bunfig.toml", ".pnpmrc"]
    static let dangerousKeys = ["shell", "node-options", "nodeoptions", "node_options", "preload"]
    private static let maxBytes = 1 << 20

    static func swapsShellOrPreloads(packageDir: URL, home: HomePath?) -> Bool {
        var directories: [URL] = []
        var dir = packageDir.standardizedFileURL
        while true {
            directories.append(dir)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        directories.append(URL(fileURLWithPath: homePath, isDirectory: true))
        return directories.contains { directory in
            fileNames.contains { carriesDangerousKey(directory.appendingPathComponent($0)) }
        }
    }

    private static func carriesDangerousKey(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: file),
              let data = try? handle.read(upToCount: maxBytes)
        else { return true }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return dangerousKeys.contains { text.contains($0) }
    }
}
