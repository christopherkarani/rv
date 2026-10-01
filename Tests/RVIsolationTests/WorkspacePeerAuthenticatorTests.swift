#if os(macOS)
import Darwin
import Foundation
import Security
import Testing
@testable import RVIsolation

@Test func peerTrustRejectsUserOwnedManifest() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("[]".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: PeerAuthenticationError.invalidTrustConfiguration) {
        try ProtectedPeerTrustConfiguration.load(from: url)
    }
}

@Test func peerTrustRejectsRealAllowACLDespiteSafePOSIXMode() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-peer-acl-\(UUID().uuidString)")
    try Data("[]".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(chmod(url.path, 0o644) == 0)
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/chmod")
    command.arguments = ["+a", "user:\(NSUserName()) allow write", url.path]
    try command.run()
    command.waitUntilExit()
    #expect(command.terminationStatus == 0)
    var info = stat()
    #expect(lstat(url.path, &info) == 0)
    #expect(info.st_mode & 0o022 == 0)
    // Exercise ACL rejection independently of the fixture's non-root ownership.
    #expect(!ProtectedPeerTrustConfiguration.hasNoAllowACL(path: url.path))
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0)
    if fd >= 0 {
        defer { close(fd) }
        #expect(!ProtectedPeerTrustConfiguration.hasNoAllowACL(fd: fd))
    }
    #expect(throws: PeerAuthenticationError.invalidTrustConfiguration) {
        try ProtectedPeerTrustConfiguration.load(from: url)
    }
    #expect(!ProtectedPeerTrustConfiguration.hasNoAllowACL(path: url.path + "-absent"))
    #expect(!ProtectedPeerTrustConfiguration.hasNoAllowACL(fd: -1))
    for arguments in [["-N", url.path], ["+a", "everyone deny execute", url.path]] {
        let update = Process()
        update.executableURL = URL(fileURLWithPath: "/bin/chmod")
        update.arguments = arguments
        try update.run()
        update.waitUntilExit()
        #expect(update.terminationStatus == 0)
    }
    #expect(ProtectedPeerTrustConfiguration.hasNoAllowACL(path: url.path))
}

@Test func aclLessExistingFileCarriesNoAllowEntries() throws {
    // Regression: acl_get_file returns NULL/ENOENT for files without any
    // extended ACL. That must read as "no allow entries", not failure —
    // otherwise trust can never load on normally-protected paths.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-peer-noacl-\(UUID().uuidString)")
    try Data("[]".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ProtectedPeerTrustConfiguration.hasNoAllowACL(path: url.path))
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0)
    if fd >= 0 {
        defer { close(fd) }
        #expect(ProtectedPeerTrustConfiguration.hasNoAllowACL(fd: fd))
    }
}

@Test func unixPeerEvidenceRejectsNonSocketDescriptor() {
    #expect(throws: PeerAuthenticationError.missingPeerEvidence) {
        try WorkspacePeerAuthenticator.capture(fd: -1)
    }
}

@Test func unixPeerEvidenceFromRealConnectedSocket() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-peer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("peer.sock").path
    let (listener, _) = try WorkspaceControlSocket.openListener(path: path).get()
    defer { close(listener) }
    let client = try WorkspaceControlSocket.connect(path: path, timeout: 2).get()
    defer { close(client) }
    let accepted = accept(listener, nil, nil)
    #expect(accepted >= 0)
    guard accepted >= 0 else { return }
    defer { close(accepted) }
    let clientEvidence = try WorkspacePeerAuthenticator.capture(fd: accepted)
    let serverEvidence = try WorkspacePeerAuthenticator.capture(fd: client)
    #expect(clientEvidence.processID == getpid())
    #expect(clientEvidence.effectiveUserID == geteuid())
    #expect(clientEvidence.auditToken?.count == MemoryLayout<audit_token_t>.size)
    #expect(clientEvidence.codeIdentity.cdHash.isEmpty == false)
    #expect(clientEvidence.componentRole == nil)
    #expect(serverEvidence.processID == getpid())
    #expect(serverEvidence.componentRole == nil)
}

@Test func dynamicCodeInvalidRequirementFailsAndDefaultHasNoRole() throws {
    var code: SecCode?
    #expect(SecCodeCopySelf([], &code) == errSecSuccess)
    let running = try #require(code)
    let evidence = try MacOSPeerCodeVerifier.capture(code: running, processID: getpid(), effectiveUserID: geteuid())
    #expect(evidence.componentRole == nil)
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString("identifier \"rv.definitely.wrong\"" as CFString, [], &requirement) == errSecSuccess)
    #expect(SecCodeCheckValidity(running, [], try #require(requirement)) != errSecSuccess)
}
@Test func unixDifferentExecutableCannotAcquireRoleAndDeadPeerFails() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("rv-peer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (listener, _) = try WorkspaceControlSocket.openListener(path: directory.appendingPathComponent("p.sock").path).get()
    defer { close(listener) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-U", directory.appendingPathComponent("p.sock").path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    #expect(poll(&ready, 1, 3_000) == 1)
    guard ready.revents & Int16(POLLIN) != 0 else { return }
    let accepted = accept(listener, nil, nil)
    #expect(accepted >= 0)
    guard accepted >= 0 else { return }
    defer { close(accepted) }
    let evidence = try WorkspacePeerAuthenticator.capture(fd: accepted)
    #expect(evidence.processID == process.processIdentifier)
    #expect(evidence.processID != getpid())
    #expect(evidence.codeIdentity.executablePath == "/usr/bin/nc")
    #expect(evidence.componentRole == nil)
    process.terminate()
    process.waitUntilExit()
    #expect(throws: (any Error).self) {
        try WorkspacePeerAuthenticator.capture(fd: accepted)
    }
}

#endif
