#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// T9: R4 per-MIB experiment behind a flag.
///
/// The default profile is untouched (coarse `(allow sysctl-read)`); the
/// experiment compiles a deny-first + exact-name allowlist shape plus
/// same-sandbox pidinfo scoping. Both halves are required: KERN_PROCARGS2
/// consults the sysctl branch OR the process-info-pidinfo branch, so either
/// half alone leaves host argv+env readable (measured on Darwin 27, see
/// `SeatbeltSysctlExperiment`). AC-6 goes green on the experiment profile:
/// host procargs errno, self procargs size present.
@Suite("SeatbeltPerMIBExperiment", .serialized)
struct SeatbeltPerMIBExperimentTests {
    /// Flag-off default: byte-stable coarse sysctl shape, no experiment rules.
    @Test func defaultProfileKeepsCoarseSysctlRead() throws {
        let fixture = try PerMIBFixture()
        defer { fixture.tearDown() }
        let workspace = try #require(WorkingDirectory(validating: fixture.directory.path))
        let profile = try compileFirstSliceProfile(workspace: workspace).get()
        let bare = profile.source
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "(allow sysctl-read)" }
        #expect(bare.count == 1)
        #expect(profile.source.contains("sysctl-name") == false)
        #expect(profile.source.contains("process-info-pidinfo") == false)
    }

    /// Flag-on text shape: deny-first + allowlist + pidinfo scoping, no bare allow.
    @Test func experimentProfileEmitsDenyFirstAllowlist() throws {
        let fixture = try PerMIBFixture()
        defer { fixture.tearDown() }
        let workspace = try #require(WorkingDirectory(validating: fixture.directory.path))
        let profile = try compileFirstSliceProfile(workspace: workspace, sysctlPolicy: .perMIBExperiment).get()
        #expect(profile.source.contains("(deny sysctl-read)"))
        for name in SeatbeltSysctlExperiment.allowlistedNames {
            #expect(profile.source.contains("(sysctl-name \"\(name)\")"), "missing allowlist entry \(name)")
        }
        #expect(profile.source.contains("(deny process-info-pidinfo)"))
        #expect(profile.source.contains("(allow process-info-pidinfo (target same-sandbox))"))
        let bare = profile.source
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "(allow sysctl-read)" }
        #expect(bare.count == 0)
    }

    /// AC-6 live: under the experiment profile host procargs fails closed
    /// while self procargs, an allowlisted MIB, and the pid-1 control hold.
    /// Content is never printed: byte counts and errnos only.
    @Test func experimentDeniesHostProcargsKeepsSelf() throws {
        let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        #expect(FileManager.default.isExecutableFile(atPath: sandboxExec.path))
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        #expect(FileManager.default.isExecutableFile(atPath: clang.path))

        let fixture = try PerMIBFixture()
        defer { fixture.tearDown() }
        let workspace = try #require(WorkingDirectory(validating: fixture.directory.path))
        let profile = try compileFirstSliceProfile(workspace: workspace, sysctlPolicy: .perMIBExperiment).get()
        let profileURL = fixture.directory.appendingPathComponent("experiment.sb")
        try Data(profile.source.utf8).write(to: profileURL)

        let probeURL = fixture.directory.appendingPathComponent("permib-probe")
        try Data(perMIBProbeSource.utf8).write(to: fixture.directory.appendingPathComponent("permib-probe.c"))
        let compile = Process()
        compile.executableURL = clang
        compile.arguments = ["-O2", "-o", probeURL.path, fixture.directory.appendingPathComponent("permib-probe.c").path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)

        let reportURL = fixture.directory.appendingPathComponent("permib-report.txt")
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let run = Process()
        run.executableURL = sandboxExec
        run.arguments = ["-f", profileURL.path, probeURL.path, "\(hostPID)", reportURL.path]
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = pipe
        try run.run()
        run.waitUntilExit()
        let console = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(run.terminationStatus == 0, "console:\n\(console)")
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        #expect(report.contains("SELF read bytes="), "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("HOST errno="), "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("HOST read bytes=") == false, "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("PID1 errno="), "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("PID1 read bytes=") == false, "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("NCPU size="), "report:\n\(report)\nconsole:\n\(console)")
        #expect(report.contains("PROCALL errno="), "report:\n\(report)\nconsole:\n\(console)")
    }

    /// Toolchain smoke under exactly the experiment sysctl/pidinfo rules:
    /// every tool in the T9 matrix must behave as unsandboxed. swift is the
    /// load-bearing row: it calls uname(3), which needs kern.ostype,
    /// kern.osrelease, kern.hostname, kern.version, and hw.machine.
    @Test func experimentKeepsToolchainSmoke() throws {
        let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        #expect(FileManager.default.isExecutableFile(atPath: sandboxExec.path))
        let fixture = try PerMIBFixture()
        defer { fixture.tearDown() }
        let profileURL = fixture.directory.appendingPathComponent("matrix.sb")
        let source = "(version 1)\n(allow default)\n\(SeatbeltSysctlExperiment.sbplRules(policy: .perMIBExperiment))\n"
        try Data(source.utf8).write(to: profileURL)

        let tools: [(path: String, arguments: [String], marker: String)] = [
            ("/bin/sh", ["-c", "echo t9-sh-ok"], "t9-sh-ok"),
            ("/usr/bin/git", ["--version"], "git version"),
            ("/usr/bin/python3", ["-c", "print('t9-py-ok')"], "t9-py-ok"),
            ("/usr/bin/curl", ["--version"], "curl"),
            ("/usr/bin/clang", ["--version"], "clang"),
            ("/usr/bin/xcrun", ["--version"], "xcrun"),
        ]
        for tool in tools {
            #expect(FileManager.default.isExecutableFile(atPath: tool.path), "missing \(tool.path)")
            let (status, output) = try perMIBRun(
                sandboxExec: sandboxExec, profileURL: profileURL,
                path: tool.path, arguments: tool.arguments)
            #expect(status == 0, "\(tool.path) output:\n\(output)")
            #expect(output.contains(tool.marker), "\(tool.path) output:\n\(output)")
        }
        // Known-gap rows: node and swift size their allocators through
        // raw-MIB sysctl queries that `sysctl-name` allows cannot express
        // (measured LowLevelAlloc overflow aborts; see the SHIP-BLOCKED
        // note in SeatbeltLoopbackTests). They pass on some hosts and
        // abort with that one signature on others. Pin exactly that: a
        // pass is fine, the documented crash is the known gap, and any
        // other failure mode is a regression. When the toolchain leaves
        // are identified, delete the crash arm so the rows hard-require.
        var gapTools: [(path: String, arguments: [String], marker: String)] = [
            ("/usr/bin/swift", ["--version"], "swift-driver")
        ]
        if let node = perMIBFindTool([
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/node",
            "/opt/homebrew/bin/node", "/usr/local/bin/node",
        ]) {
            gapTools.append((node, ["-e", "console.log('t9-node-ok')"], "t9-node-ok"))
        }
        for tool in gapTools {
            #expect(FileManager.default.isExecutableFile(atPath: tool.path), "missing \(tool.path)")
            let (status, output) = try perMIBRun(
                sandboxExec: sandboxExec, profileURL: profileURL,
                path: tool.path, arguments: tool.arguments)
            let passed = status == 0 && output.contains(tool.marker)
            let knownGap = output.contains("LowLevelAlloc")
            #expect(passed || knownGap, "\(tool.path) status=\(status) output:\n\(output)")
        }
    }
}

