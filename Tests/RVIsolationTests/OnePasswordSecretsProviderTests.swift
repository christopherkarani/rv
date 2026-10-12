#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Stand-in provider id

/// SecretRef allowlists provider ids and the registry (parent-owned) has not
/// admitted `"onepassword"` yet, so top-level `resolve(_:)` dispatch tests
/// carry this allowlisted stand-in via the provider's internal init. Flip to
/// `"onepassword"` once the registry lands. Every other suite calls the
/// internal resolution paths on a default-id provider and pins exact
/// `"onepassword..."` labels.
private let standInProviderID = "exec"

// MARK: - Fake `op` harness

/// Fake `op` scenario script. Behavior comes from files in `$FAKEOP_DIR` so
/// each test scripts only what it needs:
///
/// - `invocations.log` (written): one argv line per spawn, for exact-shape
///   and spawn-count assertions. Space-joined (`$*`), so it collapses
///   argv boundaries — boundary proofs use `argv.bin`, never this file.
/// - `argv.bin` (written): every spawn's argv as NUL-separated bytes,
///   appended per spawn. Single-spawn tests parse the whole file as one
///   record (`singleArgv()`); multi-spawn tests must not parse it, since
///   concurrent appends can interleave.
/// - `env.log` (written): `set <len>` when the child sees
///   `OP_SERVICE_ACCOUNT_TOKEN`, else `unset`. The length proves
///   pass-through; the value is never logged.
/// - `pids.log` (written): one PID per spawn, for kill verification.
/// - `hang`: when present, the child `exec`s into `sleep 300` (same PID).
/// - `delay`: seconds to sleep before responding.
/// - `linger`: seconds a background grandchild holds the pipes open. Alone
///   it outlives the script exit, so termination lands before EOF; with
///   `delay` the main script is still sleeping when the timeout kills it,
///   so the kill lands while a grandchild holds the pipes.
/// - `read.stdout` / `read.stderr` / `read.exit`: `read` payload, diagnostics,
///   and exit status (default empty payload, exit 0).
/// - `vaults.json` / `vaults.stderr` / `vaults.exit`: `vault list` equivalents.
/// - `items.<vault>.json` / `.stderr` / `.exit`: per-vault `item list`.
///
/// Fidelity limits (what the fake gets wrong vs real `op`):
/// - Per-vault listings key off the filename `items.<vault>.json`, so a
///   vault id containing `/` is unrepresentable (it becomes a path). Slash
///   injection is proven on the qualified/read path instead; listing_argv
///   injection tests use every other metacharacter.
/// - Responses are whole-file `cat`s: the fake cannot stream partial
///   stdout before hanging, so partial-output-on-timeout is proven with a
///   dedicated script op, not the fake (see SpawnBehavior).
/// - `hang` models a SIGTERM-killable hang only. A child ignoring SIGTERM
///   would outlive the kill; the provider sends SIGTERM and never
///   escalates, matching Foundation's `Process.terminate` vocabulary.
/// - Real `op` exit codes and stderr shapes are scripted per test from
///   observed CLI output (`[ERROR] ...`); unknown future shapes still
///   degrade safely because the provider only branches on exit status.
private let fakeOpScript = """
#!/bin/bash
printf '%s\\n' "$*" >>"$FAKEOP_DIR/invocations.log"
printf '%s\\0' "$@" >>"$FAKEOP_DIR/argv.bin"
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN+x}" ]; then
  echo "set ${#OP_SERVICE_ACCOUNT_TOKEN}" >>"$FAKEOP_DIR/env.log"
else
  echo "unset" >>"$FAKEOP_DIR/env.log"
fi
echo "$$" >>"$FAKEOP_DIR/pids.log"
if [ -f "$FAKEOP_DIR/hang" ]; then exec sleep 300; fi
if [ -f "$FAKEOP_DIR/linger" ]; then sleep "$(cat "$FAKEOP_DIR/linger")" & fi
if [ -f "$FAKEOP_DIR/delay" ]; then sleep "$(cat "$FAKEOP_DIR/delay")"; fi
if [ "$1" = "read" ]; then
  if [ -f "$FAKEOP_DIR/read.stderr" ]; then cat "$FAKEOP_DIR/read.stderr" >&2; fi
  if [ -f "$FAKEOP_DIR/read.stdout" ]; then cat "$FAKEOP_DIR/read.stdout"; fi
  code=0
  if [ -f "$FAKEOP_DIR/read.exit" ]; then code="$(cat "$FAKEOP_DIR/read.exit")"; fi
  exit "$code"
fi
if [ "$1" = "vault" ] && [ "$2" = "list" ]; then
  if [ -f "$FAKEOP_DIR/vaults.stderr" ]; then cat "$FAKEOP_DIR/vaults.stderr" >&2; fi
  if [ -f "$FAKEOP_DIR/vaults.json" ]; then cat "$FAKEOP_DIR/vaults.json"; fi
  code=0
  if [ -f "$FAKEOP_DIR/vaults.exit" ]; then code="$(cat "$FAKEOP_DIR/vaults.exit")"; fi
  exit "$code"
fi
if [ "$1" = "item" ] && [ "$2" = "list" ]; then
  vault=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--vault" ]; then vault="$arg"; fi
    prev="$arg"
  done
  if [ -f "$FAKEOP_DIR/items.$vault.stderr" ]; then cat "$FAKEOP_DIR/items.$vault.stderr" >&2; fi
  if [ -f "$FAKEOP_DIR/items.$vault.json" ]; then cat "$FAKEOP_DIR/items.$vault.json"; fi
  code=0
  if [ -f "$FAKEOP_DIR/items.$vault.exit" ]; then code="$(cat "$FAKEOP_DIR/items.$vault.exit")"; fi
  exit "$code"
fi
echo "unknown op invocation: $*" >&2
exit 1
"""

/// One fake-`op` installation rooted at a fresh temp dir.
private struct FakeOp: Sendable {
    /// Scenario dir; also the child's `$FAKEOP_DIR`.
    let dir: URL

    /// Fake `op` executable path.
    var opPath: String { dir.appendingPathComponent("op").path }

