#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Mach/XPC boundary: the cage must not reach host credential/security
/// services, while normal development workflows keep working.
///
/// Every test runs a real contained child (or the real profile compiler for
/// the architectural invariant). No test prints real Keychain items or
/// secret values: Keychain probes use guaranteed-nonexistent items and
/// assert only on error markers.
@Suite("SeatbeltMachBoundary", .serialized)
struct SeatbeltMachBoundaryTests {
    /// `/usr/bin/security` cannot cleanly reach the real Keychain service.
    /// Unsandboxed, a nonexistent item reports only "could not be found".
    /// Sandboxed, the boundary blocks the XPC path and the CLI surfaces the
    /// resulting paramErr ("One or more parameters") instead of a clean
    /// service answer. Exit 44 alone is ambiguous; the marker distinguishes.
    @Test func keychainSecurityCLICannotReachService() async throws {
        let account = "rv-nonexistent-probe-\(UUID().uuidString)"
        let service = "rv-nonexistent-service-\(UUID().uuidString)"
        let unsandboxed = runHost(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-a", account, "-s", service]
        )
        #expect(unsandboxed.status == 44)
        #expect(unsandboxed.output.contains("could not be found in the keychain"))
        #expect(unsandboxed.output.contains("One or more parameters") == false)

        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let report = tree.workspaceURL.appendingPathComponent("security.out")
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/security find-generic-password -a \(shellQuote(account)) -s \(shellQuote(service)) >security.out 2>&1; echo EXIT=$? >>security.out",
            ]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let text = try String(contentsOf: report, encoding: .utf8)
        #expect(text.contains("EXIT=44"))
        #expect(text.contains("One or more parameters"))
    }

    /// Direct Security.framework use is blocked at the sandbox boundary.
    /// Unsandboxed control returns errSecItemNotFound (-25300): the request
    /// reaches securityd. Sandboxed, the denied mach-lookup to
    /// `com.apple.securityd.xpc` / `com.apple.SecurityServer` fails the call
    /// with paramErr (-50) before any service answer.
    @Test func securityFrameworkLookupIsBlockedAtBoundary() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileMachProbe(
            machBoundarySecItemSource, named: "rv-secitem-probe",
            fileExtension: "m",
            extraArguments: ["-framework", "Foundation", "-framework", "Security"],
            in: tree.workspaceURL
        )
        let direct = runHost(executable: probe.path, arguments: [])
        #expect(direct.output.contains("status=-25300"))

        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "./rv-secitem-probe >secitem.out 2>&1"]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let text = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("secitem.out"),
            encoding: .utf8
        )
        #expect(text.contains("status=-50"))
        #expect(text.contains("status=-25300") == false)
    }

    /// A known credential-bearing Mach service is unreachable from the cage.
    /// `bootstrap_look_up` returns KERN_SUCCESS (0) unsandboxed and
    /// BOOTSTRAP_NOT_PRIVILEGED (1100, sandbox denial) sandboxed — never a
    /// port, and never BOOTSTRAP_UNKNOWN_SERVICE (1102, which would mean the
    /// probe named a service that does not exist).
    @Test func blockedMachServiceLookupFailsFromContainedChild() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileMachProbe(
            machBoundaryLookupSource, named: "rv-mach-probe",
            in: tree.workspaceURL
        )
        for service in ["com.apple.securityd.xpc", "com.apple.SecurityServer"] {
            let direct = runHost(executable: probe.path, arguments: [service])
            #expect(direct.output.contains("kr=0"))
            #expect(direct.output.contains("REACHABLE"))
        }
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "./rv-mach-probe com.apple.securityd.xpc >mach.out 2>&1; ./rv-mach-probe com.apple.SecurityServer >>mach.out 2>&1",
            ]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let text = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("mach.out"),
            encoding: .utf8
        )
        #expect(text.contains("kr=1100"))
        #expect(text.contains("REACHABLE") == false)
        #expect(text.contains("kr=1102") == false)
    }

    /// Other credential-bearing services stay blocked as well: GSS
    /// credentials, the pasteboard (which may hold secrets), and trustd all
    /// deny with 1100 from a contained child. BiometricKit is verified
    /// blocked manually but omitted here: it is hardware-dependent and may
    /// be absent on runners without Touch ID.
    @Test func otherCredentialServicesStayBlocked() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileMachProbe(
            machBoundaryLookupSource, named: "rv-mach-probe",
            in: tree.workspaceURL
        )
        let services = [
            "com.apple.GSSCred",
            "com.apple.pasteboard.1",
            "com.apple.trustd",
        ]
        for service in services {
            let direct = runHost(executable: probe.path, arguments: [service])
            #expect(direct.output.contains("kr=0"), Comment(rawValue: service))
        }
        let script = services
            .map { "./rv-mach-probe \($0) >>cred.out 2>&1" }
            .joined(separator: "; ")
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", ": >cred.out; \(script)"]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let text = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("cred.out"),
            encoding: .utf8
        )
        #expect(text.contains("REACHABLE") == false)
        #expect(text.components(separatedBy: "kr=1100").count == services.count + 1)
    }

    /// The one explicitly allowed Mach service remains reachable: SwiftPM
    /// linking requires `com.apple.bsd.dirhelper`, so a contained lookup
    /// must succeed while every other service stays denied.
    @Test func allowedDirhelperServiceStillSucceeds() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileMachProbe(
            machBoundaryLookupSource, named: "rv-mach-probe",
            in: tree.workspaceURL
        )
        let direct = runHost(executable: probe.path, arguments: ["com.apple.bsd.dirhelper"])
        #expect(direct.output.contains("kr=0"))
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "./rv-mach-probe com.apple.bsd.dirhelper >dirhelper.out 2>&1"]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let text = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("dirhelper.out"),
            encoding: .utf8
        )
        #expect(text.contains("kr=0"))
        #expect(text.contains("REACHABLE"))
    }

    /// The workflow that justifies the dirhelper allow still succeeds: a
    /// minimal `swift build` links inside the cage under the hardened Mach
    /// policy. Without the allow this fails at `Ld` with `permissionDenied`.
    @Test func swiftBuildSucceedsWithHardenedMachPolicy() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") else {
            print("mach-boundary swift-build coverage=NOT-TESTED reason=no-swift-toolchain")
            return
        }
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let package = tree.workspaceURL.appendingPathComponent("swifttest", isDirectory: true)
        let sources = package.appendingPathComponent("Sources/swifttest", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data(machBoundarySwiftManifest.utf8).write(
            to: package.appendingPathComponent("Package.swift")
        )
        try Data("print(\"hello-swift-build\")\n".utf8).write(
            to: sources.appendingPathComponent("main.swift")
        )
        // `swift` via PATH so the RV transparency shim injects
        // `--disable-sandbox` for manifest evaluation; an absolute
        // `/usr/bin/swift` bypasses the shim and fails on nested
        // `sandbox-exec` by kernel law (not by the Mach policy).
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "cd swifttest && swift build >build.log 2>&1; echo BUILD-EXIT=$? >../build.exit"]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let exit = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("build.exit"),
            encoding: .utf8
        )
        if exit.contains("BUILD-EXIT=0") == false {
            let log = (try? String(
                contentsOf: package.appendingPathComponent("build.log"),
                encoding: .utf8
            )) ?? "<no build.log>"
            print("mach-boundary swift-build log tail:\n\(log.suffix(2000))")
        }
        #expect(exit.contains("BUILD-EXIT=0"))
    }

    /// Public HTTPS still works through the RV proxy after hardening: the
    /// contained fetch returns 200, proving network productivity does not
    /// imply host credential access. Skips only when the unsandboxed control
    /// fails (no internet on this runner).
    @Test func proxiedPublicHTTPSStillSucceeds() async throws {
        let control = runHost(
            executable: "/usr/bin/curl",
            arguments: ["-s", "--max-time", "20", "-o", "/dev/null", "-w", "%{http_code}", "https://example.com"]
        )
        guard control.output.contains("200") else {
            print("mach-boundary egress coverage=NOT-TESTED reason=no-internet control=\(control.status)")
            return
        }
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/curl -s --max-time 30 -o page.html -w \"%{http_code}\" https://example.com >code.txt 2>curl.err; echo CURL-EXIT=$? >>code.txt",
            ]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let code = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("code.txt"),
            encoding: .utf8
        )
        #expect(code.contains("200"))
        let page = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("page.html"),
            encoding: .utf8
        )
        #expect(page.contains("Example Domain"))
    }

    /// File-based secrets stay denied under the hardened policy: synthetic
    /// stand-ins outside the workspace are unreadable from a contained
    /// child, and no content crosses into the workspace. One contained run
    /// covers every category to keep volume-mount costs down.
    @Test func filesystemSecretsRemainDenied() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let fakes = [
            ".ssh/id_ed25519",
            ".aws/credentials",
            ".gnupg/secring.gpg",
            ".kube/config",
            ".config/gh/hosts.yml",
            ".npmrc",
            "Library/Keychains/login.keychain-db",
        ]
        var script = ": >reads.exit"
        for (index, relative) in fakes.enumerated() {
            let secret = tree.siblingURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: secret.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("RV-SYNTHETIC-NOT-A-SECRET-\(index)".utf8).write(to: secret)
            script += "; /bin/cat \(shellQuote(secret.path)) >read-\(index) 2>/dev/null; echo \(index)=$? >>reads.exit"
        }
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", script]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let exit = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("reads.exit"),
            encoding: .utf8
        )
        for index in fakes.indices {
            #expect(exit.contains("\(index)=0") == false)
            let copied = (try? String(
                contentsOf: tree.workspaceURL.appendingPathComponent("read-\(index)"),
                encoding: .utf8
            )) ?? ""
            #expect(copied.contains("RV-SYNTHETIC-NOT-A-SECRET") == false)
        }
    }

    /// Basic process containment still holds: writes inside the workspace
    /// succeed, writes outside fail, and the run establishes a seatbelt
    /// session under the hardened Mach policy.
    @Test func processContainmentRemainsGreen() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "echo ok >\(shellQuote(inside)) && echo no >\(shellQuote(outside))"]
        ))
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus != 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        switch run.established {
        case .seatbelt(let session):
            #expect(session.backend == .seatbelt)
        case .observed, .mediated:
            Issue.record("hardened contained run must establish seatbelt")
        }
    }

    /// A contained PTY runtime still starts: stdin/stdout are terminals and
    /// the child reports success under the hardened Mach policy.
    @Test func ptyRemainsGreen() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "test -t 0 && test -t 1 && echo PTY-OK >pty.out"]
        ))
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .pseudoTerminal(rows: 24, columns: 80),
            host: nil,
            sessionStore: .file(tree.rootURL.appendingPathComponent("mach-pty.jsonl"))
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        let text = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("pty.out"),
            encoding: .utf8
        )
        #expect(text.contains("PTY-OK"))
    }

    /// Architectural invariant: the compiled contained profile denies
    /// Mach/XPC by default and contains no broad `(allow mach-lookup)`.
    /// Narrow allows come only from `SeatbeltMachPolicy.allowedServices`,
    /// each an exact non-wildcard service name.
    @Test func machPolicyHasNoBroadLookupAllow() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try #require(IsolatedCommand(executable: "/bin/true"))
        let request = try prepareSeatbelt(tree.contained, command).get()
        let source = try #require(request.seatbeltProfile?.source)
        #expect(source.contains("(deny mach-lookup)"))
        #expect(source.contains("(deny mach-register)"))
        #expect(source.contains("(allow mach-lookup)") == false)
        for service in SeatbeltMachPolicy.allowedServices {
            #expect(service.isEmpty == false)
            #expect(service.contains("*") == false)
            #expect(source.contains("(global-name \"\(service)\")"))
        }
        #expect(SeatbeltMachPolicy.allowedServices.contains("com.apple.bsd.dirhelper"))
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func runHost(executable: String, arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "spawn-failed")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func compileMachProbe(
    _ source: String,
    named name: String,
    fileExtension: String = "c",
    extraArguments: [String] = [],
    in workspace: URL
) throws -> URL {
    let file = workspace.appendingPathComponent("\(name).\(fileExtension)")
    let binary = workspace.appendingPathComponent(name)
    try Data(source.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path] + extraArguments
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private let machBoundarySecItemSource = """
#import <Foundation/Foundation.h>
#import <Security/Security.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSDictionary *q = @{
            (id)kSecClass: (id)kSecClassGenericPassword,
            (id)kSecAttrAccount: @"rv-nonexistent-probe-mach-boundary",
            (id)kSecAttrService: @"rv-nonexistent-service-mach-boundary",
            (id)kSecReturnData: @NO,
            (id)kSecMatchLimit: (id)kSecMatchLimitOne,
        };
        CFTypeRef out = NULL;
        OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
        printf("status=%d\\n", (int)s);
        if (out) CFRelease(out);
        return 0;
    }
}
"""

private let machBoundaryLookupSource = """
#include <stdio.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[1], &port);
    printf("kr=%d\\n", kr);
    printf(kr == KERN_SUCCESS ? "REACHABLE\\n" : "BLOCKED-or-missing\\n");
    return 0;
}
"""

private let machBoundarySwiftManifest = """
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "swifttest", targets: [.executableTarget(name: "swifttest")])
"""
#endif
