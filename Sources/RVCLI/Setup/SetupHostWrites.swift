import Foundation
import RVDomain
import RVHooks

extension SetupRun {
    static func writeHost(
        _ host: HookHost,
        existingData: Data?,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> Bool {
        let adapter: HostAdapterResource
        do {
            adapter = try HostAdapterResources.load(for: host)
        } catch {
            throw SetupError(adapterResourceFailure: error)
        }
        do {
            let destination = layout.hostAdapter(for: host).destination
            let wroteAdapter: Bool
            if host == .grok {
                let applied = HostWiring.applyGrok(
                    existing: existingData,
                    rendered: Data(adapter.rendered(rvPath: env.rvPath).utf8)
                )
                guard let contents = String(data: applied.data, encoding: .utf8) else {
                    throw SetupError.hostHookWriteFailed(.grok)
                }
                wroteAdapter = try writeOwned(
                    path: destination,
                    contents: contents,
                    existingData: existingData,
                    files: files
                )
            } else {
                wroteAdapter = try writeOwned(
                    path: destination,
                    contents: adapter.rendered(rvPath: env.rvPath),
                    existingData: existingData,
                    files: files
                )
            }
            let wroteCompanions = try writeCompanions(
                host,
                directory: (destination as NSString).deletingLastPathComponent,
                layout: layout,
                files: files
            )
            return wroteAdapter || wroteCompanions
        } catch {
            throw SetupError.hostHookWriteFailed(host)
        }
    }

    private static func writeCompanions(
        _ host: HookHost,
        directory: String,
        layout: OwnedPaths,
        files: FileOps
    ) throws -> Bool {
        switch host {
        case .openclaw:
            let pluginJSON = try HostAdapterResources.loadPluginManifest(for: host)
            let packageJSON = try HostAdapterResources.loadPackageManifest(for: host)
            let pluginPath = directory + "/openclaw.plugin.json"
            let packagePath = directory + "/package.json"
            let wrotePlugin = try writeOwned(
                path: pluginPath,
                contents: pluginJSON,
                existingData: files.readData(pluginPath),
                files: files
            )
            let wrotePackage = try writeOwned(
                path: packagePath,
                contents: packageJSON,
                existingData: files.readData(packagePath),
                files: files
            )
            return wrotePlugin || wrotePackage
        case .hermes:
            let pluginYAML = try HostAdapterResources.loadPluginManifest(for: host)
            let pluginPath = directory + "/plugin.yaml"
            return try writeOwned(
                path: pluginPath,
                contents: pluginYAML,
                existingData: files.readData(pluginPath),
                files: files
            )
        case .opencode:
            let tui = try HostAdapterResources.loadOpenCodeTuiPlugin()
            let wroteTui = try writeOwned(
                path: directory + "/rv-guard-tui.js",
                contents: tui,
                existingData: files.readData(directory + "/rv-guard-tui.js"),
                files: files
            )
            let wroteAsk = try writeOpenCodeTuiAskPackage(layout: layout, files: files)
            return wroteTui || wroteAsk
        case .codex:
            return try writeCodexHooksJSON(
                adapterPath: directory + "/rv-guard.py",
                hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json",
                files: files
            )
        case .cursor:
            return try writeCursorHooksJSON(
                adapterPath: directory + "/rv-guard.py",
                hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json",
                files: files
            )
        case .grok, .pi, .claude:
            return false
        }
    }

    private static func writeOpenCodeTuiAskPackage(layout: OwnedPaths, files: FileOps) throws -> Bool {
        let packageJSONPath = layout.openCodeTuiAskPackage + "/package.json"
        let tuiPath = layout.openCodeTuiAskPackage + "/tui.js"
        let wrotePackage = try writeOwned(
            path: packageJSONPath,
            contents: OpenCodeTuiAskPackage.packageJSON,
            existingData: files.readData(packageJSONPath),
            files: files
        )
        let wroteTui = try writeOwned(
            path: tuiPath,
            contents: OpenCodeTuiAskPackage.tuiJS,
            existingData: files.readData(tuiPath),
            files: files
        )
        var wroteConfig = false
        do {
            let merged = try OpenCodeConfigMerge.merge(
                existingData: files.readData(layout.openCodeConfig),
                pluginPath: layout.openCodeTuiAskPackage
            )
            if merged.wrote {
                try files.writeData(merged.data, to: layout.openCodeConfig)
                wroteConfig = true
            }
        } catch OpenCodeConfigMergeError.invalidJSON {
            // Foreign / broken config stays; globbed server() plugin still loads.
        }
        return wrotePackage || wroteTui || wroteConfig
    }

    static func stripOpenCodeAskPlugin(layout: OwnedPaths, files: FileOps) throws(SetupError) {
        guard let existing = files.readData(layout.openCodeConfig) else {
            return
        }
        let next: Data?
        do {
            next = try OpenCodeConfigMerge.strip(
                existingData: existing,
                pluginPath: layout.openCodeTuiAskPackage
            )
        } catch OpenCodeConfigMergeError.invalidJSON {
            return
        } catch {
            throw SetupError.hostHookWriteFailed(.opencode)
        }
        do {
            if let next {
                if next != existing {
                    try files.writeData(next, to: layout.openCodeConfig)
                }
            } else {
                files.removeFile(atPath: layout.openCodeConfig)
            }
        } catch {
            throw SetupError.hostHookWriteFailed(.opencode)
        }
    }

    /// Merges the Codex PreToolUse registration for `adapterPath` into `hooks.json`.
    private static func writeCodexHooksJSON(
        adapterPath: String,
        hooksPath: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(hooksPath) {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        let merged: (data: Data, wrote: Bool)
        do {
            merged = try CodexHooksMerge.merge(
                existingData: files.readData(hooksPath),
                adapterPath: adapterPath
            )
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        if merged.wrote == false {
            return false
        }
        do {
            try files.writeData(merged.data, to: hooksPath)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        return true
    }

    /// Merges the Cursor beforeShellExecution registration for `adapterPath` into `hooks.json`.
    private static func writeCursorHooksJSON(
        adapterPath: String,
        hooksPath: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(hooksPath) {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        let merged: (data: Data, wrote: Bool)
        do {
            let applied = try HostWiring.applyCursor(
                existing: files.readData(hooksPath),
                adapterPath: adapterPath
            )
            merged = (applied.data, applied.wrote)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        if merged.wrote == false {
            return false
        }
        do {
            try files.writeData(merged.data, to: hooksPath)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        return true
    }

    /// Writes the exclusive Claude adapter and settings merge. Returns whether a write occurred.
    static func writeClaudeSettings(
        path: String,
        rvPath: String,
        existingData: Data?,
        force: Bool,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        let adapterPath = ClaudeSettingsMerge.adapterPath(settingsPath: path)
        if files.isSymbolicLink(adapterPath) {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        let adapter: HostAdapterResource
        do {
            adapter = try HostAdapterResources.load(for: .claude)
        } catch {
            throw SetupError(adapterResourceFailure: error)
        }
        let wroteAdapter: Bool
        do {
            wroteAdapter = try writeOwned(
                path: adapterPath,
                contents: adapter.rendered(rvPath: rvPath),
                existingData: files.readData(adapterPath),
                files: files
            )
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        let merged: (data: Data, wrote: Bool)
        do {
            let applied = try HostWiring.applyClaude(
                existing: existingData,
                rvPath: rvPath,
                adapterPath: adapterPath,
                force: force
            )
            merged = (applied.data, applied.wrote)
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        if merged.wrote == false {
            return wroteAdapter
        }
        do {
            try files.writeData(merged.data, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        return true
    }

    /// Writes `contents` when missing or different. Returns whether a write occurred.
    private static func writeOwned(
        path: String,
        contents: String,
        existingData: Data?,
        files: FileOps
    ) throws -> Bool {
        let payload = Data(contents.utf8)
        if existingData == payload {
            return false
        }
        try files.write(contents, to: path)
        return true
    }
}