    /// Writes one scenario file.
    func write(_ name: String, _ text: String) throws {
        try text.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// Writes one scenario file as raw bytes.
    func write(_ name: String, _ data: Data) throws {
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// Removes one scenario file when present.
    func remove(_ name: String) throws {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Logged spawn argv lines, or [] when nothing spawned.
    func invocations() throws -> [String] {
        try logLines("invocations.log")
    }

    /// Logged child token-visibility lines (`set <len>` or `unset`).
    func envLog() throws -> [String] {
        try logLines("env.log")
    }

    /// Logged child PIDs.
    func pids() throws -> [Int32] {
        try logLines("pids.log").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The single spawn's argv as exact elements. Only valid when the test
    /// caused exactly one spawn: `argv.bin` concatenates every spawn's
    /// NUL-separated argv without record boundaries.
    func singleArgv() throws -> [String] {
        let data = try Data(contentsOf: dir.appendingPathComponent("argv.bin"))
        return data.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Non-empty lines of one log file, or [] when absent.
    private func logLines(_ name: String) throws -> [String] {
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }
}

/// Installs a fresh fake `op`.
private func makeFakeOp() throws -> FakeOp {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fakeop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let op = dir.appendingPathComponent("op")
    try fakeOpScript.write(to: op, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: op.path)
    return FakeOp(dir: dir)
}

/// Deterministic spawn environment: a usable `PATH` plus the fake's
/// scenario dir, nothing else. Tests needing an inherited token or a custom
/// `PATH` extend this map.
private func testEnvironment(_ fake: FakeOp, extra: [String: String] = [:]) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin", "FAKEOP_DIR": fake.dir.path]
    for (key, value) in extra {
        env[key] = value
    }
    return env
}

/// Default-id provider over the fake `op`.
private func makeProvider(
    _ fake: FakeOp,
    accounts: [OnePasswordAccount],
    timeoutSeconds: Double = 15,
    environment: [String: String]? = nil
) -> OnePasswordSecretsProvider {
    let env = environment ?? testEnvironment(fake)
    return OnePasswordSecretsProvider(
        accounts: accounts, opCommand: fake.opPath,
        timeoutSeconds: timeoutSeconds, environment: { env }
    )
}

/// Stand-in-id provider for top-level `resolve(_:)` dispatch tests.
private func makeStandInProvider(
    _ fake: FakeOp,
    accounts: [OnePasswordAccount],
    timeoutSeconds: Double = 15,
    cacheTTLSeconds: Double = OnePasswordSecretsProvider.defaultCacheTTLSeconds
) -> OnePasswordSecretsProvider {
    let env = testEnvironment(fake)
    return OnePasswordSecretsProvider(
        accounts: accounts, opCommand: fake.opPath,
        timeoutSeconds: timeoutSeconds, cacheTTLSeconds: cacheTTLSeconds,
        environment: { env },
        providerID: standInProviderID
    )
}

/// Installs a custom executable `op` with the given bash body, for spawn
/// shapes the fake cannot script (streaming partial output, instant exit
/// codes). Returns the scenario dir; the executable is `<dir>/op`.
private func makeScriptOp(body: String) throws -> FakeOp {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scriptop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let op = dir.appendingPathComponent("op")
    try "#!/bin/bash\n\(body)\n".write(to: op, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: op.path)
    return FakeOp(dir: dir)
}

private func serviceAccount(
    id: String = "acct-work",
    name: String = "Work",
    token: String = "ops_test_token_abc",
    vaults: [OnePasswordVault] = [OnePasswordVault(id: "vault-eng", name: "Engineering")]
) -> OnePasswordAccount {
    OnePasswordAccount(
        id: id, name: name,
        auth: .serviceAccount(token: token), vaults: vaults
    )
}

private func desktopAccount(
    id: String = "acct-default",
    name: String = "Personal",
    accountName: String = "my.1password.com",
    vaults: [OnePasswordVault] = [OnePasswordVault(id: "vault-123", name: "Personal")]
) -> OnePasswordAccount {
    OnePasswordAccount(
        id: id, name: name,
        auth: .desktopApp(accountName: accountName), vaults: vaults
    )
}

private func itemsJSON(_ rows: [(id: String, title: String)]) throws -> String {
    let array = rows.map { ["id": $0.id, "title": $0.title] }
    let data = try JSONSerialization.data(withJSONObject: array)
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func vaultsJSON(_ rows: [(id: String, name: String)]) throws -> String {
    let array = rows.map { ["id": $0.id, "name": $0.name] }
    let data = try JSONSerialization.data(withJSONObject: array)
    return String(data: data, encoding: .utf8) ?? "[]"
}

/// True while `pid` names a live process.
private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// Polls until every PID is dead, failing the test on expiry. An empty
/// PID set passes vacuously: a cancel that lands before the spawn leaves
/// nothing to kill.
private func expectDead(_ pids: [Int32], sourceLocation: SourceLocation = #_sourceLocation) async {
    guard pids.isEmpty == false else { return }
    let deadline = Date().addingTimeInterval(5)
    for pid in pids {
        while isAlive(pid) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(isAlive(pid) == false, sourceLocation: sourceLocation)
    }
}

/// Polls until the fake logs a spawn, or the deadline passes. Cancel tests
/// await flight so the kill path is genuinely exercised; a task still queued
/// at the prompt gate after the deadline is cancelled anyway, which covers
/// the queued-cancel path instead.
private func awaitSpawn(_ fake: FakeOp, timeoutSeconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let pids = try? fake.pids(), pids.isEmpty == false {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return ((try? fake.pids()) ?? []).isEmpty == false
}

// MARK: - Identity and redacted shapes

@Suite("OnePasswordIdentity")
private struct OnePasswordIdentityTests {
    @Test func defaultInit_carriesOnePasswordIDAndDefaults() {
        let provider = OnePasswordSecretsProvider(accounts: [serviceAccount()])
        #expect(provider.id == "onepassword")
        #expect(provider.opCommand == "op")
        #expect(provider.timeoutSeconds == 15)
        #expect(provider.cacheTTLSeconds == 60)
    }

    @Test func redactedAccounts_stripsEveryServiceToken() {
        let tokenA = "ops_super_secret_token_a"
        let tokenB = "ops_other_secret_token_b"
        let provider = OnePasswordSecretsProvider(accounts: [
            serviceAccount(id: "a", name: "CI", token: tokenA),
            serviceAccount(id: "b", name: "Deploys", token: tokenB),
        ])
        let redacted = provider.redactedAccounts
        #expect(redacted.count == 2)
        #expect(redacted.allSatisfy { $0.auth == .serviceAccount })
        #expect(redacted.map(\.name) == ["CI", "Deploys"])
        #expect(redacted.map(\.id) == ["a", "b"])
        #expect(redacted.allSatisfy { $0.vaults.isEmpty == false })
        let dumped = "\(redacted)"
        #expect(dumped.contains(tokenA) == false)
        #expect(dumped.contains(tokenB) == false)
    }

    @Test func redactedAccounts_keepsDesktopAccountName() {
        let provider = OnePasswordSecretsProvider(accounts: [desktopAccount()])
        let redacted = provider.redactedAccounts
        #expect(redacted.count == 1)
        #expect(redacted.first?.auth == .desktopApp(accountName: "my.1password.com"))
    }

    @Test func redactedAccounts_emptyWhenUnconfigured() {
        let provider = OnePasswordSecretsProvider(accounts: [])
        #expect(provider.redactedAccounts.isEmpty)
    }

    @Test func defaultEnvironment_readsLiveProcessEnvironment() {
        let provider = OnePasswordSecretsProvider(accounts: [])
        #expect(provider.environment() == ProcessInfo.processInfo.environment)
    }
}

// MARK: - Spawn environment

@Suite("OnePasswordSpawnEnvironment")
private struct OnePasswordSpawnEnvironmentTests {
    @Test func desktop_stripsInheritedTokenAndKeepsTheRest() {
        let env = OnePasswordSecretsProvider.spawnEnvironment(
            base: [
                "PATH": "/usr/bin:/bin",
                "OP_SERVICE_ACCOUNT_TOKEN": "ops_inherited_token",
                "HOME": "/Users/test",
            ],
            auth: .desktopApp(accountName: "my.1password.com")
        )
        #expect(env["OP_SERVICE_ACCOUNT_TOKEN"] == nil)
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/test")
    }

    @Test func serviceAccount_setsTokenOverAnyInheritedValue() {
        let env = OnePasswordSecretsProvider.spawnEnvironment(
            base: ["OP_SERVICE_ACCOUNT_TOKEN": "ops_inherited_token"],
            auth: .serviceAccount(token: "ops_explicit_token")
        )
        #expect(env["OP_SERVICE_ACCOUNT_TOKEN"] == "ops_explicit_token")
    }

    @Test func desktopWithoutInheritedToken_staysUnset() {
        let env = OnePasswordSecretsProvider.spawnEnvironment(
            base: ["PATH": "/usr/bin:/bin"],
            auth: .desktopApp(accountName: "my.1password.com")
        )
        #expect(env["OP_SERVICE_ACCOUNT_TOKEN"] == nil)
    }
}

// MARK: - Executable resolution

@Suite("OnePasswordResolveExecutable")
private struct OnePasswordResolveExecutableTests {
    @Test func absolutePresent_passesThroughWithoutPATH() {
        var consulted: [String] = []
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "/opt/1password/op", pathValue: "/usr/bin:/bin",
            isExecutable: { consulted.append($0); return true }
        )
        #expect(resolved == "/opt/1password/op")
        #expect(consulted == ["/opt/1password/op"])
    }

    @Test func absoluteMissing_returnsNil() {
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "/nonexistent/op-xyz", pathValue: "/usr/bin:/bin",
            isExecutable: { _ in false }
        )
        #expect(resolved == nil)
    }

    @Test func bareName_foundInFirstPATHDir() {
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "op", pathValue: "/fake/bin:/usr/bin",
            isExecutable: { $0 == "/fake/bin/op" }
        )
        #expect(resolved == "/fake/bin/op")
    }

    @Test func bareName_searchesPATHInOrder() {
        var consulted: [String] = []
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "op", pathValue: "/first:/second:/third",
            isExecutable: { consulted.append($0); return $0 == "/second/op" }
        )
        #expect(resolved == "/second/op")
        #expect(consulted == ["/first/op", "/second/op"])
    }

    @Test func bareName_miss_returnsNil() {
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "op", pathValue: "/first:/second",
            isExecutable: { _ in false }
        )
        #expect(resolved == nil)
    }

    @Test func bareName_noPATH_returnsNil() {
        var consulted = false
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "op", pathValue: nil,
            isExecutable: { _ in consulted = true; return true }
        )
        #expect(resolved == nil)
        #expect(consulted == false)
    }

