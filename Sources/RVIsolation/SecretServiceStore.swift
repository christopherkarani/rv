#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Linux store for the values rv keeps itself (`rv secrets set`, `rv login
/// connect`, `rv mcp import`) and for `keychain` sources: the freedesktop
/// Secret Service (GNOME Keyring, KWallet, KeePassXC) through `secret-tool`
/// from libsecret-tools. Items carry the attributes `service` and `account`,
/// the Keychain's two names, so a `keychain` source reads the same item on
/// either platform.
///
/// - Values travel on stdin and stdout only, never in argv or the
///   environment.
/// - `secret-tool` is resolved from root-owned system paths, never PATH.
/// - The session bus is the uid's own `/run/user/<uid>/bus` when that is a
///   socket this uid owns; only without it does `DBUS_SESSION_BUS_ADDRESS`
///   count. With neither, nothing runs: `secret-tool` must never autolaunch
///   a bus of its own.
///
/// The Secret Service has no per-application access control: any process
/// of this user on the bus can read an unlocked item. rv's hook guard
/// refuses an agent's `secret-tool` and direct Secret Service D-Bus calls
/// (`core.secrets:secret-service`), which is what the Keychain's per-app
/// prompt gives on macOS for the command line.
package enum SecretServiceTool {
    package static let candidates = ["/usr/bin/secret-tool", "/bin/secret-tool"]
    /// The Debian/Ubuntu package that ships `secret-tool` (Fedora: libsecret).
    package static let packageName = "libsecret-tools"
    package static let userRuntimeRoot = "/run/user"
    /// A person may have to unlock the keyring for a store.
    static let storeTimeout: TimeInterval = 60
    /// rvd reads at launch; an unanswered unlock prompt must not hold it.
    static let lookupTimeout: TimeInterval = 15

    package enum Availability: Sendable, Equatable {
        case available(tool: String, environment: [String: String])
        case missingTool
        case noSessionBus
    }

    package struct Probe: Sendable {
        var environment: [String: String]
        var uid: UInt32
        var isExecutable: @Sendable (String) -> Bool
        /// True when `path` is a socket owned by `uid` (lstat, no follow).
        var isOwnedSocket: @Sendable (String, UInt32) -> Bool

        package init(
            environment: [String: String],
            uid: UInt32,
            isExecutable: @escaping @Sendable (String) -> Bool,
            isOwnedSocket: @escaping @Sendable (String, UInt32) -> Bool
        ) {
            self.environment = environment
            self.uid = uid
            self.isExecutable = isExecutable
            self.isOwnedSocket = isOwnedSocket
        }

        package static var live: Probe {
            Probe(
                environment: ProcessInfo.processInfo.environment,
                uid: UInt32(getuid()),
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                isOwnedSocket: { path, uid in
                    var info = stat()
                    guard lstat(path, &info) == 0 else { return false }
                    return (info.st_mode & S_IFMT) == S_IFSOCK && UInt32(info.st_uid) == uid
                })
        }
    }

    package static func availability(_ probe: Probe = .live) -> Availability {
        guard let tool = candidates.first(where: probe.isExecutable) else { return .missingTool }
        let runtime = "\(userRuntimeRoot)/\(probe.uid)"
        var environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"]
        if probe.isOwnedSocket("\(runtime)/bus", probe.uid) {
            environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=\(runtime)/bus"
            environment["XDG_RUNTIME_DIR"] = runtime
        } else if let address = probe.environment["DBUS_SESSION_BUS_ADDRESS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), address.isEmpty == false,
            address.contains("\n") == false
        {
            environment["DBUS_SESSION_BUS_ADDRESS"] = address
            if let xdg = probe.environment["XDG_RUNTIME_DIR"], xdg.isEmpty == false { environment["XDG_RUNTIME_DIR"] = xdg }
        } else {
            return .noSessionBus
        }
        return .available(tool: tool, environment: environment)
    }

    /// The label the keyring shows for an item rv stored.
    static func label(service: String, account: String) -> String {
        "rv: \(account) (\(service))"
    }

    package static func store(
        service: String, account: String, value: Data, availability: Availability = availability(),
        run: Runner = BoundedProcess.runner
    ) -> Bool {
        guard case .available(let tool, let environment) = availability, value.isEmpty == false else { return false }
        let outcome = run(
            tool,
            ["store", "--label=\(label(service: service, account: account))", "service", service, "account", account],
            environment, storeTimeout, [UInt8](value))
        return outcome?.status == 0
    }

    /// True when no item is left: cleared, or there was none. `secret-tool
    /// clear` exits 1 both when nothing matched and on an error, so a
    /// failed clear is followed by a lookup: only a silent miss (exit 1, no
    /// stderr) proves the item absent. Without `secret-tool` rv never
    /// stored anything here, so there is nothing to remove; without a
    /// session bus the keyring may still hold the value, so that fails.
    package static func delete(
        service: String, account: String, availability: Availability = availability(),
        run: Runner = BoundedProcess.runner
    ) -> Bool {
        if availability == .missingTool { return true }
        guard case .available(let tool, let environment) = availability else { return false }
        let attributes = ["service", service, "account", account]
        guard let cleared = run(tool, ["clear"] + attributes, environment, storeTimeout, nil) else { return false }
        if cleared.status == 0 { return true }
        guard cleared.stderr.isEmpty,
            let found = run(tool, ["lookup"] + attributes, environment, lookupTimeout, nil)
        else { return false }
        return found.status == 1 && found.stdout.isEmpty && found.stderr.isEmpty
    }

    /// The stored value, or nil when absent, locked, or unreachable.
    package static func lookup(
        service: String, account: String, availability: Availability = availability(),
        run: Runner = BoundedProcess.runner
    ) -> Data? {
        guard case .available(let tool, let environment) = availability else { return nil }
        guard let outcome = run(tool, ["lookup", "service", service, "account", account], environment, lookupTimeout, nil),
            outcome.status == 0, outcome.stdout.isEmpty == false
        else { return nil }
        return Data(outcome.stdout)
    }

    /// Why a store failed, for "could not store NAME …".
    package static func storeFailureSuffix(_ availability: Availability = availability()) -> String {
        switch availability {
        case .missingTool:
            "(no secret store: rv keeps values in the Secret Service through secret-tool; "
                + "install \(packageName) and a keyring such as gnome-keyring)"
        case .noSessionBus:
            "(no secret store: rv keeps values in the Secret Service, which needs this user's "
                + "D-Bus session bus, and none is reachable; run it from a desktop or SSH login session)"
        case .available:
            "in the Secret Service (secret-tool store failed: is a keyring such as gnome-keyring "
                + "running and unlocked?)"
        }
    }

    package typealias Runner = @Sendable (
        _ tool: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval,
        _ input: [UInt8]?
    ) -> BoundedProcess.Outcome?
}

extension BoundedProcess {
    package static let runner: SecretServiceTool.Runner = { tool, arguments, environment, timeout, input in
        run(tool, arguments, environment: environment, timeout: timeout, maximumOutputBytes: 64 * 1024, input: input)
    }
}
