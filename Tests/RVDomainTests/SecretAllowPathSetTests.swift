import Testing
import RVDomain

struct SecretAllowPathSetTests {
    @Test func relativeLiteral_coversAbsoluteSuffix() throws {
        let set = SecretAllowPathSet(literals: [".env"])
        let rule = SecretPathCatalog.dayOne.firstMatch(of: "/tmp/rv-oracle/.env")
        let hit = try #require(rule)
        #expect(set.exempts("/tmp/rv-oracle/.env", rule: hit))
        #expect(set.exempts(".env", rule: hit))
    }

    @Test func directoryLiteral_coversChildren() throws {
        let set = SecretAllowPathSet(literals: ["/tmp/proj"])
        let rule = try #require(SecretPathCatalog.dayOne.firstMatch(of: "/tmp/proj/.env"))
        #expect(set.exempts("/tmp/proj/.env", rule: rule))
    }

    @Test func hostAuth_neverExempt() throws {
        let set = SecretAllowPathSet(literals: ["~/.claude/.credentials.json"])
        let rule = try #require(
            SecretPathCatalog.dayOne.firstMatch(of: "~/.claude/.credentials.json")
        )
        #expect(rule.category == .host)
        #expect(set.exempts("~/.claude/.credentials.json", rule: rule) == false)
        #expect(
            set.exempts(
                "/Users/ada/.claude/.credentials.json",
                rule: rule,
                home: "/Users/ada"
            ) == false
        )
    }

    @Test func homeExpansion_matchesTilde() throws {
        let set = SecretAllowPathSet(literals: ["~/.env"])
        let rule = try #require(SecretPathCatalog.dayOne.firstMatch(of: "/Users/ada/.env"))
        #expect(set.exempts("/Users/ada/.env", rule: rule, home: "/Users/ada"))
    }
}