    @Test func bareName_emptyPATH_returnsNil() {
        let resolved = OnePasswordCLIRunner.resolveExecutable(
            command: "op", pathValue: "",
            isExecutable: { _ in true }
        )
        #expect(resolved == nil)
    }
}

// MARK: - Vault-qualified resolution

@Suite("OnePasswordQualifiedResolution")
private struct OnePasswordQualifiedResolutionTests {
    @Test func fullyQualifiedURI_resolvesAsIsWithOneSpawn() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item-abc/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == ["read op://vault-123/item-abc/password --account=my.1password.com"])
    }

    @Test func pickerShaped_appendsCredentialField() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(item: "op://vault-123/item-abc", field: nil)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == ["read op://vault-123/item-abc/credential --account=my.1password.com"])
    }

    @Test func vaultNameAddressed_resolvesViaOwner() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(
            item: "op://Personal/item-abc/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == ["read op://Personal/item-abc/password --account=my.1password.com"])
    }

    @Test func routesThroughAccountOwningTheVaultID() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [
            serviceAccount(),
            desktopAccount(id: "acct-personal", name: "Personal"),
        ])
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item-abc/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
        let invocations = try fake.invocations()
        #expect(invocations.count == 1)
        #expect(invocations.first?.contains("--account=my.1password.com") == true)
    }

    @Test func firstAccountServesASharedVaultID() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [
            desktopAccount(id: "a", name: "A", accountName: "a.1password.com"),
            desktopAccount(id: "b", name: "B", accountName: "b.1password.com"),
        ])
        _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(try fake.invocations() == ["read op://vault-123/item/password --account=a.1password.com"])
    }

    @Test func vaultIDBeatsVaultNameAcrossAccounts() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [
            desktopAccount(
                id: "a", name: "A", accountName: "a.1password.com",
                vaults: [OnePasswordVault(id: "vault-a", name: "vault-b")]
            ),
            desktopAccount(
                id: "b", name: "B", accountName: "b.1password.com",
                vaults: [OnePasswordVault(id: "vault-b", name: "Other")]
            ),
        ])
        _ = try await provider.resolveQualified(item: "op://vault-b/item/password", field: nil)
        #expect(try fake.invocations() == ["read op://vault-b/item/password --account=b.1password.com"])
    }

    @Test func vaultNameInTwoAccounts_isAmbiguous() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [
            desktopAccount(
                id: "a", name: "Work", accountName: "a.1password.com",
                vaults: [OnePasswordVault(id: "vault-a", name: "Shared")]
            ),
            desktopAccount(
                id: "b", name: "Personal", accountName: "b.1password.com",
                vaults: [OnePasswordVault(id: "vault-b", name: "Shared")]
            ),
        ])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveQualified(item: "op://Shared/item", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func vaultNameTwiceInOneAccount_isAmbiguous() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-a", name: "Shared"),
            OnePasswordVault(id: "vault-b", name: "Shared"),
        ])])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveQualified(item: "op://Shared/item", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func outsideConfiguredVaults_isNotFound() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-999/item/password", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func signinExpiredStderr_degradesToNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.exit", "1")
        try fake.write(
            "read.stderr",
            "[ERROR] 2026/01/02 03:04:05 session expired, run `op signin` to authenticate\n"
        )
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func malformedURIs_areNotFoundWithoutSpawning() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        for item in ["op://", "op://vault", "op://vault/", "op:///item", "op://v//f", "op://v/./"] {
            await #expect(throws: SecretsError.notFound("onepassword")) {
                try await provider.resolveQualified(item: item, field: nil)
            }
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func fieldExtendsTheURIWithoutCredentialAppend() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        let value = try await provider.resolveQualified(item: "op://vault-123/item", field: "password")
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == ["read op://vault-123/item/password"])
    }

    @Test func qualifiedPerformsNoListing() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        let invocations = try fake.invocations()
        #expect(invocations.count == 1)
        #expect(invocations.allSatisfy { $0.hasPrefix("read ") })
    }

    @Test func readFailure_degradesToNotFoundWithoutEcho() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.exit", "1")
        try fake.write("read.stderr", "[ERROR] \"op://vault-123/item-abc/password\" is not found\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item-abc/password", field: nil)
        }
    }

    @Test func readSilentFailure_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.exit", "1")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func readFailureWithInvalidUTF8Stderr_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.exit", "1")
        try fake.write("read.stderr", Data([0xFF, 0xFE, 0x0A]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func nonUTF8Stdout_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", Data([0xFF, 0xFE]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func emptyRead_resolvesExplicitEmpty() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(value == .text(""))
    }

    @Test func stripsTrailingNewlineVariants() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        for (raw, expected) in [
            ("v\n", "v"), ("v\r\n", "v"), ("v\n\n\n", "v"), ("v\r\n\r\n", "v"),
            ("a\nb\n", "a\nb"), ("a\r\nb\r\n", "a\r\nb"), ("v", "v"),
        ] {
            try fake.write("read.stdout", raw)
            let value = try await provider.resolveQualified(
                item: "op://vault-123/item/password", field: nil
            )
            #expect(value == .text(expected))
        }
    }

    @Test func unicodeSecret_roundTripsExactly() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t-🔑-✓\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(value == .text("s3cr3t-🔑-✓"))
    }

    @Test func jsonLookingSecret_passesThroughVerbatim() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "{\"token\":\"abc\"}\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(value == .text("{\"token\":\"abc\"}"))
    }

    @Test func serviceAccount_tokenInEnvOnly() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let token = "ops_test_token_123"
        let provider = makeProvider(fake, accounts: [serviceAccount(
            token: token, vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        let invocations = try fake.invocations()
        #expect(invocations == ["read op://vault-123/item/password"])
        for line in invocations {
            #expect(line.contains(token) == false)
            #expect(line.contains("--account") == false)
        }
        #expect(try fake.envLog() == ["set \(token.count)"])
    }

    @Test func desktop_stripsInheritedTokenAndFlagsAccountLast() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(
            fake, accounts: [desktopAccount()],
            environment: testEnvironment(fake, extra: ["OP_SERVICE_ACCOUNT_TOKEN": "ops_inherited_token"])
        )
        _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(try fake.invocations() == ["read op://vault-123/item/password --account=my.1password.com"])
        #expect(try fake.envLog() == ["unset"])
    }
}

// MARK: - Bare resolution

