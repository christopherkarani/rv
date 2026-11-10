#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
@testable import RVCLI

/// Swift twin of `Sources/rv-c/tests/observe_gate_test.c`: only the owner's
/// config file (never the environment) can make a daemon miss step aside,
/// and anything ambiguous keeps the normal fallback.
struct HookObserveFallbackTests {
    private let directory: URL
    private var config: URL { directory.appendingPathComponent("config.json") }
    private var managed: String { directory.appendingPathComponent("managed").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-observe-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ json: String, mode: Int16 = 0o600) throws {
        try Data(json.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: config.path)
    }

    private func applies(_ host: HookHost = .claude, file: String? = nil) -> Bool {
        HookObserveFallback.applies(configFile: file ?? config.path, managedDirectory: managed, host: host)
    }

    @Test func resolvesLikeRvdWithoutTheEnvironment() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(applies() == false, "no config is enforce")
        try write(#"{"guard":{"mode":"observe"}}"#)
        #expect(applies())
        try write(#"{"guard.mode":"OBSERVE"}"#)
        #expect(applies())
        try write(#"{"guard":{"mode":"enforce"},"guard.mode":"observe"}"#)
        #expect(applies() == false)
        try write(#"{"guard":{"mode":"observe","hosts":{"claude":"block"}}}"#)
        #expect(applies(.claude) == false)
        #expect(applies(.cursor))
        try write(#"{"guard":{"hosts":{"claude":"off"}}}"#)
        #expect(applies(.claude))
        try write(#"{"guard":{"mode":"observe""#)
        #expect(applies() == false, "malformed config is enforce")
    }

    @Test func refusesUnsafeFilesAndOrganizationPolicy() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(#"{"guard":{"mode":"observe"}}"#, mode: 0o644)
        #expect(applies())
        try write(#"{"guard":{"mode":"observe"}}"#, mode: 0o666)
        #expect(applies() == false, "writable by others")
        try write(#"{"guard":{"mode":"observe"}}"#)

        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        #expect(applies(file: link.path) == false, "symlinked config")
        #expect(applies(file: directory.path) == false, "directory")

        try FileManager.default.createDirectory(atPath: managed, withIntermediateDirectories: false)
        #expect(applies() == false, "organization policy directory present")
        try FileManager.default.removeItem(atPath: managed)
        try FileManager.default.createSymbolicLink(
            atPath: managed, withDestinationPath: "/nonexistent-rv-managed")
        #expect(applies() == false, "dangling managed symlink still counts as present")
        try FileManager.default.removeItem(atPath: managed)

        let oversized = #"{"guard":{"mode":"observe"}}"#
            + String(repeating: " ", count: HookObserveFallback.configMaxBytes)
        try write(oversized)
        #expect(applies() == false, "oversized config")
    }
}
