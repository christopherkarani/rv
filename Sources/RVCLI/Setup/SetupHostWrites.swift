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
        try writeArtifacts(
            HostArtifacts.attach(
                host: host,
                layout: layout,
                existingData: existingData,
                forceClear: false
            ),
            existingData: existingData,
            env: env,
            layout: layout,
            files: files
        )
    }

    /// Executes adapter + companion writes already named on the plan step.
    static func writeArtifacts(
        _ write: HostAttachWrite,
        existingData: Data?,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> Bool {
        switch write.adapter {
        case .claudeSettingsMerge(let force):
            return try writeClaudeSettings(
                path: write.destination,
                rvPath: env.rvPath,
                existingData: existingData,
                force: force,
                files: files
            )
        case .writeOwnedRendered, .applyGrokThenWriteOwned:
            return try writeOwnedHost(
                write,
                existingData: existingData,
                env: env,
                layout: layout,
                files: files
            )
        }
    }

    private static func writeOwnedHost(
        _ write: HostAttachWrite,
        existingData: Data?,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> Bool {
        let adapter: HostAdapterResource
        do {
            adapter = try HostAdapterResources.load(for: write.host)
        } catch {
            throw SetupError(adapterResourceFailure: error)
        }
        do {
            let wroteAdapter: Bool
            if case .applyGrokThenWriteOwned = write.adapter {
                let applied = HostWiring.applyGrok(
                    existing: existingData,
                    rendered: Data(adapter.rendered(rvPath: env.rvPath).utf8)
                )
                guard let contents = String(data: applied.data, encoding: .utf8) else {
                    throw SetupError.hostHookWriteFailed(.grok)
                }
                wroteAdapter = try writeOwned(
                    path: write.destination,
                    contents: contents,
                    existingData: existingData,
                    files: files
                )
            } else {
                wroteAdapter = try writeOwned(
                    path: write.destination,
                    contents: adapter.rendered(rvPath: env.rvPath),
                    existingData: existingData,
                    files: files
                )
            }
            let wroteCompanions = try writeCompanions(
                write.companions,
                host: write.host,
                layout: layout,
                files: files
            )
            return wroteAdapter || wroteCompanions
        } catch {
            throw SetupError.hostHookWriteFailed(write.host)
        }
    }

    private static func writeCompanions(
        _ companions: [HostCompanionWrite],
        host: HookHost,
        layout: OwnedPaths,
        files: FileOps
    ) throws -> Bool {
        var wroteAny = false
        for companion in companions {
            let wrote: Bool
            switch companion {
            case .pluginManifest(let path):
                let pluginJSON = try HostAdapterResources.loadPluginManifest(for: host)
                wrote = try writeOwned(
                    path: path,
                    contents: pluginJSON,
                    existingData: files.readData(path),
                    files: files
                )
            case .packageManifest(let path):
                let packageJSON = try HostAdapterResources.loadPackageManifest(for: host)
                wrote = try writeOwned(
                    path: path,
                    contents: packageJSON,
                    existingData: files.readData(path),
                    files: files
                )
            case .openCodeTuiPlugin(let path):
                let tui = try HostAdapterResources.loadOpenCodeTuiPlugin()
                wrote = try writeOwned(
                    path: path,
                    contents: tui,
                    existingData: files.readData(path),
                    files: files
                )
            case .openCodeAskPackage:
                wrote = try writeOpenCodeTuiAskPackage(layout: layout, files: files)
            case .codexHooksJSON(let adapterPath, let hooksPath):
                wrote = try writeCodexHooksJSON(
                    adapterPath: adapterPath,
                    hooksPath: hooksPath,
                    files: files
                )
            case .cursorHooksJSON(let adapterPath, let hooksPath):
                wrote = try writeCursorHooksJSON(
                    adapterPath: adapterPath,
                    hooksPath: hooksPath,
                    files: files
                )
            }
            if wrote {
                wroteAny = true
            }
        }
        return wroteAny
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