@Suite("OnePasswordBareResolution")
private struct OnePasswordBareResolutionTests {
    @Test func singleMatchAcrossAccounts_resolvesCredentialURI() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-eng.json", try itemsJSON([("item-1", "GitHub Token")]))
        try fake.write("items.vault-home.json", try itemsJSON([("item-2", "Stripe Key")]))
        try fake.write("read.stdout", "ghp_secret\n")
        let provider = makeProvider(fake, accounts: [
            serviceAccount(vaults: [OnePasswordVault(id: "vault-eng", name: "Engineering")]),
            serviceAccount(
                id: "acct-personal", name: "Personal",
                vaults: [OnePasswordVault(id: "vault-home", name: "Home")]
            ),
        ])
        let value = try await provider.resolveBare(item: "GitHub Token", field: nil)
        #expect(value == .text("ghp_secret"))
        #expect(try fake.invocations() == [
            "item list --vault vault-eng --format=json",
            "item list --vault vault-home --format=json",
            "read op://vault-eng/item-1/credential",
        ])
    }

    @Test func matchByItemID() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-9", "Something Else")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveBare(item: "item-9", field: nil)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations().last == "read op://vault-123/item-9/credential --account=my.1password.com")
    }

    @Test func matchByTitle_readsByItemID() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-7", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        _ = try await provider.resolveBare(item: "Deploy Key", field: nil)
        #expect(try fake.invocations().last == "read op://vault-123/item-7/credential --account=my.1password.com")
    }

    @Test func fieldOverridesCredentialForBareRefs() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-7", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        _ = try await provider.resolveBare(item: "Deploy Key", field: "password")
        #expect(try fake.invocations().last == "read op://vault-123/item-7/password --account=my.1password.com")
    }

    @Test func sameTitleInTwoAccounts_isAmbiguous() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-eng.json", try itemsJSON([("item-1", "GitHub Token")]))
        try fake.write("items.vault-home.json", try itemsJSON([("item-2", "GitHub Token")]))
        let provider = makeProvider(fake, accounts: [
            serviceAccount(vaults: [OnePasswordVault(id: "vault-eng", name: "Engineering")]),
            serviceAccount(
                id: "acct-personal", name: "Personal",
                vaults: [OnePasswordVault(id: "vault-home", name: "Home")]
            ),
        ])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
        let invocations = try fake.invocations()
        #expect(invocations.count == 2)
        #expect(invocations.allSatisfy { $0.hasPrefix("item list ") })
    }

    @Test func duplicateTitlesInsideOneVault_areAmbiguous() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([
            ("item-1", "GitHub Token"), ("item-9", "GitHub Token"),
        ]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func sameTitleInTwoVaultsOneAccount_isAmbiguous() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "GitHub Token")]))
        try fake.write("items.vault-456.json", try itemsJSON([("item-2", "GitHub Token")]))
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal"),
            OnePasswordVault(id: "vault-456", name: "Work"),
        ])])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func idPlusTitleMatch_isAmbiguous() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([
            ("GitHub Token", "Other Title"), ("item-2", "GitHub Token"),
        ]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.denied("onepassword:ambiguous")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func noMatch_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "GitHub Token")]))
        try fake.write("items.vault-456.json", "[]")
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal"),
            OnePasswordVault(id: "vault-456", name: "Work"),
        ])])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "missing", field: nil)
        }
    }

    @Test func emptyListings_areNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", "[]")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "missing", field: nil)
        }
    }

    @Test func listingFailure_degradesToNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.exit", "1")
        try fake.write("items.vault-123.stderr", "[ERROR] vault is gone\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func listingGarbageJSON_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", "not json at all{{{")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func listingWrongShapeJSON_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", "{\"id\":\"item-1\",\"title\":\"GitHub Token\"}")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func listingNonUTF8_isNotFound() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", Data([0xFF, 0xFE]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
    }

    @Test func rowsWithExtraMembers_stillMatch() async throws {
        let fake = try makeFakeOp()
        try fake.write(
            "items.vault-123.json",
            "[{\"id\":\"item-7\",\"title\":\"Deploy Key\",\"extra\":\"ignored\",\"nested\":{\"a\":1}}]"
        )
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveBare(item: "Deploy Key", field: nil)
        #expect(value == .text("s3cr3t"))
    }

    @Test func bareListsEveryVaultInOrder() async throws {
        let fake = try makeFakeOp()
        for vault in ["vault-a1", "vault-a2", "vault-b1"] {
            try fake.write("items.\(vault).json", "[]")
        }
        let provider = makeProvider(fake, accounts: [
            desktopAccount(
                id: "a", name: "A", accountName: "a.1password.com",
                vaults: [
                    OnePasswordVault(id: "vault-a1", name: "A1"),
                    OnePasswordVault(id: "vault-a2", name: "A2"),
                ]
            ),
            desktopAccount(
                id: "b", name: "B", accountName: "b.1password.com",
                vaults: [OnePasswordVault(id: "vault-b1", name: "B1")]
            ),
        ])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "missing", field: nil)
        }
        #expect(try fake.invocations() == [
            "item list --vault vault-a1 --format=json --account=a.1password.com",
            "item list --vault vault-a2 --format=json --account=a.1password.com",
            "item list --vault vault-b1 --format=json --account=b.1password.com",
        ])
    }

    @Test func matchInLastVault_readsAfterAllLists() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", "[]")
        try fake.write("items.vault-456.json", try itemsJSON([("item-2", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal"),
            OnePasswordVault(id: "vault-456", name: "Work"),
        ])])
        let value = try await provider.resolveBare(item: "Deploy Key", field: nil)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == [
            "item list --vault vault-123 --format=json --account=my.1password.com",
            "item list --vault vault-456 --format=json --account=my.1password.com",
            "read op://vault-456/item-2/credential --account=my.1password.com",
        ])
    }

    @Test func titleWithSlash_matchesExactly() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "team/api key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let value = try await provider.resolveBare(item: "team/api key", field: nil)
        #expect(value == .text("s3cr3t"))
    }

    @Test func accountWithoutVaults_contributesNothing() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [
            desktopAccount(id: "empty", name: "Empty", accountName: "e.1password.com", vaults: []),
            desktopAccount(),
        ])
        let value = try await provider.resolveBare(item: "Deploy Key", field: nil)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == [
            "item list --vault vault-123 --format=json --account=my.1password.com",
            "read op://vault-123/item-1/credential --account=my.1password.com",
        ])
    }

    @Test func readAfterListingFailureShape_stillReads() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        try fake.write("read.exit", "1")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "Deploy Key", field: nil)
        }
    }

    @Test func concurrentBareResolves_allSucceed() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-eng.json", try itemsJSON([("item-1", "GitHub Token")]))
        try fake.write("read.stdout", "ghp_secret\n")
        let provider = makeProvider(fake, accounts: [serviceAccount()])
        try await withThrowingTaskGroup(of: SecretValue.self) { group in
            for _ in 0..<10 {
                group.addTask { try await provider.resolveBare(item: "GitHub Token", field: nil) }
            }
            for try await value in group {
                #expect(value == .text("ghp_secret"))
            }
        }
    }
}

// MARK: - Top-level dispatch

@Suite("OnePasswordResolveDispatch")
private struct OnePasswordResolveDispatchTests {
    @Test func wrongProvider_isInvalidRef() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: "file", item: "op://vault-123/item/password")
        await #expect(throws: SecretsError.invalidRef("onepassword")) {
            try await provider.resolve(ref)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func unconfigured_isProviderDown() async throws {
        let fake = try makeFakeOp()
        let provider = makeStandInProvider(fake, accounts: [])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item/password")
        await #expect(throws: SecretsError.providerDown(standInProviderID)) {
            try await provider.resolve(ref)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func opItem_dispatchesToQualifiedResolution() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc")
        let value = try await provider.resolve(ref)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations() == ["read op://vault-123/item-abc/credential --account=my.1password.com"])
    }

    @Test func bareItem_dispatchesToBareResolution() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "Deploy Key")
        let value = try await provider.resolve(ref)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations().count == 2)
    }

    @Test func bareItemWithField_dispatchesFieldThrough() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "Deploy Key", field: "username")
        _ = try await provider.resolve(ref)
        #expect(try fake.invocations().last == "read op://vault-123/item-1/username --account=my.1password.com")
    }

    @Test func midStringOpMarker_staysBare() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "xop://y")]))
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "xop://y")
        let value = try await provider.resolve(ref)
        #expect(value == .text("s3cr3t"))
        #expect(try fake.invocations().last == "read op://vault-123/item-1/credential --account=my.1password.com")
    }

    @Test func cancelledEntry_throwsCancellation() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: "file", item: "anything")
        let started = Mutex(false)
        let proceed = Mutex(false)
        let task = Task {
            started.withLock { $0 = true }
            while proceed.withLock({ $0 }) == false {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return try await provider.resolve(ref)
        }
        while started.withLock({ $0 }) == false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        proceed.withLock { $0 = true }
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(try fake.invocations().isEmpty)
    }
}

// MARK: - Cached ref resolver

