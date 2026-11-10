import Foundation
import RVDomain

/// The interpreter a host's hook command starts. Claude, Codex, Cursor and
/// Antigravity run `python3 …/rv-guard.py`; when `python3` is missing the
/// shell exits 127 and those hosts treat it as a non-blocking hook error,
/// so the guard silently fails open. Other adapters load inside the host's
/// own runtime (pi, OpenCode, OpenClaw, Hermes) or exec `rv` directly
/// (Grok, Muse) and start no interpreter of their own.
enum AdapterRuntime {
    static let python3 = "python3"
    /// Ceiling for one `python3 -c` probe.
    static let probeTimeout: TimeInterval = 5

    static func interpreter(for host: HookHost) -> String? {
        switch host {
        case .claude, .codex, .cursor, .antigravity:
            python3
        case .grok, .pi, .opencode, .openclaw, .hermes, .muse:
            nil
        }
    }

    /// One line naming the hosts left unwired (setup) and why.
    static func setupRefusal(hosts: [HookHost], interpreter: String) -> String {
        let names = hosts.map(\.rawValue).joined(separator: ", ")
        return "rv setup: not wiring \(names): \(interpreter) is not runnable, so the hook would fail open "
            + "(the host treats a missing interpreter as a non-blocking error)\n"
            + "fix: \(installHint(interpreter)), then rerun rv setup\n"
    }

    static func installHint(_ interpreter: String) -> String {
        #if os(macOS)
        "install \(interpreter) (xcode-select --install, or brew install python)"
        #else
        "install \(interpreter) with your package manager (e.g. apt install python3)"
        #endif
    }

    /// Hosts whose hook is in place (wired or needing repair): the ones a
    /// missing interpreter leaves failing open.
    static func hooked(_ hosts: HostAdapterInstallationSnapshot) -> [HookHost] {
        HookHost.setupSlotOrder.filter { host in
            switch hosts.installation(for: host) {
            case .wired, .broken: true
            case .missing, .absentFile, .occupied: false
            }
        }
    }

    /// Live check: the first `name` on `pathEntries` runs `-c pass` and
    /// exits 0 within `probeTimeout`. macOS's `/usr/bin/python3` is a stub
    /// that exists without the developer tools, so presence alone is not
    /// proof.
    static func liveRunnable(_ name: String, pathEntries: [String]) -> Bool {
        let fileManager = FileManager.default
        guard let executable = pathEntries
            .map({ ($0 as NSString).appendingPathComponent(name) })
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "pass"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard exited.wait(timeout: .now() + probeTimeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

extension HostAdapterInstallation {
    /// Setup would write this host's hook without `--force`.
    var wouldWire: Bool {
        switch self {
        case .absentFile, .broken, .wired: true
        case .missing, .occupied: false
        }
    }
}
