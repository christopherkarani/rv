import Testing
@testable import RVDomain

/// Default APFS is case-insensitive: `~/.SSH/authorized_keys` opens
/// `~/.ssh/authorized_keys`, so path rules must match case variants there.
@Suite("Path case folding")
struct PathCaseFoldingTests {
    #if canImport(Darwin)
    @Test("secret catalog matches case variants on Darwin", arguments: [
        "~/.SSH/authorized_keys",
        "~/.Ssh/id_ed25519",
        "/Users/me/.SSH/config",
        "$HOME/.AWS/credentials",
        "repo/.ENV",
        "repo/.Env.local",
        "~/.CONFIG/RV/config.json",
        "/Users/me/Library/keychains/login.keychain-db",
        "~/.Claude/.credentials.json",
    ])
    func catalogFoldsCase(path: String) {
        #expect(SecretPathCatalog.dayOne.firstMatch(of: path) != nil, "\(path)")
    }

    @Test("folded env-variant exemptions still exempt")
    func envExemptionsFold() {
        #expect(SecretPathCatalog.dayOne.firstMatch(of: "repo/.ENV.EXAMPLE") == nil)
    }

    #endif

    @Test("ordinary paths stay unmatched")
    func ordinaryPathsUnmatched() {
        #expect(SecretPathCatalog.dayOne.firstMatch(of: "~/src/app/main.swift") == nil)
        #expect(SecretPathCatalog.dayOne.firstMatch(of: "~/notes/ssh-tips.md") == nil)
    }
}