@Suite("OnePasswordRefCache")
private struct OnePasswordRefCacheTests {
    @Test func repeatedResolveWithinTTL_spawnsOnce() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        let first = try await provider.resolve(ref)
        let second = try await provider.resolve(ref)
        #expect(first == .text("s3cr3t"))
        #expect(second == first)
        #expect(try fake.invocations().count == 1)
    }

    @Test func expiredTTL_asksBackendAgain() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(
            fake, accounts: [desktopAccount()], cacheTTLSeconds: 0.1
        )
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        _ = try await provider.resolve(ref)
        try await Task.sleep(nanoseconds: 300_000_000)
        try fake.write("read.stdout", "rotated\n")
        let second = try await provider.resolve(ref)
        #expect(second == .text("rotated"))
        #expect(try fake.invocations().count == 2)
    }

    @Test func notFound_neverRetained() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "missing")
        for _ in 0..<2 {
            await #expect(throws: SecretsError.notFound(standInProviderID)) {
                try await provider.resolve(ref)
            }
        }
        #expect(try fake.invocations().count == 2)
    }

    @Test func ambiguity_neverRetained() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "Deploy Key")]))
        try fake.write("items.vault-456.json", try itemsJSON([("item-2", "Deploy Key")]))
        let provider = makeStandInProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal"),
            OnePasswordVault(id: "vault-456", name: "Work"),
        ])])
        let ref = try SecretRef(provider: standInProviderID, item: "Deploy Key")
        for _ in 0..<2 {
            await #expect(throws: SecretsError.denied("\(standInProviderID):ambiguous")) {
                try await provider.resolve(ref)
            }
        }
        #expect(try fake.invocations().count == 4)
    }

    @Test func readFailure_neverRetained() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.exit", "1")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        for _ in 0..<2 {
            await #expect(throws: SecretsError.notFound(standInProviderID)) {
                try await provider.resolve(ref)
            }
        }
        #expect(try fake.invocations().count == 2)
    }

    @Test func configChange_dropsCachedSecrets() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "first\n")
        var provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        #expect(try await provider.resolve(ref) == .text("first"))
        // Same ref, edited config (one vault added): the cached generation
        // must not serve secrets the new config re-reads.
        try fake.write("read.stdout", "second\n")
        provider.accounts = [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal"),
            OnePasswordVault(id: "vault-new", name: "New"),
        ])]
        #expect(try await provider.resolve(ref) == .text("second"))
        #expect(try fake.invocations().count == 2)
    }

    @Test func tokenRotation_dropsCachedSecrets() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let firstToken = "ops_first_token_aaa"
        let rotatedToken = "ops_rotated_token_bbb"
        var provider = makeStandInProvider(fake, accounts: [serviceAccount(
            token: firstToken,
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        _ = try await provider.resolve(ref)
        provider.accounts = [serviceAccount(
            token: rotatedToken,
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )]
        _ = try await provider.resolve(ref)
        #expect(try fake.invocations().count == 2)
        #expect(try fake.envLog() == ["set \(firstToken.count)", "set \(rotatedToken.count)"])
    }

    @Test func nonPositiveTTL_everyResolveReachesBackend() async throws {
        for ttl in [0.0, -30.0] {
            let fake = try makeFakeOp()
            try fake.write("read.stdout", "s3cr3t\n")
            let provider = makeStandInProvider(
                fake, accounts: [desktopAccount()], cacheTTLSeconds: ttl
            )
            let ref = try SecretRef(
                provider: standInProviderID, item: "op://vault-123/item-abc/password"
            )
            _ = try await provider.resolve(ref)
            _ = try await provider.resolve(ref)
            #expect(try fake.invocations().count == 2)
        }
    }

    @Test func fieldDistinction_keepsSeparateEntries() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let password = try SecretRef(
            provider: standInProviderID, item: "op://vault-123/item-abc", field: "password"
        )
        let username = try SecretRef(
            provider: standInProviderID, item: "op://vault-123/item-abc", field: "username"
        )
        _ = try await provider.resolve(password)
        _ = try await provider.resolve(username)
        _ = try await provider.resolve(password)
        #expect(try fake.invocations() == [
            "read op://vault-123/item-abc/password --account=my.1password.com",
            "read op://vault-123/item-abc/username --account=my.1password.com",
        ])
    }

    @Test func cancelledResolve_neverServedFromCache() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        #expect(try await provider.resolve(ref) == .text("s3cr3t"))
        let proceed = Mutex(false)
        let task = Task {
            while proceed.withLock({ $0 }) == false {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return try await provider.resolve(ref)
        }
        task.cancel()
        proceed.withLock { $0 = true }
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // The priming resolve spawned once; the cancelled resolve spawned
        // nothing and served nothing.
        #expect(try fake.invocations().count == 1)
    }

    @Test func staleGenerationStore_isDropped() async {
        let cache = OnePasswordRefCache()
        let genA = [serviceAccount()]
        let genB = [desktopAccount()]
        let key = OnePasswordCacheKey(item: "op://vault-123/item/password", field: nil)
        _ = await cache.lookup(key: key, accounts: genA)
        await cache.store(key: key, value: .text("x"), accounts: genB, ttlSeconds: 60)
        #expect(await cache.lookup(key: key, accounts: genA) == nil)
    }

    @Test func expiredEntry_servesMiss() async throws {
        let cache = OnePasswordRefCache()
        let accounts = [serviceAccount()]
        let key = OnePasswordCacheKey(item: "op://vault-123/item/password", field: nil)
        _ = await cache.lookup(key: key, accounts: accounts)
        await cache.store(key: key, value: .text("v"), accounts: accounts, ttlSeconds: 0.05)
        #expect(await cache.lookup(key: key, accounts: accounts) == .text("v"))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await cache.lookup(key: key, accounts: accounts) == nil)
    }

    @Test func providerCopies_shareOneCachedGeneration() async throws {
        // The provider is a struct over a shared cache actor: copies serve
        // one generation instead of each paying backend reads.
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeStandInProvider(fake, accounts: [desktopAccount()])
        let ref = try SecretRef(provider: standInProviderID, item: "op://vault-123/item-abc/password")
        _ = try await provider.resolve(ref)
        let copy = provider
        #expect(try await copy.resolve(ref) == .text("s3cr3t"))
        #expect(try fake.invocations().count == 1)
    }

    @Test func capacityOverflow_evictsOldestFirst() async {
        let cache = OnePasswordRefCache()
        let accounts = [serviceAccount()]
        let capacity = OnePasswordSecretsProvider.secretCacheCapacity
        for index in 0...(capacity) {
            let key = OnePasswordCacheKey(item: "item-\(index)", field: nil)
            _ = await cache.lookup(key: key, accounts: accounts)
            await cache.store(
                key: key, value: .text("v-\(index)"),
                accounts: accounts, ttlSeconds: 60
            )
        }
        let first = OnePasswordCacheKey(item: "item-0", field: nil)
        let last = OnePasswordCacheKey(item: "item-\(capacity)", field: nil)
        #expect(await cache.lookup(key: first, accounts: accounts) == nil)
        #expect(await cache.lookup(key: last, accounts: accounts) == .text("v-\(capacity)"))
    }
}

// MARK: - Command injection

@Suite("OnePasswordCommandInjection")
private struct OnePasswordCommandInjectionTests {
    @Test func qualifiedMetacharacters_passedAsSingleArgv() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        // Every shell metacharacter class, plus live sentinels: if any
        // layer shelled out, a sentinel file would exist afterwards. The
        // sentinel payloads ride in the field (last position, read as-is,
        // slashes harmless); vault and item segments stay slash-free so
        // URI routing still matches by id.
        let sentinelA = fake.dir.appendingPathComponent("pwned-a").path
        let sentinelB = fake.dir.appendingPathComponent("pwned-b").path
        let vaultID = "vault 1;echo pwned"
        let item = "it'em\"a|b&c<d>e\\f$g`q`$(x)"
        let field = "f/g;touch \(sentinelA);$(touch \(sentinelB))"
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: vaultID, name: "N"),
        ])])
        let value = try await provider.resolveQualified(
            item: "op://\(vaultID)/\(item)", field: field
        )
        #expect(value == .text("s3cr3t"))
        #expect(try fake.singleArgv() == [
            "read", "op://\(vaultID)/\(item)/\(field)", "--account=my.1password.com",
        ])
        #expect(FileManager.default.fileExists(atPath: sentinelA) == false)
        #expect(FileManager.default.fileExists(atPath: sentinelB) == false)
    }

    @Test func listingVaultID_passedAsSingleArgv() async throws {
        let fake = try makeFakeOp()
        // No `/`: the fake keys per-vault listings off the filename
        // `items.<vault>.json`, so a slash is unrepresentable there (see
        // the harness fidelity limits). Every other metacharacter class
        // is covered; slashes are proven on the read path above.
        let vaultID = "vault x'y\"z;$(())`b` a|b&c$d\\\\e"
        try fake.write("items.\(vaultID).json", "[]")
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: vaultID, name: "N"),
        ])])
        await #expect(throws: SecretsError.notFound("onepassword")) {
            try await provider.resolveBare(item: "missing", field: nil)
        }
        #expect(try fake.singleArgv() == [
            "item", "list", "--vault", vaultID, "--format=json",
            "--account=my.1password.com",
        ])
    }

    @Test func desktopAccountName_passedAsSingleArgv() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let sentinel = fake.dir.appendingPathComponent("pwned").path
        let name = "evil;touch \(sentinel)\"'`$(x)"
        let provider = makeProvider(fake, accounts: [desktopAccount(accountName: name)])
        _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        #expect(try fake.singleArgv() == [
            "read", "op://vault-123/item/password", "--account=\(name)",
        ])
        #expect(FileManager.default.fileExists(atPath: sentinel) == false)
    }

    @Test func bareFieldMetacharacters_neverShelled() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-7", "Deploy Key")]))
        try fake.write("read.stdout", "s3cr3t\n")
        // Bare refs build `op://vault/itemID/<field>` for the read, so the
        // field meets argv exactly like a qualified URI tail. Two spawns
        // (list + read) share `argv.bin` without record boundaries, so the
        // live sentinels plus the invocation count carry the proof here.
        let sentinel = fake.dir.appendingPathComponent("pwned-bare").path
        let field = "f;touch \(sentinel)$((touch \(sentinel).2))`x`"
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        _ = try await provider.resolveBare(item: "Deploy Key", field: field)
        let invocations = try fake.invocations()
        #expect(invocations.count == 2)
        #expect(invocations.last?.contains(field) == true)
        #expect(FileManager.default.fileExists(atPath: sentinel) == false)
        #expect(FileManager.default.fileExists(atPath: sentinel + ".2") == false)
    }

    @Test func newlinesInNames_passedThroughVerbatim() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let vaultID = "vault\nnewline"
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: vaultID, name: "N"),
        ])])
        let value = try await provider.resolveQualified(
            item: "op://\(vaultID)/item/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
        #expect(try fake.singleArgv() == [
            "read", "op://\(vaultID)/item/password", "--account=my.1password.com",
        ])
    }
}