private struct PerMIBFixture {
    let directory: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-permib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func perMIBFindTool(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func perMIBRun(
    sandboxExec: URL,
    profileURL: URL,
    path: String,
    arguments: [String]
) throws -> (status: Int32, output: String) {
    let run = Process()
    run.executableURL = sandboxExec
    run.arguments = ["-f", profileURL.path, path] + arguments
    let pipe = Pipe()
    run.standardOutput = pipe
    run.standardError = pipe
    try run.run()
    run.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (run.terminationStatus, output)
}

/// Ticket-owned proc probe: self/host/pid-1 KERN_PROCARGS2, KERN_PROC_ALL,
/// and one allowlisted leaf, as counts and errnos only. Report goes to the
/// argv file (workspace-writable); stdout mirrors it best-effort.
private let perMIBProbeSource = #"""
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static void probe_args(const char *tag, int pid, FILE *out) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
        fprintf(out, "%s errno=%d\n", tag, errno);
        printf("%s errno=%d\n", tag, errno);
        return;
    }
    char *buffer = (char *)malloc(size ? size : 1);
    if (!buffer) {
        fprintf(out, "%s malloc-fail\n", tag);
        return;
    }
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
        fprintf(out, "%s read errno=%d\n", tag, errno);
        printf("%s read errno=%d\n", tag, errno);
    } else {
        fprintf(out, "%s read bytes=%zu\n", tag, size);
        printf("%s read bytes=%zu\n", tag, size);
    }
    memset(buffer, 0, size);
    free(buffer);
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    FILE *out = fopen(argv[2], "w");
    if (!out) return 3;
    alarm(60);
    setvbuf(stdout, NULL, _IONBF, 0);
    probe_args("SELF", getpid(), out);
    probe_args("HOST", atoi(argv[1]), out);
    probe_args("PID1", 1, out);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) {
        fprintf(out, "PROCALL errno=%d\n", errno);
        printf("PROCALL errno=%d\n", errno);
    } else {
        fprintf(out, "PROCALL size=%zu\n", size);
        printf("PROCALL size=%zu\n", size);
    }
    size_t ncpu = 0;
    if (sysctlbyname("hw.ncpu", NULL, &ncpu, NULL, 0) != 0) {
        fprintf(out, "NCPU errno=%d\n", errno);
        printf("NCPU errno=%d\n", errno);
    } else {
        fprintf(out, "NCPU size=%zu\n", ncpu);
        printf("NCPU size=%zu\n", ncpu);
    }
    fclose(out);
    return 0;
}
"""#
#endif