// MARK: - Redaction

@Suite("OnePasswordRedaction")
private struct OnePasswordRedactionTests {
    @Test func qualifiedFailure_errorCarriesNoNamesOrSecrets() async throws {
        let fake = try makeFakeOp()
        let secretItem = "ghp_live_secret_item_abc"
        try fake.write("read.exit", "1")
        try fake.write(
            "read.stderr",
            "[ERROR] \"op://vault-123/\(secretItem)/password\" denied: token ops_leaked_token_xyz rejected\n"
        )
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        do {
            _ = try await provider.resolveQualified(
                item: "op://vault-123/\(secretItem)/password", field: nil
            )
            Issue.record("expected notFound")
        } catch {
            let text = String(describing: error)
            #expect(text.contains(secretItem) == false)
            #expect(text.contains("vault-123") == false)
            #expect(text.contains("ops_leaked_token_xyz") == false)
            #expect(error as? SecretsError == SecretsError.notFound("onepassword"))
        }
    }

    @Test func bareFailure_errorCarriesNoTitlesOrVaults() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.exit", "1")
        try fake.write(
            "items.vault-123.stderr",
            "[ERROR] vault \"Top Secret Vault\" unreadable for item \"My Secret Title\"\n"
        )
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        do {
            _ = try await provider.resolveBare(item: "My Secret Title", field: nil)
            Issue.record("expected notFound")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("My Secret Title") == false)
            #expect(text.contains("Top Secret Vault") == false)
            #expect(error as? SecretsError == SecretsError.notFound("onepassword"))
        }
    }

    @Test func ambiguity_errorNamesNoMatches() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", try itemsJSON([("item-1", "ghp_secret_title")]))
        try fake.write("items.vault-456.json", try itemsJSON([("item-2", "ghp_secret_title")]))
        let provider = makeProvider(fake, accounts: [desktopAccount(vaults: [
            OnePasswordVault(id: "vault-123", name: "Personal Secrets"),
            OnePasswordVault(id: "vault-456", name: "Work Secrets"),
        ])])
        do {
            _ = try await provider.resolveBare(item: "ghp_secret_title", field: nil)
            Issue.record("expected ambiguity")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("ghp_secret_title") == false)
            #expect(text.contains("Personal Secrets") == false)
            #expect(text.contains("Work Secrets") == false)
            #expect(error as? SecretsError == SecretsError.denied("onepassword:ambiguous"))
        }
    }

    @Test func serviceToken_neverSurfacesInErrors() async throws {
        let fake = try makeFakeOp()
        let token = "ops_real_token_secret_1"
        try fake.write("read.exit", "1")
        try fake.write("read.stderr", "[ERROR] invalid service account token\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            token: token, vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        do {
            _ = try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
            Issue.record("expected notFound")
        } catch {
            #expect(String(describing: error).contains(token) == false)
            #expect(error as? SecretsError == SecretsError.notFound("onepassword"))
        }
    }
}

// MARK: - Health

@Suite("OnePasswordHealth")
private struct OnePasswordHealthTests {
    @Test func healthySingleAccount_reportsReachable() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", try vaultsJSON([("vault-123", "Personal")]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let health = await provider.health()
        #expect(health == ProviderHealth(ok: true))
        #expect(health.identity == nil)
        #expect(try fake.invocations() == ["vault list --format=json --account=my.1password.com"])
    }

    @Test func healthyMultiAccount_checksEveryAccount() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", try vaultsJSON([("vault-x", "X")]))
        let provider = makeProvider(fake, accounts: [
            desktopAccount(id: "a", name: "A", accountName: "a.1password.com"),
            serviceAccount(id: "b", name: "B"),
        ])
        let health = await provider.health()
        #expect(health.ok)
        #expect(try fake.invocations() == [
            "vault list --format=json --account=a.1password.com",
            "vault list --format=json",
        ])
    }

    @Test func oneAccountFailing_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.exit", "1")
        try fake.write("vaults.stderr", "[ERROR] locked\n")
        let provider = makeProvider(fake, accounts: [
            desktopAccount(),
            serviceAccount(id: "b", name: "B"),
        ])
        let health = await provider.health()
        #expect(health == ProviderHealth(ok: false))
    }

    @Test func failingSecondAccount_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", try vaultsJSON([("vault-123", "Personal")]))
        let first = makeProvider(fake, accounts: [desktopAccount()])
        #expect(await first.health() == ProviderHealth(ok: true))
        try fake.write("vaults.exit", "1")
        let both = makeProvider(fake, accounts: [desktopAccount(), serviceAccount(id: "b", name: "B")])
        #expect(await both.health() == ProviderHealth(ok: false))
    }

    @Test func garbageVaultJSON_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", "not json{{{")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func wrongShapeVaultJSON_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", "{\"id\":\"v\"}")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func vaultRowsWithExtraMembers_stillHealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", "[{\"id\":\"vault-1\",\"name\":\"Personal\",\"extra\":\"ignored\"}]")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func missingConfiguredVaults_stillHealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", try vaultsJSON([("vault-other", "Other")]))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func cliMissing_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        let provider = OnePasswordSecretsProvider(
            accounts: [desktopAccount()], opCommand: fake.dir.appendingPathComponent("no-op").path,
            timeoutSeconds: 15, environment: { testEnvironment(fake) }
        )
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func timeout_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("hang", "")
        let provider = makeProvider(fake, accounts: [serviceAccount()], timeoutSeconds: 1)
        #expect(await provider.health() == ProviderHealth(ok: false))
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func unconfigured_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [])
        #expect(await provider.health() == ProviderHealth(ok: false))
        #expect(try fake.invocations().isEmpty)
    }

    @Test func cancelledTask_isUnhealthy() async throws {
        let fake = try makeFakeOp()
        try fake.write("delay", "5")
        try fake.write("vaults.json", "[]")
        let provider = makeProvider(fake, accounts: [serviceAccount()])
        let task = Task { await provider.health() }
        _ = await awaitSpawn(fake)
        task.cancel()
        #expect(await task.value == ProviderHealth(ok: false))
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func serviceHealth_tokenInEnvOnly() async throws {
        let fake = try makeFakeOp()
        try fake.write("vaults.json", "[]")
        let token = "ops_health_token_xyz"
        let provider = makeProvider(fake, accounts: [serviceAccount(token: token)])
        #expect(await provider.health() == ProviderHealth(ok: true))
        for line in try fake.invocations() {
            #expect(line.contains(token) == false)
        }
        #expect(try fake.envLog() == ["set \(token.count)"])
    }
}

// MARK: - Spawn behavior: timeouts, kills, limits, lookup

@Suite("OnePasswordSpawnBehavior")
private struct OnePasswordSpawnBehaviorTests {
    @Test func timeoutKillsHungRead() async throws {
        let fake = try makeFakeOp()
        try fake.write("hang", "")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )], timeoutSeconds: 1)
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        // No argv assertion: under parallel load the timeout can fire before
        // the child is first scheduled. Argv shape is pinned elsewhere.
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func timeoutDuringListing_mapsTimeout() async throws {
        let fake = try makeFakeOp()
        try fake.write("hang", "")
        let provider = makeProvider(fake, accounts: [serviceAccount()], timeoutSeconds: 1)
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func providerRecoversAfterTimeout() async throws {
        let fake = try makeFakeOp()
        try fake.write("hang", "")
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )], timeoutSeconds: 1)
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        try fake.remove("hang")
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
    }

    @Test func partialOutputBeforeHang_neverServedOnTimeout() async throws {
        // The fake cannot stream (whole-file cats only), so this shape
        // needs a dedicated script op: partial stdout, then a hang.
        let script = try makeScriptOp(body: """
            echo "$$" >>"$FAKEOP_DIR/pids.log"
            printf 'partial-secret-bytes'
            exec sleep 300
            """)
        let provider = OnePasswordSecretsProvider(
            accounts: [serviceAccount(
                vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
            )],
            opCommand: script.opPath, timeoutSeconds: 1,
            environment: { testEnvironment(script) }
        )
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        await expectDead(try script.pids())
    }

    @Test func timeoutDoesNotWaitForPipeHolders() async throws {
        // A grandchild holds the pipes 60s while the main child hangs
        // forever; the 1s timeout must finish without waiting for either
        // horizon. No elapsed assertion: under full-target parallel load
        // a 1s sleep can fire seconds late, so timing bounds flake. The
        // grandchild marker is the load-immune proof instead: it appears
        // only when the pipe-holder exits, so its absence at resolve time
        // proves the timeout path never waited for EOF. The main child
        // hangs forever (never a bounded delay), so even a late-firing
        // timeout still yields the timeout outcome, never success.
        let script = try makeScriptOp(body: """
            echo "$$" >>"$FAKEOP_DIR/pids.log"
            (sleep 60; touch "$FAKEOP_DIR/grandchild-done") & echo $! >"$FAKEOP_DIR/grandchild.pid"
            exec sleep 300
            """)
        let provider = OnePasswordSecretsProvider(
            accounts: [serviceAccount(
                vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
            )],
            opCommand: script.opPath, timeoutSeconds: 1,
            environment: { testEnvironment(script) }
        )
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: script.dir.appendingPathComponent("grandchild-done").path
            ) == false
        )
        await expectDead(try script.pids())
        // Reap the pipe-holder instead of orphaning a 60s sleeper.
        let grandchildPID = try String(
            contentsOf: script.dir.appendingPathComponent("grandchild.pid"), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int32(grandchildPID) {
            kill(pid, SIGKILL)
            await expectDead([pid])
        }
    }

    @Test func exitBeforeEOF_waitsForDrainedOutput() async throws {
        let fake = try makeFakeOp()
        try fake.write("linger", "1")
        try fake.write("read.stdout", "slow-secret\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        let start = Date()
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item/password", field: nil
        )
        #expect(value == .text("slow-secret"))
        #expect(Date().timeIntervalSince(start) >= 0.5)
    }

    @Test func slowButWithinBudget_succeeds() async throws {
        let fake = try makeFakeOp()
        try fake.write("delay", "1")
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )], timeoutSeconds: 15)
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
    }

    @Test func zeroTimeout_timesOutWithoutSpawning() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()], timeoutSeconds: 0)
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func negativeTimeout_timesOutWithoutSpawning() async throws {
        let fake = try makeFakeOp()
        let provider = makeProvider(fake, accounts: [desktopAccount()], timeoutSeconds: -5)
        await #expect(throws: SecretsError.timeout("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func oversizedRead_killsChildAndMapsOversized() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", Data(repeating: 0x78, count: 2_097_152))
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        await #expect(throws: SecretsError.oversized("onepassword")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func oversizedListing_mapsOversized() async throws {
        let fake = try makeFakeOp()
        try fake.write("items.vault-123.json", Data(repeating: 0x78, count: 2_097_152))
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        await #expect(throws: SecretsError.oversized("onepassword")) {
            try await provider.resolveBare(item: "GitHub Token", field: nil)
        }
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func largeButUnderCap_succeeds() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", Data(repeating: 0x79, count: 524_288))
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item/password", field: nil
        )
        #expect(value == .text(String(repeating: "y", count: 524_288)))
    }

    @Test func missingAbsoluteCommand_isProviderDown() async throws {
        let fake = try makeFakeOp()
        let provider = OnePasswordSecretsProvider(
            accounts: [desktopAccount()],
            opCommand: fake.dir.appendingPathComponent("no-such-op").path,
            timeoutSeconds: 15, environment: { testEnvironment(fake) }
        )
        await #expect(throws: SecretsError.providerDown("onepassword:cli")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        #expect(try fake.invocations().isEmpty)
    }

    @Test func directoryAsCommand_isProviderDown() async throws {
        let fake = try makeFakeOp()
        let provider = OnePasswordSecretsProvider(
            accounts: [desktopAccount()], opCommand: fake.dir.path,
            timeoutSeconds: 15, environment: { testEnvironment(fake) }
        )
        await #expect(throws: SecretsError.providerDown("onepassword:cli")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func bareCommand_resolvesThroughPATH() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = OnePasswordSecretsProvider(
            accounts: [serviceAccount(
                vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
            )],
            opCommand: "op", timeoutSeconds: 15,
            environment: { testEnvironment(fake, extra: ["PATH": "\(fake.dir.path):/usr/bin:/bin"]) }
        )
        let value = try await provider.resolveQualified(
            item: "op://vault-123/item/password", field: nil
        )
        #expect(value == .text("s3cr3t"))
    }

    @Test func bareCommandMissingFromPATH_isProviderDown() async throws {
        let fake = try makeFakeOp()
        let provider = OnePasswordSecretsProvider(
            accounts: [desktopAccount()], opCommand: "rv-no-such-op-xyz",
            timeoutSeconds: 15, environment: { testEnvironment(fake) }
        )
        await #expect(throws: SecretsError.providerDown("onepassword:cli")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func bareCommandWithoutPATH_isProviderDown() async throws {
        let provider = OnePasswordSecretsProvider(
            accounts: [desktopAccount()], opCommand: "op",
            timeoutSeconds: 15, environment: { [:] }
        )
        await #expect(throws: SecretsError.providerDown("onepassword:cli")) {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
    }

    @Test func cancellationDuringRead_killsChildAndThrowsCancellation() async throws {
        let fake = try makeFakeOp()
        // Generous delay: under full-target parallel load a fixed sleep
        // can fire seconds late, so the cancel must be event-driven
        // (awaitSpawn, like the listing twin) with wall-clock margin.
        try fake.write("delay", "30")
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        let task = Task {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        _ = await awaitSpawn(fake)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func cancellationDuringListing_throwsCancellation() async throws {
        let fake = try makeFakeOp()
        try fake.write("delay", "5")
        try fake.write("items.vault-123.json", "[]")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let task = Task { try await provider.resolveBare(item: "GitHub Token", field: nil) }
        _ = await awaitSpawn(fake)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        let pids = try fake.pids()
        await expectDead(pids)
    }

    @Test func cancelledWhileQueuedAtPromptGate_throwsCancellation() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        let entered = Mutex(false)
        let releaseGate = Mutex(false)
        let holder = Task {
            try await OnePasswordDesktopSpawnGate.shared.run {
                entered.withLock { $0 = true }
                while releaseGate.withLock({ $0 }) == false {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return 0
            }
        }
        // Generous deadline: the holder contends for the process-shared
        // gate with every desktop test in the target, and under full-target
        // parallel load on a slow host the queue can take a minute to drain.
        // The assertions below are unchanged; only starvation tolerance grew.
        let deadline = Date().addingTimeInterval(180)
        while entered.withLock({ $0 }) == false && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard entered.withLock({ $0 }) else {
            Issue.record("prompt gate never drained")
            releaseGate.withLock { $0 = true }
            _ = try await holder.value
            return
        }
        let task = Task {
            try await provider.resolveQualified(item: "op://vault-123/item/password", field: nil)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        releaseGate.withLock { $0 = true }
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(try await holder.value == 0)
    }

    @Test func manyConcurrentQualifiedResolves_allSucceed() async throws {
        let fake = try makeFakeOp()
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [serviceAccount(
            vaults: [OnePasswordVault(id: "vault-123", name: "Personal")]
        )])
        try await withThrowingTaskGroup(of: SecretValue.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await provider.resolveQualified(
                        item: "op://vault-123/item/password", field: nil
                    )
                }
            }
            for try await value in group {
                #expect(value == .text("s3cr3t"))
            }
        }
        #expect(try fake.invocations().count == 20)
    }

    @Test func concurrentDesktopResolves_allSucceed() async throws {
        let fake = try makeFakeOp()
        try fake.write("delay", "0.2")
        try fake.write("read.stdout", "s3cr3t\n")
        let provider = makeProvider(fake, accounts: [desktopAccount()])
        try await withThrowingTaskGroup(of: SecretValue.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await provider.resolveQualified(
                        item: "op://vault-123/item/password", field: nil
                    )
                }
            }
            for try await value in group {
                #expect(value == .text("s3cr3t"))
            }
        }
    }
}

// MARK: - Desktop spawn gate

@Suite("OnePasswordDesktopSpawnGate")
private struct OnePasswordDesktopSpawnGateTests {
    @Test func singleBody_runsImmediately() async throws {
        let gate = OnePasswordDesktopSpawnGate()
        let value = try await gate.run { 42 }
        #expect(value == 42)
    }

    @Test func concurrentBodies_serializeFIFO() async throws {
        let gate = OnePasswordDesktopSpawnGate()
        let entered = Mutex<[String]>([])
        let releaseA = Mutex(false)

        let taskA = Task {
            try await gate.run {
                entered.withLock { $0.append("A") }
                while releaseA.withLock({ $0 }) == false {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return "A"
            }
        }
        while entered.withLock({ $0.isEmpty }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let taskB = Task { try await gate.run {
            entered.withLock { $0.append("B") }
            return "B"
        } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let taskC = Task { try await gate.run {
            entered.withLock { $0.append("C") }
            return "C"
        } }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(entered.withLock { $0 } == ["A"])
        releaseA.withLock { $0 = true }
        #expect(try await taskA.value == "A")
        #expect(try await taskB.value == "B")
        #expect(try await taskC.value == "C")
        #expect(entered.withLock { $0 } == ["A", "B", "C"])
    }

    @Test func cancelledWaiter_throwsWithoutRunningItsBody() async throws {
        let gate = OnePasswordDesktopSpawnGate()
        let enteredA = Mutex(false)
        let enteredB = Mutex(false)
        let releaseA = Mutex(false)
        let taskA = Task {
            try await gate.run {
                enteredA.withLock { $0 = true }
                while releaseA.withLock({ $0 }) == false {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return "A"
            }
        }
        while enteredA.withLock({ $0 }) == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let taskB = Task { try await gate.run {
            enteredB.withLock { $0 = true }
            return "B"
        } }
        try await Task.sleep(nanoseconds: 200_000_000)
        taskB.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(enteredB.withLock { $0 } == false)
        releaseA.withLock { $0 = true }
        #expect(try await taskA.value == "A")
        do {
            _ = try await taskB.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(enteredB.withLock { $0 } == false)
        let value = try await gate.run { "C" }
        #expect(value == "C")
    }
}

// MARK: - Spawn box

@Suite("OnePasswordSpawnBox")
private struct OnePasswordSpawnBoxTests {
    @Test func cliMissing_resumesOnceAndIgnoresLateFinishes() async {
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        let outcome = await withCheckedContinuation { (
            continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
        ) in
            box.begin(
                continuation: continuation, command: "/nonexistent-op-xyz",
                arguments: [], environment: [:], timeoutSeconds: 5
            )
        }
        #expect(outcome.ok == false)
        #expect(outcome.cliMissing)
        #expect(outcome.timedOut == false)
        box.noteTerminated(status: 0)
        box.noteTimeout()
        box.cancel()
        box.appendOutput(Data("late".utf8))
    }

    @Test func zeroTimeout_resumesTimedOut() async {
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        let outcome = await withCheckedContinuation { (
            continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
        ) in
            box.begin(
                continuation: continuation, command: "/bin/echo",
                arguments: [], environment: [:], timeoutSeconds: 0
            )
        }
        #expect(outcome.ok == false)
        #expect(outcome.timedOut)
    }

    @Test func cancelBeforeBegin_resumesCancelledWithoutSpawning() async {
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        box.cancel()
        // Before the fix this hung: the early finish took no
        // continuation, and the late begin spawned a child nobody
        // resumed for.
        let outcome = await withCheckedContinuation { (
            continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
        ) in
            box.begin(
                continuation: continuation, command: "/bin/echo",
                arguments: ["hello"], environment: [:], timeoutSeconds: 5
            )
        }
        #expect(outcome.ok == false)
        #expect(outcome.timedOut == false)
        #expect(outcome.oversized == false)
        #expect(outcome.cliMissing == false)
    }

    @Test func armOrAbandon_finishedBox_abandonsWithoutArming() async {
        weak var weakBox: OnePasswordSpawnBox?
        do {
            let box = OnePasswordSpawnBox(maximumBytes: 1024)
            weakBox = box
            let outcome = await withCheckedContinuation { (
                continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
            ) in
                box.begin(
                    continuation: continuation, command: "/nonexistent-op-xyz",
                    arguments: [], environment: [:], timeoutSeconds: 5
                )
            }
            #expect(outcome.cliMissing)
            // No child was ever tracked, so nothing to terminate — and no
            // stray kill may be armed: a 3600s task would retain the box.
            #expect(box.armOrAbandon(limit: 3600) == nil)
        }
        #expect(weakBox == nil)
    }

    @Test func cancelBetweenTrackAndLaunch_resumesCancelledAndReapsChild() async throws {
        // The launch gate holds `begin` after the child is tracked but
        // before it launches, so the cancel below lands deterministically
        // inside the window. Before the fix this aborted the host:
        // `terminate` on the tracked-but-unlaunched task raises
        // `NSInvalidArgumentException` (`[NSConcreteTask terminate]: task
        // not launched`). The hanging fake keeps the reaped child
        // observable: a leaked child would still be alive below.
        let fake = try makeFakeOp()
        try fake.write("hang", "")
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        let gated = Mutex(false)
        let release = Mutex(false)
        box.launchGate = {
            gated.withLock { $0 = true }
            while release.withLock({ $0 }) == false {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let task = Task {
            await withCheckedContinuation { (
                continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
            ) in
                box.begin(
                    continuation: continuation, command: fake.opPath,
                    arguments: ["read", "op://v/i/f"], environment: testEnvironment(fake),
                    timeoutSeconds: 30
                )
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while gated.withLock({ $0 }) == false && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(gated.withLock { $0 })
        box.cancel()
        release.withLock { $0 = true }
        let outcome = await task.value
        #expect(outcome.ok == false)
        #expect(outcome.timedOut == false)
        #expect(outcome.oversized == false)
        #expect(outcome.cliMissing == false)
        // The outcome resumed at cancel time, before the gated launch ran,
        // so await the parent-side launch record: the reaped child may die
        // before first scheduling, so its own pids.log may stay empty while
        // `launchedChildPID` still proves the launch happened. The hanging
        // fake keeps a leaked child alive, so the death check below fails
        // when the reap is broken.
        var launched: Int32?
        let launchDeadline = Date().addingTimeInterval(30)
        while launched == nil && Date() < launchDeadline {
            launched = box.launchedChildPID
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try #require(launched)
        await expectDead([pid])
    }

    @Test func reapUntrackedLaunch_pendingBox_keepsChild() async throws {
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = FileHandle.nullDevice
        try child.run()
        box.reapUntrackedLaunch(child)
        #expect(child.isRunning)
        child.terminate()
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(child.isRunning == false)
    }

    @Test func reapUntrackedLaunch_finishedBox_terminatesChild() async throws {
        let box = OnePasswordSpawnBox(maximumBytes: 1024)
        box.cancel()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = FileHandle.nullDevice
        try child.run()
        box.reapUntrackedLaunch(child)
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(child.isRunning == false)
    }

    @Test func armOrAbandon_pendingBox_armsKillThenReleases() async throws {
        weak var weakBox: OnePasswordSpawnBox?
        do {
            let box = OnePasswordSpawnBox(maximumBytes: 1024)
            weakBox = box
            #expect(box.armOrAbandon(limit: 0.05) == nil)
        }
        // The armed kill retains the box mid-flight, then releases it
        // when it fires (without a continuation waiting: no resume, no
        // crash). Poll, don't sleep-then-assert: under full-target
        // parallel load the 50ms kill can fire seconds late.
        #expect(weakBox != nil)
        let deadline = Date().addingTimeInterval(30)
        while weakBox != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(weakBox == nil)
    }
}

