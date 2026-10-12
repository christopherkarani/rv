import Foundation
import Testing
import RVDomain

@Suite("MCPConnection")
struct MCPConnectionTests {
    // MARK: - Record construction

    @Test func make_minimalRecordSucceeds() throws {
        let connection = try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default")
        #expect(connection.owner == .user)
        #expect(connection.name == "main")
        #expect(connection.integration == "github")
        #expect(connection.template == "oauth")
        #expect(connection.provider == "default")
        #expect(connection.identityLabel == nil)
        #expect(connection.description == nil)
        #expect(connection.expiresAt == nil)
        #expect(connection.oauthClient == nil)
        #expect(connection.oauthClientOwner == nil)
        #expect(connection.oauthScope == nil)
        #expect(connection.missingOAuthScopes == [])
        #expect(connection.lastHealth == nil)
    }

    @Test func make_fullRecordRoundTrips() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let health = try MCPConnectionHealth(status: .healthy, httpStatus: 200, identity: "octocat", checkedAt: checkedAt, detail: "probe ok", reason: nil)
        let connection = try MCPConnection(
            owner: .org,
            name: "_crm$1",
            integration: "salesforce",
            template: "apiKey",
            provider: "keychain",
            identityLabel: "staging CRM",
            description: "Reads only. Owner: data team.",
            expiresAt: expiresAt,
            oauthClient: "first-party-crm",
            oauthClientOwner: .org,
            oauthScope: "read write",
            missingOAuthScopes: ["admin"],
            lastHealth: health
        )
        #expect(connection.owner == .org)
        #expect(connection.name == "_crm$1")
        #expect(connection.integration == "salesforce")
        #expect(connection.template == "apiKey")
        #expect(connection.provider == "keychain")
        #expect(connection.identityLabel == "staging CRM")
        #expect(connection.description == "Reads only. Owner: data team.")
        #expect(connection.expiresAt == expiresAt)
        #expect(connection.oauthClient == "first-party-crm")
        #expect(connection.oauthClientOwner == .org)
        #expect(connection.oauthScope == "read write")
        #expect(connection.missingOAuthScopes == ["admin"])
        #expect(connection.lastHealth == health)
    }

    @Test func addressLiteral_format() throws {
        let connection = try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default")
        #expect(connection.addressLiteral == "tools.github.org.main")
    }

    @Test func toolAddress_buildsParseableAddress() throws {
        let connection = try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default")
        let address = try connection.toolAddress(forTool: "repos.list")
        #expect(address.literal == "tools.github.user.main.repos.list")
        #expect(try MCPToolAddress.parse(address.literal) == address)
    }

    // MARK: - Record validation

    @Test func name_acceptsIdentifierCharset() throws {
        for name in ["a", "Z", "_", "$", "main", "_crm$1", "a0_$", "aB1", String(repeating: "n", count: MCPConnection.maxNameBytes)] {
            let connection = try MCPConnection(owner: .user, name: name, integration: "i", template: "t", provider: "p")
            #expect(connection.name == name)
        }
    }

    @Test func name_rejectsEmptyTooLongAndBadChars() {
        #expect(throws: MCPConnectionError.emptyField(.name)) {
            try MCPConnection(owner: .user, name: "", integration: "i", template: "t", provider: "p")
        }
        #expect(throws: MCPConnectionError.tooLong(field: .name, maxBytes: MCPConnection.maxNameBytes)) {
            try MCPConnection(owner: .user, name: String(repeating: "n", count: MCPConnection.maxNameBytes + 1), integration: "i", template: "t", provider: "p")
        }
        for bad in ["0abc", "has.dot", "has space", "has-dash", "ünicode", "tab\there", "line\nbreak", "ａbc", "a\u{0301}b", "a🙂b"] {
            #expect(throws: MCPConnectionError.invalidCharacters(field: .name)) {
                try MCPConnection(owner: .user, name: bad, integration: "i", template: "t", provider: "p")
            }
        }
    }

    @Test func slugs_rejectEmptyTooLongAndBadStarts() throws {
        // Happy paths hit every charset label: digit/upper/lower starts and
        // digit/letter/underscore/dash rests. Dots are rejected everywhere:
        // slugs feed address literals, where dots are segment boundaries.
        let connection = try MCPConnection(owner: .user, name: "n", integration: "9aBc_-x", template: "T", provider: "P0")
        #expect(connection.integration == "9aBc_-x")
        #expect(connection.template == "T")
        #expect(throws: MCPConnectionError.emptyField(.integration)) {
            try MCPConnection(owner: .user, name: "n", integration: "", template: "t", provider: "p")
        }
        #expect(throws: MCPConnectionError.emptyField(.template)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "", provider: "p")
        }
        #expect(throws: MCPConnectionError.emptyField(.provider)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "")
        }
        #expect(throws: MCPConnectionError.tooLong(field: .integration, maxBytes: MCPConnection.maxSlugBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: String(repeating: "i", count: MCPConnection.maxSlugBytes + 1), template: "t", provider: "p")
        }
        for bad in [".lead", "-lead", "_lead", "$lead", "has space", "has/slash", "tab\there", "has.dot", "trailing."] {
            #expect(throws: MCPConnectionError.invalidCharacters(field: .integration)) {
                try MCPConnection(owner: .user, name: "n", integration: bad, template: "t", provider: "p")
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .template)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: bad, provider: "p")
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .provider)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: bad)
            }
        }
    }

    @Test func labels_acceptSpacesAndUnicodeRejectControls() throws {
        let connection = try MCPConnection(
            owner: .user, name: "n", integration: "i", template: "t", provider: "p",
            identityLabel: "José's staging 123 🚀",
            description: "Reads only — owner: data team ✓"
        )
        #expect(connection.identityLabel == "José's staging 123 🚀")
        #expect(throws: MCPConnectionError.tooLong(field: .identityLabel, maxBytes: MCPConnection.maxLabelBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: String(repeating: "l", count: MCPConnection.maxLabelBytes + 1))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .description, maxBytes: MCPConnection.maxDescriptionBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", description: String(repeating: "d", count: MCPConnection.maxDescriptionBytes + 1))
        }
        for bad in ["bell\u{07}here", "line\nbreak", "tab\there", "zero\u{200B}width", "del\u{7F}ete", "line\u{2028}sep", "para\u{2029}sep"] {
            #expect(throws: MCPConnectionError.invalidCharacters(field: .identityLabel)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: bad)
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .description)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", description: bad)
            }
        }
    }

    @Test func oauthClient_validatesAsSlug() throws {
        let connection = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: "first-party-app_1-x")
        #expect(connection.oauthClient == "first-party-app_1-x")
        #expect(throws: MCPConnectionError.emptyField(.oauthClient)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: "")
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .oauthClient)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: "has space")
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .oauthClient)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: "has.dot")
        }
        #expect(throws: MCPConnectionError.tooLong(field: .oauthClient, maxBytes: MCPConnection.maxSlugBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: String(repeating: "c", count: MCPConnection.maxSlugBytes + 1))
        }
    }

    @Test func oauthScope_validatesWholeAndPerToken() throws {
        let connection = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: "read  write\t mail")
        #expect(connection.oauthScope == "read  write\t mail")
        let blank = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: "   ")
        #expect(blank.oauthScope == "   ")
        #expect(throws: MCPConnectionError.tooLong(field: .oauthScope, maxBytes: MCPConnection.maxOAuthScopeBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: String(repeating: "s", count: MCPConnection.maxOAuthScopeBytes + 1))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .oauthScope, maxBytes: MCPConnection.maxScopeTokenBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: "ok \(String(repeating: "s", count: MCPConnection.maxScopeTokenBytes + 1))")
        }
    }

    @Test func missingOAuthScopes_validatesEachToken() throws {
        let connection = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", missingOAuthScopes: ["admin", "https://graph.microsoft.com/Mail.Read"])
        #expect(connection.missingOAuthScopes.count == 2)
        #expect(throws: MCPConnectionError.emptyField(.missingOAuthScope)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", missingOAuthScopes: ["ok", ""])
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .missingOAuthScope)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", missingOAuthScopes: ["has space"])
        }
        #expect(throws: MCPConnectionError.tooLong(field: .missingOAuthScope, maxBytes: MCPConnection.maxScopeTokenBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", missingOAuthScopes: [String(repeating: "s", count: MCPConnection.maxScopeTokenBytes + 1)])
        }
    }

    @Test func record_codableRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let full = try MCPConnection(
            owner: .org, name: "main", integration: "github", template: "oauth", provider: "default",
            identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            oauthClient: "app", oauthClientOwner: .user, oauthScope: "a b", missingOAuthScopes: ["c"],
            lastHealth: try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "me", checkedAt: Date(timeIntervalSince1970: 1_700_000_000), detail: "blip", reason: .probeFailed)
        )
        #expect(try decoder.decode(MCPConnection.self, from: encoder.encode(full)) == full)
        let minimal = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p")
        #expect(try decoder.decode(MCPConnection.self, from: encoder.encode(minimal)) == minimal)
    }

    @Test func record_equalityCoversEveryField() throws {
        let base = try MCPConnection(
            owner: .org, name: "main", integration: "github", template: "oauth", provider: "default",
            identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10),
            oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"],
            lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5))
        )
        #expect(base == base)
        #expect(base != (try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "other", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "gitlab", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "apiKey", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "keychain", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "other", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "other", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 11), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "other", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .user, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "b", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["c"], lastHealth: try MCPConnectionHealth(status: .healthy, checkedAt: Date(timeIntervalSince1970: 5)))))
        #expect(base != (try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", identityLabel: "label", description: "desc", expiresAt: Date(timeIntervalSince1970: 10), oauthClient: "app", oauthClientOwner: .org, oauthScope: "a", missingOAuthScopes: ["b"], lastHealth: try MCPConnectionHealth(status: .expired, checkedAt: Date(timeIntervalSince1970: 5)))))
    }

    @Test func validationErrors_carryLabelsOnly() {
        #expect(MCPConnectionError.emptyField(.name) == MCPConnectionError.emptyField(.name))
        #expect(MCPConnectionError.emptyField(.name) != MCPConnectionError.emptyField(.provider))
        #expect(MCPConnectionError.emptyField(.name) != MCPConnectionError.invalidCharacters(field: .name))
        #expect(MCPConnectionError.emptyField(.name) != MCPConnectionError.tooLong(field: .name, maxBytes: 1))
        #expect(MCPConnectionError.tooLong(field: .name, maxBytes: 8) == MCPConnectionError.tooLong(field: .name, maxBytes: 8))
        #expect(MCPConnectionError.tooLong(field: .name, maxBytes: 8) != MCPConnectionError.tooLong(field: .name, maxBytes: 9))
        #expect(MCPConnectionError.tooLong(field: .name, maxBytes: 8) != MCPConnectionError.tooLong(field: .provider, maxBytes: 8))
        #expect(MCPConnectionError.tooLong(field: .name, maxBytes: 8) != MCPConnectionError.invalidCharacters(field: .name))
        #expect(MCPConnectionError.invalidCharacters(field: .variable) == MCPConnectionError.invalidCharacters(field: .variable))
        #expect(MCPConnectionError.invalidCharacters(field: .variable) != MCPConnectionError.invalidCharacters(field: .externalID))
    }

    @Test func noAuthTemplate_sentinelValue() {
        #expect(MCPConnection.noAuthTemplate == "none")
    }

    @Test func address_everyValidRecordRoundTrips() throws {
        let records = try [
            MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default"),
            MCPConnection(owner: .org, name: "_crm$1", integration: "9aBc_-x", template: "T", provider: "P0"),
            MCPConnection(owner: .org, name: "a", integration: "i", template: "none", provider: "file"),
        ]
        for record in records {
            let address = try record.toolAddress(forTool: "repos.list")
            #expect(address.literal == "\(record.addressLiteral).repos.list")
            #expect(try MCPToolAddress.parse(address.literal) == address)
            #expect(address.integration == record.integration)
            #expect(address.owner == record.owner.rawValue)
            #expect(address.connection == record.name)
        }
    }

    @Test func toolAddress_rejectsInvalidTools() throws {
        let record = try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default")
        #expect(throws: MCPToolAddressError.emptySegment) {
            try record.toolAddress(forTool: "")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try record.toolAddress(forTool: "has space")
        }
    }

    @Test func caps_exactBoundariesPass() throws {
        let slug128 = String(repeating: "s", count: MCPConnection.maxSlugBytes)
        let record = try MCPConnection(
            owner: .user, name: String(repeating: "n", count: MCPConnection.maxNameBytes),
            integration: slug128, template: slug128, provider: slug128,
            identityLabel: String(repeating: "l", count: MCPConnection.maxLabelBytes),
            description: String(repeating: "d", count: MCPConnection.maxDescriptionBytes),
            oauthClient: slug128
        )
        #expect(record.name.count == MCPConnection.maxNameBytes)
        let token512 = String(repeating: "t", count: MCPConnection.maxScopeTokenBytes)
        let whole4096 = (Array(repeating: String(repeating: "t", count: 511), count: 7) + [token512]).joined(separator: " ")
        #expect(whole4096.utf8.count == MCPConnection.maxOAuthScopeBytes)
        let scoped = try MCPConnection(
            owner: .user, name: "n", integration: "i", template: "t", provider: "p",
            oauthScope: whole4096, missingOAuthScopes: [token512]
        )
        #expect(scoped.oauthScope == whole4096)
        #expect(try ConnectionExternalRef(provider: "keychain", id: String(repeating: "i", count: MCPConnection.maxExternalIDBytes)).id.count == MCPConnection.maxExternalIDBytes)
        #expect(try normalizeConnectionInput(.values([String(repeating: "v", count: MCPConnection.maxVariableBytes): "1"])).count == 1)
        let health = try MCPConnectionHealth(
            status: .healthy,
            identity: String(repeating: "i", count: MCPConnection.maxHealthIdentityBytes),
            checkedAt: Date(timeIntervalSince1970: 1),
            detail: String(repeating: "d", count: MCPConnection.maxHealthDetailBytes)
        )
        #expect(health.identity?.count == MCPConnection.maxHealthIdentityBytes)
    }

    @Test func caps_countBytesNotCharacters() throws {
        // "é" is 2 UTF-8 bytes: 128 of them exactly fill the 256-byte label cap.
        let labelExact = String(repeating: "é", count: MCPConnection.maxLabelBytes / 2)
        #expect(labelExact.utf8.count == MCPConnection.maxLabelBytes)
        #expect(try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: labelExact).identityLabel == labelExact)
        #expect(throws: MCPConnectionError.tooLong(field: .identityLabel, maxBytes: MCPConnection.maxLabelBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: String(repeating: "é", count: MCPConnection.maxLabelBytes / 2 + 1))
        }
        let descExact = String(repeating: "é", count: MCPConnection.maxDescriptionBytes / 2)
        #expect(try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", description: descExact).description == descExact)
        #expect(throws: MCPConnectionError.tooLong(field: .description, maxBytes: MCPConnection.maxDescriptionBytes)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", description: String(repeating: "é", count: MCPConnection.maxDescriptionBytes / 2 + 1))
        }
    }

    @Test func labels_acceptEmptyStrings() throws {
        let record = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: "", description: "")
        #expect(record.identityLabel == "")
        #expect(record.description == "")
        // Unknown scope is spelled nil, never "": an empty echo is rejected.
        #expect(throws: MCPConnectionError.emptyField(.oauthScope)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: "")
        }
        #expect(grantedScopes(fromOAuthScope: nil) == nil)
    }

    @Test func oauthScope_acceptsNewlineSeparators() throws {
        // Whitespace only separates tokens; the parser and the validator split
        // identically, so a stored newline-separated scope resolves the same.
        let record = try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthScope: "read\nwrite")
        #expect(grantedScopes(fromOAuthScope: record.oauthScope) == ["read", "write"])
    }

    @Test func isConnectionIdentifier_matchesValidation() {
        for good in ["a", "Z", "_", "$", "main", "_crm$1", "a0_$"] {
            #expect(isConnectionIdentifier(good) == true)
        }
        for bad in ["", "0abc", "has space", "has.dot", "has-dash", "ünicode", "ａbc"] {
            #expect(isConnectionIdentifier(bad) == false)
        }
    }

    @Test func normalizeConnectionName_oracleCases() {
        #expect(normalizeConnectionName("my-api-key") == "myApiKey")
        #expect(normalizeConnectionName("my api key") == "myApiKey")
        #expect(normalizeConnectionName("main") == "main")
        #expect(normalizeConnectionName("a") == "a")
        #expect(normalizeConnectionName("alreadyCamel42") == "alreadyCamel42")
        #expect(normalizeConnectionName("") == "connection")
        #expect(normalizeConnectionName("123") == "connection123")
        #expect(normalizeConnectionName("9lives") == "connection9lives")
        #expect(normalizeConnectionName("$foo") == "foo")
        #expect(normalizeConnectionName("_private") == "private")
        #expect(normalizeConnectionName("A") == "a")
        #expect(normalizeConnectionName("OAuth Token!") == "oauthToken")
        #expect(normalizeConnectionName("a-b_c.d") == "aBCD")
        #expect(normalizeConnectionName("Café Müßig") == "cafMIg")
        #expect(normalizeConnectionName("", fallback: "conn") == "conn")
        #expect(normalizeConnectionName("123", fallback: "c") == "c123")
        #expect(normalizeConnectionName("", fallback: "") == "")
    }

    @Test func normalizeConnectionName_idempotentAndValid() throws {
        let battery = ["my-api-key", "my api key", "main", "", "123", "$foo", "A", "OAuth Token!", "Café Müßig", "_private", "9lives", "a-b_c.d", "alreadyCamel42"]
        for raw in battery {
            let once = normalizeConnectionName(raw)
            #expect(normalizeConnectionName(once) == once)
            #expect(isConnectionIdentifier(once) == true)
            #expect(try MCPConnection(owner: .user, name: once, integration: "i", template: "t", provider: "p").name == once)
        }
        let long = String(repeating: "a", count: MCPConnection.maxNameBytes + 72)
        #expect(normalizeConnectionName(long) == long)
        #expect(throws: MCPConnectionError.tooLong(field: .name, maxBytes: MCPConnection.maxNameBytes)) {
            try MCPConnection(owner: .user, name: normalizeConnectionName(long), integration: "i", template: "t", provider: "p")
        }
    }

    @Test func decode_revalidatesAndDefaults() throws {
        let decoder = JSONDecoder()
        let minimal = try decoder.decode(MCPConnection.self, from: Data(#"{"owner":"org","name":"main","integration":"github","template":"oauth","provider":"default"}"#.utf8))
        #expect(minimal.owner == .org)
        #expect(minimal.identityLabel == nil)
        #expect(minimal.missingOAuthScopes == [])
        #expect(minimal.lastHealth == nil)
        let nulled = try decoder.decode(MCPConnection.self, from: Data(#"{"owner":"org","name":"main","integration":"github","template":"oauth","provider":"default","missingOAuthScopes":null}"#.utf8))
        #expect(nulled.missingOAuthScopes == [])
        #expect(throws: MCPConnectionError.invalidCharacters(field: .name)) {
            try decoder.decode(MCPConnection.self, from: Data(#"{"owner":"org","name":"has space","integration":"github","template":"oauth","provider":"default"}"#.utf8))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .integration, maxBytes: MCPConnection.maxSlugBytes)) {
            try decoder.decode(MCPConnection.self, from: Data(#"{"owner":"org","name":"main","integration":"\#(String(repeating: "i", count: MCPConnection.maxSlugBytes + 1))","template":"oauth","provider":"default"}"#.utf8))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .identityLabel)) {
            try decoder.decode(MCPConnection.self, from: Data(#"{"owner":"org","name":"main","integration":"github","template":"oauth","provider":"default","identityLabel":"bad\u0007"}"#.utf8))
        }
    }

    @Test func health_decodeRevalidates() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let minimal = try decoder.decode(MCPConnectionHealth.self, from: Data(#"{"status":"unknown","checkedAt":1700000000000}"#.utf8))
        #expect(minimal.status == .unknown)
        #expect(minimal.identity == nil)
        #expect(throws: MCPConnectionError.invalidCharacters(field: .healthIdentity)) {
            try decoder.decode(MCPConnectionHealth.self, from: Data(#"{"status":"healthy","checkedAt":1700000000000,"identity":"bad\u0007"}"#.utf8))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .healthDetail, maxBytes: MCPConnection.maxHealthDetailBytes)) {
            try decoder.decode(MCPConnectionHealth.self, from: Data(#"{"status":"degraded","checkedAt":1700000000000,"detail":"\#(String(repeating: "d", count: MCPConnection.maxHealthDetailBytes + 1))"}"#.utf8))
        }
    }

    // MARK: - Origins + normalization

    @Test func normalize_valueSugarTargetsToken() throws {
        let normalized = try normalizeConnectionInput(.value("sekret"))
        #expect(normalized == [NamedConnectionInput(variable: "token", origin: .value("sekret"))])
        #expect(ConnectionValueInput.primaryVariable == "token")
    }

    @Test func normalize_fromSugarValidatesReference() throws {
        let normalized = try normalizeConnectionInput(.from(provider: "keychain", id: "opaque-1"))
        #expect(normalized == [NamedConnectionInput(variable: "token", origin: .from(provider: "keychain", id: "opaque-1"))])
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalProvider)) {
            try normalizeConnectionInput(.from(provider: "has space", id: "x"))
        }
        #expect(throws: MCPConnectionError.emptyField(.externalProvider)) {
            try normalizeConnectionInput(.from(provider: "", id: "x"))
        }
        #expect(throws: MCPConnectionError.emptyField(.externalID)) {
            try normalizeConnectionInput(.from(provider: "keychain", id: ""))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalID)) {
            try normalizeConnectionInput(.from(provider: "keychain", id: "bad\u{07}id"))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .externalID, maxBytes: MCPConnection.maxExternalIDBytes)) {
            try normalizeConnectionInput(.from(provider: "keychain", id: String(repeating: "i", count: MCPConnection.maxExternalIDBytes + 1)))
        }
    }

    @Test func normalize_valuesMapSortsAndValidatesVariables() throws {
        let normalized = try normalizeConnectionInput(.values(["zeta": "1", "alpha": "2"]))
        #expect(normalized.map(\.variable) == ["alpha", "zeta"])
        #expect(normalized[0].origin == .value("2"))
        #expect(try normalizeConnectionInput(.values([:])) == [])
        #expect(throws: MCPConnectionError.invalidCharacters(field: .variable)) {
            try normalizeConnectionInput(.values(["has space": "1"]))
        }
        #expect(throws: MCPConnectionError.emptyField(.variable)) {
            try normalizeConnectionInput(.values(["": "1"]))
        }
        #expect(throws: MCPConnectionError.tooLong(field: .variable, maxBytes: MCPConnection.maxVariableBytes)) {
            try normalizeConnectionInput(.values([String(repeating: "v", count: MCPConnection.maxVariableBytes + 1): "1"]))
        }
    }

    @Test func normalize_inputsMapPreservesMixedOriginsSorted() throws {
        let normalized = try normalizeConnectionInput(.inputs([
            "b": .value("pasted"),
            "a": .from(provider: "keychain", id: "x"),
        ]))
        #expect(normalized.map(\.variable) == ["a", "b"])
        #expect(normalized[0].origin == .from(provider: "keychain", id: "x"))
        #expect(normalized[1].origin == .value("pasted"))
        #expect(try normalizeConnectionInput(.inputs([:])) == [])
        #expect(throws: MCPConnectionError.invalidCharacters(field: .variable)) {
            try normalizeConnectionInput(.inputs(["0bad": .value("1")]))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalProvider)) {
            try normalizeConnectionInput(.inputs(["ok": .from(provider: "bad provider", id: "x")]))
        }
    }

    @Test func origins_equalityMatrix() {
        let values: [ConnectionInputOrigin] = [.value("a"), .from(provider: "p", id: "i")]
        for (index, lhs) in values.enumerated() {
            for (other, rhs) in values.enumerated() {
                #expect((lhs == rhs) == (index == other))
            }
        }
        #expect(ConnectionInputOrigin.value("a") == ConnectionInputOrigin.value("a"))
        #expect(ConnectionInputOrigin.value("a") != ConnectionInputOrigin.value("b"))
        #expect(ConnectionInputOrigin.from(provider: "p", id: "i") == ConnectionInputOrigin.from(provider: "p", id: "i"))
        #expect(ConnectionInputOrigin.from(provider: "p", id: "i") != ConnectionInputOrigin.from(provider: "q", id: "i"))
        #expect(ConnectionInputOrigin.from(provider: "p", id: "i") != ConnectionInputOrigin.from(provider: "p", id: "j"))
        #expect(ConnectionInputOrigin.value("a") != ConnectionInputOrigin.from(provider: "p", id: "i"))
        let inputs: [ConnectionValueInput] = [.value("a"), .from(provider: "p", id: "i"), .values(["k": "v"]), .inputs(["k": .value("v")])]
        for (index, lhs) in inputs.enumerated() {
            for (other, rhs) in inputs.enumerated() {
                #expect((lhs == rhs) == (index == other))
            }
        }
        #expect(ConnectionValueInput.value("a") != ConnectionValueInput.value("b"))
        #expect(ConnectionValueInput.from(provider: "p", id: "i") != ConnectionValueInput.from(provider: "p", id: "j"))
        #expect(ConnectionValueInput.values(["k": "v"]) != ConnectionValueInput.values(["k": "w"]))
        #expect(ConnectionValueInput.inputs(["k": .value("v")]) != ConnectionValueInput.inputs(["k": .value("w")]))
        #expect(NamedConnectionInput(variable: "a", origin: .value("1")) == NamedConnectionInput(variable: "a", origin: .value("1")))
        #expect(NamedConnectionInput(variable: "a", origin: .value("1")) != NamedConnectionInput(variable: "b", origin: .value("1")))
        #expect(NamedConnectionInput(variable: "a", origin: .value("1")) != NamedConnectionInput(variable: "a", origin: .value("2")))
    }

    // MARK: - Routing (single-provider rule)

    @Test func route_noAuthAcceptsOnlyEmptyPlaceholders() throws {
        #expect(try routeConnectionInputs([], isNoAuthTemplate: true) == ConnectionInputRouting(provider: nil, variables: []))
        let placeholders = try normalizeConnectionInput(.values(["token": "", "extra": ""]))
        #expect(try routeConnectionInputs(placeholders, isNoAuthTemplate: true) == ConnectionInputRouting(provider: nil, variables: []))
        let live = try normalizeConnectionInput(.value("sekret"))
        #expect(throws: ConnectionInputsError.inputsOnNoAuthTemplate) {
            try routeConnectionInputs(live, isNoAuthTemplate: true)
        }
        let external = try normalizeConnectionInput(.from(provider: "keychain", id: "x"))
        #expect(throws: ConnectionInputsError.inputsOnNoAuthTemplate) {
            try routeConnectionInputs(external, isNoAuthTemplate: true)
        }
    }

    @Test func route_credentialedRequiresOneProvider() throws {
        #expect(throws: ConnectionInputsError.noCredentialInputs) {
            try routeConnectionInputs([], isNoAuthTemplate: false)
        }
        let pasted = try normalizeConnectionInput(.values(["b": "1", "a": "2"]))
        #expect(try routeConnectionInputs(pasted, isNoAuthTemplate: false) == ConnectionInputRouting(provider: nil, variables: ["a", "b"]))
        let external = try normalizeConnectionInput(.inputs(["b": .from(provider: "keychain", id: "y"), "a": .from(provider: "keychain", id: "x")]))
        #expect(try routeConnectionInputs(external, isNoAuthTemplate: false) == ConnectionInputRouting(provider: "keychain", variables: ["a", "b"]))
        let mixed = try normalizeConnectionInput(.inputs(["a": .value("1"), "b": .from(provider: "keychain", id: "x")]))
        #expect(throws: ConnectionInputsError.mixedOrigins) {
            try routeConnectionInputs(mixed, isNoAuthTemplate: false)
        }
        let split = try normalizeConnectionInput(.inputs(["a": .from(provider: "keychain", id: "x"), "b": .from(provider: "vault-http", id: "y")]))
        #expect(throws: ConnectionInputsError.multipleProviders) {
            try routeConnectionInputs(split, isNoAuthTemplate: false)
        }
    }

    @Test func inputsErrors_equalityMatrix() {
        let cases: [ConnectionInputsError] = [.noCredentialInputs, .inputsOnNoAuthTemplate, .mixedOrigins, .multipleProviders]
        for (index, lhs) in cases.enumerated() {
            for (other, rhs) in cases.enumerated() {
                #expect((lhs == rhs) == (index == other))
            }
        }
        #expect(ConnectionInputRouting(provider: "p", variables: ["a"]) == ConnectionInputRouting(provider: "p", variables: ["a"]))
        #expect(ConnectionInputRouting(provider: "p", variables: ["a"]) != ConnectionInputRouting(provider: "q", variables: ["a"]))
        #expect(ConnectionInputRouting(provider: "p", variables: ["a"]) != ConnectionInputRouting(provider: "p", variables: ["b"]))
        #expect(ConnectionInputRouting(provider: "p", variables: ["a"]) != ConnectionInputRouting(provider: nil, variables: ["a"]))
    }

    @Test func inputsErrors_messagesAreCallerSafe() {
        #expect(ConnectionInputsError.noCredentialInputs.message == "A connection must supply at least one credential input.")
        #expect(ConnectionInputsError.inputsOnNoAuthTemplate.message == "A no-auth connection cannot accept credential inputs.")
        #expect(ConnectionInputsError.mixedOrigins.message == "A connection cannot mix pasted and external-provider inputs.")
        #expect(ConnectionInputsError.multipleProviders.message == "A connection's inputs must all use the same external provider.")
    }

    @Test func route_allowsEmptyValueOnCredentialed() throws {
        // Executor `connections.test.ts`: "allows an empty-string value
        // (no-auth integrations bind one)". Emptiness only matters on no-auth.
        let empty = try normalizeConnectionInput(.value(""))
        #expect(try routeConnectionInputs(empty, isNoAuthTemplate: false) == ConnectionInputRouting(provider: nil, variables: ["token"]))
    }

    @Test func route_singleExternal() throws {
        let external = try normalizeConnectionInput(.from(provider: "keychain", id: "x"))
        #expect(try routeConnectionInputs(external, isNoAuthTemplate: false) == ConnectionInputRouting(provider: "keychain", variables: ["token"]))
    }

    @Test func route_noAuthRejectsPartialPlaceholders() throws {
        let partial = try normalizeConnectionInput(.values(["token": "", "extra": "live"]))
        #expect(throws: ConnectionInputsError.inputsOnNoAuthTemplate) {
            try routeConnectionInputs(partial, isNoAuthTemplate: true)
        }
        let mixed = try normalizeConnectionInput(.inputs(["a": .value(""), "b": .from(provider: "keychain", id: "x")]))
        #expect(throws: ConnectionInputsError.inputsOnNoAuthTemplate) {
            try routeConnectionInputs(mixed, isNoAuthTemplate: true)
        }
    }

    @Test func normalize_fromSugarRejectsDotsAndTooLongProviders() {
        #expect(throws: MCPConnectionError.tooLong(field: .externalProvider, maxBytes: MCPConnection.maxSlugBytes)) {
            try normalizeConnectionInput(.from(provider: String(repeating: "p", count: MCPConnection.maxSlugBytes + 1), id: "x"))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalProvider)) {
            try normalizeConnectionInput(.from(provider: "has.dot", id: "x"))
        }
    }

    // MARK: - Pure resolution

    @Test func resolve_mapsVariablesToValues() throws {
        let inputs = try normalizeConnectionInput(.values(["b": "two", "a": "one"]))
        let resolved = try resolveConnectionInputValues(inputs) { _ in .text("unused") }
        #expect(resolved["a"] == .text("one"))
        #expect(resolved["b"] == .text("two"))
        #expect(try resolveConnectionInputValues([]) { _ in nil } == [:])
    }

    @Test func resolve_preservesUnresolvableExternalsAsNil() throws {
        let inputs = try normalizeConnectionInput(.inputs([
            "missing": .from(provider: "keychain", id: "gone"),
            "found": .from(provider: "keychain", id: "here"),
        ]))
        let resolved = try resolveConnectionInputValues(inputs) { ref in
            ref.id == "here" ? .text("sekret") : nil
        }
        #expect(resolved.keys.contains("missing"))
        #expect(resolved.keys.contains("found"))
        let missing = try #require(resolved["missing"])
        #expect(missing == nil)
        #expect(resolved["found"] == .text("sekret"))
    }

    @Test func externalRef_bridgesToSecretRef() throws {
        let ref = try ConnectionExternalRef(provider: "keychain", id: "item-1")
        let secret = try ref.secretRef()
        #expect(secret.provider == "keychain")
        #expect(secret.item == "item-1")
        #expect(secret.field == nil)
        let foreign = try ConnectionExternalRef(provider: "1password", id: "x")
        #expect(throws: SecretsError.invalidRef("1password")) {
            try foreign.secretRef()
        }
        #expect(ref == (try ConnectionExternalRef(provider: "keychain", id: "item-1")))
        #expect(ref != (try ConnectionExternalRef(provider: "vault-http", id: "item-1")))
        #expect(ref != (try ConnectionExternalRef(provider: "keychain", id: "item-2")))
    }

    @Test func externalRef_allowedProvidersBattery() throws {
        for provider in ["file", "keychain", "vault-http", "env", "exec", "encrypted"] {
            let secret = try (try ConnectionExternalRef(provider: provider, id: "x")).secretRef()
            #expect(secret.provider == provider)
        }
        // The broker allowlist is case-sensitive, and the executor's
        // "default" key is not a broker provider (RV's default is "file").
        for provider in ["Keychain", "1password", "default"] {
            let foreign = try ConnectionExternalRef(provider: provider, id: "x")
            #expect(throws: SecretsError.invalidRef(provider)) {
                try foreign.secretRef()
            }
        }
    }

    @Test func resolve_rejectsHandBuiltVariables() {
        #expect(throws: MCPConnectionError.invalidCharacters(field: .variable)) {
            try resolveConnectionInputValues([NamedConnectionInput(variable: "has space", origin: .value("x"))]) { _ in nil }
        }
        #expect(throws: MCPConnectionError.emptyField(.variable)) {
            try resolveConnectionInputValues([NamedConnectionInput(variable: "", origin: .value("x"))]) { _ in nil }
        }
        #expect(throws: MCPConnectionError.tooLong(field: .variable, maxBytes: MCPConnection.maxVariableBytes)) {
            try resolveConnectionInputValues([NamedConnectionInput(variable: String(repeating: "v", count: MCPConnection.maxVariableBytes + 1), origin: .value("x"))]) { _ in nil }
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalID)) {
            try resolveConnectionInputValues([NamedConnectionInput(variable: "token", origin: .from(provider: "keychain", id: "bad\u{07}id"))]) { _ in nil }
        }
    }

    @Test func resolve_externalIDIsOpaque() throws {
        // Core never parses the id: slashes, spaces, and unicode all pass.
        let inputs = try normalizeConnectionInput(.inputs([
            "a": .from(provider: "keychain", id: "vault/item:1 with space"),
            "b": .from(provider: "keychain", id: "项目-1 ✓"),
        ]))
        let resolved = try resolveConnectionInputValues(inputs) { ref in
            #expect(ref.provider == "keychain")
            return .text("seen:\(ref.id)")
        }
        #expect(resolved["a"] == .text("seen:vault/item:1 with space"))
        #expect(resolved["b"] == .text("seen:项目-1 ✓"))
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalID)) {
            try normalizeConnectionInput(.from(provider: "keychain", id: "line\u{2028}sep"))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalID)) {
            try normalizeConnectionInput(.from(provider: "keychain", id: "para\u{2029}sep"))
        }
    }

    // MARK: - Invocation credential

    @Test func credential_valueIsAlwaysTokenValues() {
        let withToken = ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": .text("s"), "other": nil], config: ["k": "v"], grantedScopes: ["a"])
        #expect(withToken.value == .text("s"))
        let other = withToken.values["other"]
        #expect(other != nil)
        #expect(other! == nil)
        #expect(withToken.values.keys.contains("other"))
        #expect(withToken.config == ["k": "v"])
        #expect(withToken.grantedScopes == ["a"])
        let withoutToken = ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["other": .text("x")])
        #expect(withoutToken.value == nil)
        #expect(withoutToken.config == [:])
        #expect(withoutToken.grantedScopes == nil)
        let nilToken = ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": nil])
        #expect(nilToken.value == nil)
    }

    @Test func credential_equalityCoversEveryField() {
        let base = ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["a"])
        #expect(base == base)
        #expect(base != ToolInvocationCredential(owner: .user, integration: "i", connection: "c", template: "t", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "j", connection: "c", template: "t", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "i", connection: "d", template: "t", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "u", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": .text("x")], config: ["k": "v"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": .text("s")], config: ["k": "w"], grantedScopes: ["a"]))
        #expect(base != ToolInvocationCredential(owner: .org, integration: "i", connection: "c", template: "t", values: ["token": .text("s")], config: ["k": "v"], grantedScopes: ["b"]))
    }

    @Test func grantedScopes_parsesAndFailsOpen() {
        #expect(grantedScopes(fromOAuthScope: nil) == nil)
        #expect(grantedScopes(fromOAuthScope: "") == nil)
        #expect(grantedScopes(fromOAuthScope: "   ") == nil)
        #expect(grantedScopes(fromOAuthScope: "read write") == ["read", "write"])
        #expect(grantedScopes(fromOAuthScope: "  read\twrite\nmail  ") == ["read", "write", "mail"])
    }

    // MARK: - Failure taxonomy

    @Test func rfc6749_closedSetParsesExtensionsStayOpen() {
        #expect(OAuthTokenErrorCode(rawValue: "invalid_request") == .invalidRequest)
        #expect(OAuthTokenErrorCode(rawValue: "invalid_client") == .invalidClient)
        #expect(OAuthTokenErrorCode(rawValue: "invalid_grant") == .invalidGrant)
        #expect(OAuthTokenErrorCode(rawValue: "unauthorized_client") == .unauthorizedClient)
        #expect(OAuthTokenErrorCode(rawValue: "unsupported_grant_type") == .unsupportedGrantType)
        #expect(OAuthTokenErrorCode(rawValue: "invalid_scope") == .invalidScope)
        #expect(OAuthTokenErrorCode(rawValue: "invalid_target") == nil)
        #expect(OAuthTokenErrorCode(rawValue: "expired_token") == nil)
        #expect(OAuthTokenErrorCode.allCases.count == 6)
        let coded = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c", oauthErrorCode: "invalid_grant")
        #expect(coded.rfc6749Code == .invalidGrant)
        let extended = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c", oauthErrorCode: "invalid_target")
        #expect(extended.rfc6749Code == nil)
        #expect(extended.oauthErrorCode == "invalid_target")
        let uncoded = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c")
        #expect(uncoded.rfc6749Code == nil)
    }

    @Test func grantDead_onlyInvalidGrantProvesDead() {
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .invalidGrant) == true)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .invalidClient) == false)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .invalidScope) == false)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .invalidRequest) == false)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .unauthorizedClient) == false)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: .unsupportedGrantType) == false)
        #expect(MCPCredentialFailure.grantDeadForTokenError(code: nil) == false)
    }

    @Test func rfc6749_codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for code in OAuthTokenErrorCode.allCases {
            #expect(try decoder.decode(OAuthTokenErrorCode.self, from: encoder.encode(code)) == code)
        }
    }

    @Test func factories_buildLabelOnlyMessages() {
        let reauth = MCPCredentialFailure.reauthRequired(owner: .org, integration: "github", connection: "main", oauthErrorCode: "invalid_grant")
        #expect(reauth.reauthRequired == true)
        #expect(reauth.blockedByAdmin == false)
        #expect(reauth.credentialMissing == false)
        #expect(reauth.message == "Connection 'main' for integration 'github' needs re-authentication (authorization server code: invalid_grant).")
        let reauthBare = MCPCredentialFailure.reauthRequired(owner: .org, integration: "github", connection: "main")
        #expect(reauthBare.message == "Connection 'main' for integration 'github' needs re-authentication.")
        let missing = MCPCredentialFailure.credentialMissing(owner: .user, integration: "i", connection: "c")
        #expect(missing.credentialMissing == true)
        #expect(missing.reauthRequired == false)
        #expect(missing.message == "Connection 'c' for integration 'i' has no usable credential material.")
        let admin = MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c", oauthErrorCode: "access_denied")
        #expect(admin.blockedByAdmin == true)
        #expect(admin.reauthRequired == true)
        #expect(admin.message == "Connection 'c' for integration 'i' was declined by administrator policy; signing in again cannot help (authorization server code: access_denied).")
        let adminBare = MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c")
        #expect(adminBare.message == "Connection 'c' for integration 'i' was declined by administrator policy; signing in again cannot help.")
        let rejected = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c", oauthErrorCode: "invalid_client")
        #expect(rejected.reauthRequired == false)
        #expect(rejected.message == "The authorization server refused the stored credential for connection 'c' (integration 'i') (authorization server code: invalid_client).")
        let rejectedBare = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c")
        #expect(rejectedBare.message == "The authorization server refused the stored credential for connection 'c' (integration 'i').")
    }

    @Test func kind_precedenceIsAdminOverMissingOverReauth() {
        let all = MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, blockedByAdmin: true, credentialMissing: true)
        #expect(all.kind == .blockedByAdmin)
        let missingReauth = MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, credentialMissing: true)
        #expect(missingReauth.kind == .credentialMissing)
        let reauth = MCPCredentialFailure.reauthRequired(owner: .org, integration: "i", connection: "c")
        #expect(reauth.kind == .reauthRequired)
        let rejected = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c")
        #expect(rejected.kind == .refreshRejected)
        #expect(MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c").kind == .blockedByAdmin)
        #expect(MCPCredentialFailure.credentialMissing(owner: .org, integration: "i", connection: "c").kind == .credentialMissing)
        let blockedAlone = MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", blockedByAdmin: true)
        #expect(blockedAlone.kind == .blockedByAdmin)
        #expect(blockedAlone.healthReason == .blockedByAdmin)
    }

    @Test func healthReason_mapsKindToEnumerableReason() {
        #expect(MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c").healthReason == .blockedByAdmin)
        #expect(MCPCredentialFailure.credentialMissing(owner: .org, integration: "i", connection: "c").healthReason == .credentialMissing)
        #expect(MCPCredentialFailure.reauthRequired(owner: .org, integration: "i", connection: "c").healthReason == .credentialRefreshRejected)
        #expect(MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c").healthReason == .credentialRefreshRejected)
    }

    @Test func recovery_reconnectPromptsNeverRetryAdminNeverReconnects() {
        let reauth = MCPCredentialFailure.reauthRequired(owner: .org, integration: "github", connection: "main")
        guard case .reconnect(let reauthPrompt) = reauth.recovery else {
            Issue.record("reauth must recover via reconnect")
            return
        }
        #expect(reauthPrompt.contains("Reconnect 'main'"))
        #expect(reauthPrompt.lowercased().contains("retry") == false)
        let missing = MCPCredentialFailure.credentialMissing(owner: .org, integration: "i", connection: "c")
        guard case .reconnect(let missingPrompt) = missing.recovery else {
            Issue.record("missing must recover via reconnect")
            return
        }
        #expect(missingPrompt.contains("Reconnect 'c'"))
        #expect(missingPrompt.lowercased().contains("retry") == false)
        let rejected = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c")
        guard case .reconnect(let rejectedPrompt) = rejected.recovery else {
            Issue.record("refresh-rejected must recover via reconnect")
            return
        }
        #expect(rejectedPrompt.contains("Reconnect 'c'"))
        #expect(rejectedPrompt.lowercased().contains("retry") == false)
        let admin = MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c")
        guard case .contactAdmin(let adminPrompt) = admin.recovery else {
            Issue.record("admin-blocked must recover via contactAdmin")
            return
        }
        #expect(adminPrompt.contains("administrator"))
        #expect(adminPrompt.lowercased().contains("reconnect") == false)
        #expect(adminPrompt.lowercased().contains("retry") == false)
        #expect(adminPrompt.lowercased().contains("sign-in") || adminPrompt.lowercased().contains("sign in"))
    }

    @Test func retryable_onlyWriteIncompleteRetries() {
        #expect(MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c").retryable == false)
        #expect(MCPCredentialFailure.reauthRequired(owner: .org, integration: "i", connection: "c").retryable == false)
        #expect(OAuthScopeGap(integration: "i", connection: "c", operation: "op", missing: ["x"]).retryable == false)
        #expect(MCPCredentialWriteIncomplete(owner: .org, integration: "i", connection: "c").retryable == true)
        #expect(MCPCredentialWriteIncomplete(owner: .org, integration: "i", connection: "c").recovery == .retry)
    }

    @Test func providerNotRegistered_carriesLabelOnly() {
        let failure = MCPCredentialProviderNotRegistered(provider: "1password")
        #expect(failure.message == "Credential provider not registered: 1password")
        #expect(failure == MCPCredentialProviderNotRegistered(provider: "1password"))
        #expect(failure != MCPCredentialProviderNotRegistered(provider: "vault"))
    }

    @Test func writeIncomplete_messageNamesLabels() {
        let failure = MCPCredentialWriteIncomplete(owner: .org, integration: "github", connection: "main")
        #expect(failure.message == "Credential write for org/github/main is incomplete; retry the connection operation.")
        #expect(failure == MCPCredentialWriteIncomplete(owner: .org, integration: "github", connection: "main"))
        #expect(failure != MCPCredentialWriteIncomplete(owner: .user, integration: "github", connection: "main"))
        #expect(failure != MCPCredentialWriteIncomplete(owner: .org, integration: "gitlab", connection: "main"))
        #expect(failure != MCPCredentialWriteIncomplete(owner: .org, integration: "github", connection: "aux"))
    }

    @Test func failure_equalityCoversEveryField() {
        let base = MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false)
        #expect(base == base)
        #expect(base != MCPCredentialFailure(owner: .user, integration: "i", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "j", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "d", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "n", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: false, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_client", blockedByAdmin: false, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: true, credentialMissing: false))
        #expect(base != MCPCredentialFailure(owner: .org, integration: "i", connection: "c", message: "m", reauthRequired: true, oauthErrorCode: "invalid_grant", blockedByAdmin: false, credentialMissing: true))
    }

    @Test func recovery_equalityMatrix() {
        #expect(CredentialRecovery.retry == CredentialRecovery.retry)
        #expect(CredentialRecovery.reconnect(prompt: "a") == CredentialRecovery.reconnect(prompt: "a"))
        #expect(CredentialRecovery.reconnect(prompt: "a") != CredentialRecovery.reconnect(prompt: "b"))
        #expect(CredentialRecovery.contactAdmin(prompt: "a") == CredentialRecovery.contactAdmin(prompt: "a"))
        #expect(CredentialRecovery.contactAdmin(prompt: "a") != CredentialRecovery.contactAdmin(prompt: "b"))
        #expect(CredentialRecovery.reconnect(prompt: "a") != CredentialRecovery.contactAdmin(prompt: "a"))
        #expect(CredentialRecovery.reconnect(prompt: "a") != CredentialRecovery.retry)
        #expect(CredentialRecovery.contactAdmin(prompt: "a") != CredentialRecovery.retry)
        #expect(CredentialRecovery.retry != CredentialRecovery.reconnect(prompt: "a"))
    }

    // MARK: - Scope tracking

    @Test func canonical_foldsAliasesAndGraphPrefixes() {
        #expect(canonicalOAuthScope("https://www.googleapis.com/auth/userinfo.email") == "email")
        #expect(canonicalOAuthScope("https://www.googleapis.com/auth/userinfo.profile") == "profile")
        #expect(canonicalOAuthScope("https://graph.microsoft.com/Mail.ReadWrite") == "Mail.ReadWrite")
        #expect(canonicalOAuthScope("https://graph.microsoft.us/User.Read") == "User.Read")
        #expect(canonicalOAuthScope("https://graph.microsoft.de/Files.Read") == "Files.Read")
        #expect(canonicalOAuthScope("HTTPS://GRAPH.MICROSOFT.COM/Mail.Read") == "Mail.Read")
        #expect(canonicalOAuthScope("http://graph.microsoft.com/Mail.Read") == "Mail.Read")
        #expect(canonicalOAuthScope("https://graph.microsoft.com/v1.0/me/messages") == "messages")
        #expect(canonicalOAuthScope("Mail.Read") == "Mail.Read")
        #expect(canonicalOAuthScope("https://example.com/scopes/read") == "https://example.com/scopes/read")
        #expect(canonicalOAuthScope("https://graph.microsoft.evil.com/Mail.Read") == "https://graph.microsoft.evil.com/Mail.Read")
        #expect(canonicalOAuthScope("https://graph.microsoft.com") == "https://graph.microsoft.com")
        #expect(canonicalOAuthScope("https://graph.microsoft.com/") == "")
        #expect(canonicalOAuthScope("") == "")
    }

    @Test func missingGrantedScopes_diffsWithCanonicalSkips() {
        #expect(missingGrantedScopes(requested: ["read", "write"], granted: ["read"]) == ["write"])
        #expect(missingGrantedScopes(requested: ["read"], granted: ["read"]) == [])
        #expect(missingGrantedScopes(requested: [], granted: ["read"]) == [])
        #expect(missingGrantedScopes(requested: ["b", "a", "b"], granted: []) == ["b", "a"])
        #expect(missingGrantedScopes(requested: ["", "  ", "read"], granted: []) == ["read"])
        #expect(missingGrantedScopes(requested: ["  read  "], granted: ["read"]) == [])
        #expect(missingGrantedScopes(requested: ["https://graph.microsoft.com/.default", "read"], granted: []) == ["read"])
        #expect(missingGrantedScopes(requested: ["openid", "email", "profile", "offline_access", "read"], granted: []) == ["read"])
        #expect(missingGrantedScopes(requested: ["email"], granted: ["https://www.googleapis.com/auth/userinfo.email"]) == [])
        #expect(missingGrantedScopes(requested: ["https://www.googleapis.com/auth/userinfo.email"], granted: ["email"]) == [])
        #expect(missingGrantedScopes(requested: ["Mail.Read"], granted: ["https://graph.microsoft.com/Mail.Read"]) == [])
        #expect(missingGrantedScopes(requested: ["https://graph.microsoft.com/Mail.Read"], granted: ["Mail.Read"]) == [])
        #expect(missingGrantedScopes(requested: ["https://graph.microsoft.com/foo/"], granted: ["x"]) == [])
        #expect(missingGrantedScopes(requested: ["read"], granted: ["", "  "]) == ["read"])
    }

    @Test func missingGrantedScopes_caseAndMetaEdges() {
        // No case folding outside the meta/host checks: "Read" is not "read".
        #expect(missingGrantedScopes(requested: ["Read"], granted: ["read"]) == ["Read"])
        #expect(missingGrantedScopes(requested: ["read"], granted: ["Read"]) == ["read"])
        #expect(missingGrantedScopes(requested: ["https://graph.microsoft.com/.DEFAULT", "read"], granted: []) == ["read"])
        #expect(missingGrantedScopes(requested: ["https://www.googleapis.com/auth/userinfo.email", "read"], granted: []) == ["read"])
        #expect(missingGrantedScopes(requested: ["Mail.Read", "mail.read"], granted: ["Mail.Read"]) == ["mail.read"])
    }

    @Test func canonical_preservesCaseAndRejectsNonGraphHosts() {
        #expect(canonicalOAuthScope("https://graph.microsoft.com/mail.read") == "mail.read")
        #expect(canonicalOAuthScope("HTTP://graph.microsoft.com/X") == "X")
        #expect(canonicalOAuthScope("https://graph.microsoft.com:443/Mail.Read") == "https://graph.microsoft.com:443/Mail.Read")
        #expect(canonicalOAuthScope("https://graph.microsoft.com/Mail.Read?x=1") == "Mail.Read?x=1")
        #expect(canonicalOAuthScope("https://GRAPH.MICROSOFT.US/a/b") == "b")
    }

    @Test func evaluateScopeGap_failsOpenAndPromptsReconnect() throws {
        #expect(evaluateScopeGap(declared: ["read"], grantedScopes: nil, integration: "i", connection: "c", operation: "op") == nil)
        #expect(evaluateScopeGap(declared: ["read"], grantedScopes: ["read"], integration: "i", connection: "c", operation: "op") == nil)
        let gap = try #require(evaluateScopeGap(declared: ["read", "write"], grantedScopes: ["read"], integration: "github", connection: "main", operation: "repos.delete"))
        #expect(gap.missing == ["write"])
        #expect(gap.prompt.contains("repos.delete"))
        #expect(gap.prompt.contains("Reconnect 'main'"))
        #expect(gap.prompt.contains("1 required scope"))
        #expect(gap.prompt.contains("write") == false)
        #expect(gap.prompt.lowercased().contains("retry") == false)
    }

    @Test func scopeGap_equalityCoversEveryField() {
        let base = OAuthScopeGap(integration: "i", connection: "c", operation: "op", missing: ["a"])
        #expect(base == base)
        #expect(base != OAuthScopeGap(integration: "j", connection: "c", operation: "op", missing: ["a"]))
        #expect(base != OAuthScopeGap(integration: "i", connection: "d", operation: "op", missing: ["a"]))
        #expect(base != OAuthScopeGap(integration: "i", connection: "c", operation: "other", missing: ["a"]))
        #expect(base != OAuthScopeGap(integration: "i", connection: "c", operation: "op", missing: ["b"]))
    }

    @Test func scopeGap_promptNeverNamesScopes() {
        // Scope values can encode customer resource names: the prompt carries
        // the count only, however adversarial the value looks.
        let gap = OAuthScopeGap(integration: "i", connection: "c", operation: "op", missing: ["customer-secret-scope"])
        #expect(gap.missing == ["customer-secret-scope"])
        #expect(gap.prompt.contains("customer-secret-scope") == false)
        #expect(gap.prompt.contains("1 required scope"))
        let multi = OAuthScopeGap(integration: "i", connection: "c", operation: "op", missing: ["a", "b"])
        #expect(multi.prompt.contains("2 required scope"))
        #expect(evaluateScopeGap(declared: [], grantedScopes: ["read"], integration: "i", connection: "c", operation: "op") == nil)
    }

    // MARK: - Health

    @Test func health_validatesIdentityAndDetail() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let health = try MCPConnectionHealth(status: .expired, httpStatus: 401, identity: "octocat", checkedAt: checkedAt, detail: "token revoked", reason: .credentialRefreshRejected)
        #expect(health.status == .expired)
        #expect(health.httpStatus == 401)
        #expect(health.identity == "octocat")
        #expect(health.checkedAt == checkedAt)
        #expect(health.detail == "token revoked")
        #expect(health.reason == .credentialRefreshRejected)
        let minimal = try MCPConnectionHealth(status: .unknown, checkedAt: checkedAt)
        #expect(minimal.httpStatus == nil)
        #expect(minimal.identity == nil)
        #expect(minimal.detail == nil)
        #expect(minimal.reason == nil)
        #expect(throws: MCPConnectionError.tooLong(field: .healthIdentity, maxBytes: MCPConnection.maxHealthIdentityBytes)) {
            try MCPConnectionHealth(status: .healthy, identity: String(repeating: "i", count: MCPConnection.maxHealthIdentityBytes + 1), checkedAt: checkedAt)
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .healthIdentity)) {
            try MCPConnectionHealth(status: .healthy, identity: "bad\u{07}id", checkedAt: checkedAt)
        }
        #expect(throws: MCPConnectionError.tooLong(field: .healthDetail, maxBytes: MCPConnection.maxHealthDetailBytes)) {
            try MCPConnectionHealth(status: .degraded, checkedAt: checkedAt, detail: String(repeating: "d", count: MCPConnection.maxHealthDetailBytes + 1))
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .healthDetail)) {
            try MCPConnectionHealth(status: .degraded, checkedAt: checkedAt, detail: "bad\u{200B}detail")
        }
    }

    @Test func health_acceptsEmptyTextRejectsSeparators() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = try MCPConnectionHealth(status: .healthy, identity: "", checkedAt: checkedAt, detail: "")
        #expect(empty.identity == "")
        #expect(empty.detail == "")
        #expect(throws: MCPConnectionError.invalidCharacters(field: .healthIdentity)) {
            try MCPConnectionHealth(status: .healthy, identity: "line\u{2028}sep", checkedAt: checkedAt)
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .healthDetail)) {
            try MCPConnectionHealth(status: .degraded, checkedAt: checkedAt, detail: "para\u{2029}sep")
        }
    }

    @Test func health_vocabularyRawValues() {
        #expect(MCPConnectionHealthStatus.allCases.count == 5)
        #expect(MCPHealthCheckReason.allCases.count == 7)
        #expect(MCPConnectionHealthStatus.healthy.rawValue == "healthy")
        #expect(MCPConnectionHealthStatus.expired.rawValue == "expired")
        #expect(MCPConnectionHealthStatus.misconfigured.rawValue == "misconfigured")
        #expect(MCPConnectionHealthStatus.degraded.rawValue == "degraded")
        #expect(MCPConnectionHealthStatus.unknown.rawValue == "unknown")
        #expect(MCPHealthCheckReason.credentialMissing.rawValue == "credential_missing")
        #expect(MCPHealthCheckReason.credentialRefreshRejected.rawValue == "credential_refresh_rejected")
        #expect(MCPHealthCheckReason.blockedByAdmin.rawValue == "blocked_by_admin")
        #expect(MCPHealthCheckReason.probeTimeout.rawValue == "probe_timeout")
        #expect(MCPHealthCheckReason.probeFailed.rawValue == "probe_failed")
        #expect(MCPHealthCheckReason.upstreamStatus.rawValue == "upstream_status")
        #expect(MCPHealthCheckReason.toolSyncFailed.rawValue == "tool_sync_failed")
    }

    @Test func health_equalityAndCodable() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let base = try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "me", checkedAt: checkedAt, detail: "blip", reason: .probeFailed)
        #expect(base == base)
        #expect(base != (try MCPConnectionHealth(status: .healthy, httpStatus: 500, identity: "me", checkedAt: checkedAt, detail: "blip", reason: .probeFailed)))
        #expect(base != (try MCPConnectionHealth(status: .degraded, httpStatus: 502, identity: "me", checkedAt: checkedAt, detail: "blip", reason: .probeFailed)))
        #expect(base != (try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "you", checkedAt: checkedAt, detail: "blip", reason: .probeFailed)))
        #expect(base != (try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "me", checkedAt: Date(timeIntervalSince1970: 1), detail: "blip", reason: .probeFailed)))
        #expect(base != (try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "me", checkedAt: checkedAt, detail: "other", reason: .probeFailed)))
        #expect(base != (try MCPConnectionHealth(status: .degraded, httpStatus: 500, identity: "me", checkedAt: checkedAt, detail: "blip", reason: .probeTimeout)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        #expect(try decoder.decode(MCPConnectionHealth.self, from: encoder.encode(base)) == base)
        let minimal = try MCPConnectionHealth(status: .unknown, checkedAt: checkedAt)
        #expect(try decoder.decode(MCPConnectionHealth.self, from: encoder.encode(minimal)) == minimal)
    }

    // MARK: - Cross-shape integration

    @Test func recordToCredential_grantedScopesBridge() throws {
        let connection = try MCPConnection(owner: .org, name: "main", integration: "github", template: "oauth", provider: "default", oauthScope: "read write")
        let credential = ToolInvocationCredential(owner: connection.owner, integration: connection.integration, connection: connection.name, template: connection.template, values: ["token": .text("s")], grantedScopes: grantedScopes(fromOAuthScope: connection.oauthScope))
        #expect(credential.grantedScopes == ["read", "write"])
        #expect(credential.value == .text("s"))
        let staticConnection = try MCPConnection(owner: .org, name: "s", integration: "i", template: "apiKey", provider: "default")
        #expect(grantedScopes(fromOAuthScope: staticConnection.oauthScope) == nil)
        #expect(evaluateScopeGap(declared: ["read"], grantedScopes: grantedScopes(fromOAuthScope: staticConnection.oauthScope), integration: "i", connection: "s", operation: "op") == nil)
    }

    @Test func failureHealthReason_feedsRecordHealth() throws {
        let failure = MCPCredentialFailure.blockedByAdmin(owner: .org, integration: "i", connection: "c")
        let health = try MCPConnectionHealth(status: .expired, checkedAt: Date(), detail: failure.message, reason: failure.healthReason)
        #expect(health.reason == .blockedByAdmin)
        let connection = try MCPConnection(owner: .org, name: "c", integration: "i", template: "t", provider: "p", lastHealth: health)
        #expect(connection.lastHealth?.reason == .blockedByAdmin)
    }

    // MARK: - Differential address probe (final pass)

    @Test func address_dottedSlugsMisparseSoConstructionRejectsThem() throws {
        // The silent-misparse mechanism, pinned: a dotted integration shifts
        // every segment of the would-be literal without throwing.
        let shifted = try MCPToolAddress.parse("tools.a.b.user.main.repos.list")
        #expect(shifted.integration == "a")
        #expect(shifted.owner == "b")
        #expect(shifted.connection == "user")
        #expect(shifted.tool == "main.repos.list")
        // Differential sweep: for every ASCII-dot slug, the would-be literal
        // NEVER resolves to the intended triple (it shifts or throws), and
        // construction rejects the slug outright — so no surviving record
        // can address a tool it does not own.
        for slug in ["a.b", ".lead", "trail.", "a..b", ".", "...", "user.main", "a.b.c.d"] {
            let literal = "tools.\(slug).user.main.repos.list"
            let parsed = try? MCPToolAddress.parse(literal)
            #expect(parsed?.integration != slug)
            #expect(throws: MCPConnectionError.invalidCharacters(field: .integration)) {
                try MCPConnection(owner: .user, name: "main", integration: slug, template: "t", provider: "p")
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .name)) {
                try MCPConnection(owner: .user, name: "a\(slug)b", integration: "i", template: "t", provider: "p")
            }
        }
    }

    @Test func address_unicodeDotsAndEmptiesRejectedEverywhere() {
        // Lookalike dots parse faithfully (the grammar splits on ASCII "."
        // only) but are rejected anyway: confusable segments must not exist.
        for slug in ["a。b", "a．b", "a․b", "a·b", "a\u{066B}b", "a\u{FF61}b"] {
            #expect(throws: MCPConnectionError.invalidCharacters(field: .integration)) {
                try MCPConnection(owner: .user, name: "n", integration: slug, template: "t", provider: "p")
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .template)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: slug, provider: "p")
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .provider)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: slug)
            }
            #expect(throws: MCPConnectionError.invalidCharacters(field: .oauthClient)) {
                try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", oauthClient: slug)
            }
        }
        for empty in ["", ".", ".."] {
            if empty.isEmpty {
                #expect(throws: MCPConnectionError.emptyField(.integration)) {
                    try MCPConnection(owner: .user, name: "n", integration: empty, template: "t", provider: "p")
                }
            } else {
                #expect(throws: MCPConnectionError.invalidCharacters(field: .integration)) {
                    try MCPConnection(owner: .user, name: "n", integration: empty, template: "t", provider: "p")
                }
            }
        }
    }

    @Test func address_validBatteryRoundTripsExactly() throws {
        let slugs = ["a", "9", "9aBc_-x", "T0", String(repeating: "s", count: MCPConnection.maxSlugBytes), "a-b_c0Z"]
        let names = ["a", "Z", "_crm$1", "a0_$", String(repeating: "n", count: MCPConnection.maxNameBytes)]
        for slug in slugs {
            for name in names {
                for owner in [PolicyOwner.user, PolicyOwner.org] {
                    let record = try MCPConnection(owner: owner, name: name, integration: slug, template: "t", provider: "p")
                    for tool in ["ping", "repos.list", "a.b.c"] {
                        let address = try record.toolAddress(forTool: tool)
                        #expect(address.literal == "\(record.addressLiteral).\(tool)")
                        let reparsed = try MCPToolAddress.parse(address.literal)
                        #expect(reparsed == address)
                        #expect(reparsed.integration == slug)
                        #expect(reparsed.owner == owner.rawValue)
                        #expect(reparsed.connection == name)
                        #expect(reparsed.tool == tool)
                    }
                }
            }
        }
    }

    @Test func toolAddress_rejectsEmptyDotParts() throws {
        let record = try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default")
        for bad in ["a..b", ".lead", "trail.", "."] {
            #expect(throws: MCPToolAddressError.emptySegment) {
                try record.toolAddress(forTool: bad)
            }
        }
    }

    @Test func route_rejectsHandBuiltInputs() {
        #expect(throws: MCPConnectionError.invalidCharacters(field: .variable)) {
            try routeConnectionInputs([NamedConnectionInput(variable: "has space", origin: .value("x"))], isNoAuthTemplate: false)
        }
        #expect(throws: MCPConnectionError.emptyField(.variable)) {
            try routeConnectionInputs([NamedConnectionInput(variable: "", origin: .value("x"))], isNoAuthTemplate: false)
        }
        #expect(throws: MCPConnectionError.tooLong(field: .variable, maxBytes: MCPConnection.maxVariableBytes)) {
            try routeConnectionInputs([NamedConnectionInput(variable: String(repeating: "v", count: MCPConnection.maxVariableBytes + 1), origin: .value("x"))], isNoAuthTemplate: false)
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalProvider)) {
            try routeConnectionInputs([NamedConnectionInput(variable: "token", origin: .from(provider: "bad provider", id: "x"))], isNoAuthTemplate: false)
        }
        #expect(throws: MCPConnectionError.emptyField(.externalID)) {
            try routeConnectionInputs([NamedConnectionInput(variable: "token", origin: .from(provider: "keychain", id: ""))], isNoAuthTemplate: false)
        }
        // No-auth routing fails closed too: validation precedes the
        // placeholder check, so smuggled keys never reach the decision.
        #expect(throws: MCPConnectionError.invalidCharacters(field: .variable)) {
            try routeConnectionInputs([NamedConnectionInput(variable: "has space", origin: .value(""))], isNoAuthTemplate: true)
        }
    }

    @Test func failure_isThrowableDirectly() {
        let failure = MCPCredentialFailure.refreshRejected(owner: .org, integration: "i", connection: "c")
        #expect(throws: failure) {
            throw failure
        }
    }

    // MARK: - Review: operator text

    @Test func operatorText_rejectsControlFormatAndSeparators() {
        // Zero-width joiner, BOM, line/paragraph separators: all disallowed.
        for hostile in ["a\u{200D}b", "\u{FEFF}lead", "line\u{2028}sep", "para\u{2029}sep", "bell\u{07}", "esc\u{1B}x"] {
            #expect(OperatorText.containsDisallowedTextScalar(hostile) == true, "\(hostile.debugDescription) rejected")
            #expect(throws: MCPConnectionError.invalidCharacters(field: .identityLabel)) {
                try OperatorText.requireDisplayText(hostile, field: .identityLabel, maxBytes: MCPConnection.maxLabelBytes)
            }
        }
        // Emoji, symbols, punctuation, and spaces pass; only the four
        // categories are disallowed.
        for fine in ["staging CRM 🙂", "Reads only. Owner: data-team!", "", "plain", "tab-free ✓"] {
            #expect(OperatorText.containsDisallowedTextScalar(fine) == false, "\(fine) accepted")
        }
        #expect(throws: MCPConnectionError.tooLong(field: .identityLabel, maxBytes: MCPConnection.maxLabelBytes)) {
            try OperatorText.requireDisplayText(
                String(repeating: "l", count: MCPConnection.maxLabelBytes + 1),
                field: .identityLabel, maxBytes: MCPConnection.maxLabelBytes
            )
        }
    }

    @Test func operatorText_connectionDelegatesToSharedRule() {
        // The record enforces the shared rule: invisible-format labels fail
        // through the record the same way they fail through OperatorText.
        #expect(throws: MCPConnectionError.invalidCharacters(field: .identityLabel)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", identityLabel: "a\u{200D}b")
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .description)) {
            try MCPConnection(owner: .user, name: "n", integration: "i", template: "t", provider: "p", description: "para\u{2029}sep")
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .externalID)) {
            try ConnectionExternalRef(provider: "keychain", id: "\u{FEFF}item")
        }
    }

    // MARK: - Review: connection IDs

    @Test func connectionID_parseRoundTrips() throws {
        let id = try MCPConnectionID.parse("github.user.main")
        let direct = try MCPConnectionID(integration: "github", owner: .user, name: "main")
        #expect(id == direct)
        #expect(id.integration == "github")
        #expect(id.owner == .user)
        #expect(id.name == "main")
        #expect(id.description == "github.user.main")
        #expect(try MCPConnectionID.parse(id.description) == id)
        let org = try MCPConnectionID(integration: "9aBc_-x", owner: .org, name: "_crm$1")
        #expect(org.description == "9aBc_-x.org._crm$1")
        #expect(try MCPConnectionID.parse(org.description) == org)
    }

    @Test func connectionID_rejectsShapesAndCharsets() {
        #expect(throws: MCPConnectionIDError.malformed) {
            try MCPConnectionID.parse("github.user")
        }
        #expect(throws: MCPConnectionIDError.malformed) {
            try MCPConnectionID.parse("a.b.c.d")
        }
        #expect(throws: MCPConnectionIDError.malformed) {
            try MCPConnectionID.parse("github..main")
        }
        #expect(throws: MCPConnectionIDError.malformed) {
            try MCPConnectionID.parse(".user.main")
        }
        #expect(throws: MCPConnectionIDError.malformed) {
            try MCPConnectionID.parse("")
        }
        #expect(throws: MCPConnectionIDError.unknownOwner) {
            try MCPConnectionID.parse("github.admin.main")
        }
        #expect(throws: MCPConnectionIDError.unknownOwner) {
            try MCPConnectionID.parse("github.User.main")
        }
        // Parts face the record charsets: dotted segments cannot occur, and
        // bad characters report the record field.
        #expect(throws: MCPConnectionError.invalidCharacters(field: .integration)) {
            try MCPConnectionID.parse("has space.user.main")
        }
        #expect(throws: MCPConnectionError.invalidCharacters(field: .name)) {
            try MCPConnectionID.parse("github.user.0bad")
        }
        #expect(throws: MCPConnectionError.emptyField(.name)) {
            try MCPConnectionID(integration: "i", owner: .user, name: "")
        }
    }

    // MARK: - Review: scope fail-open split

    @Test func evaluateScopeGap_oauthNilGrantFailsClosed() throws {
        // OAuth with unknown coverage: every countable declared scope misses.
        let gap = try #require(evaluateScopeGap(
            declared: ["read", "write"], grantedScopes: nil, oauthClient: "app",
            integration: "github", connection: "main", operation: "repos.delete"
        ))
        #expect(gap.missing == ["read", "write"])
        #expect(gap.prompt.contains("Reconnect 'main'"))
        #expect(gap.prompt.contains("repos.delete"))
        #expect(gap.retryable == false)
        // Nothing required, nothing missing — even on OAuth.
        #expect(evaluateScopeGap(
            declared: [], grantedScopes: nil, oauthClient: "app",
            integration: "i", connection: "c", operation: "op"
        ) == nil)
        #expect(evaluateScopeGap(
            declared: ["openid", "email"], grantedScopes: nil, oauthClient: "app",
            integration: "i", connection: "c", operation: "op"
        ) == nil)
        // Known-empty grants fail closed on both sides already.
        #expect(evaluateScopeGap(
            declared: ["read"], grantedScopes: [], integration: "i", connection: "c", operation: "op"
        )?.missing == ["read"])
        #expect(evaluateScopeGap(
            declared: ["read"], grantedScopes: [], oauthClient: "app",
            integration: "i", connection: "c", operation: "op"
        )?.missing == ["read"])
        // Known coverage still diffs normally when the client is named.
        #expect(evaluateScopeGap(
            declared: ["read"], grantedScopes: ["read"], oauthClient: "app",
            integration: "i", connection: "c", operation: "op"
        ) == nil)
    }

    @Test func scopeGap_legacyRowsPreserved() throws {
        // Legacy static row: no OAuth fields at all, still fails open.
        let staticRow = try MCPConnection(owner: .user, name: "main", integration: "github", template: "apiKey", provider: "default")
        #expect(evaluateScopeGap(
            declared: ["read"], grantedScopes: grantedScopes(fromOAuthScope: staticRow.oauthScope),
            oauthClient: staticRow.oauthClient,
            integration: staticRow.integration, connection: staticRow.name, operation: "op"
        ) == nil)
        // Legacy OAuth row: a client with no scope echo still constructs and
        // decodes (the linkage invariant is advisory at rest) ...
        let legacyOAuth = try MCPConnection(owner: .user, name: "main", integration: "github", template: "oauth", provider: "default", oauthClient: "app")
        #expect(legacyOAuth.oauthScope == nil)
        let decoded = try JSONDecoder().decode(
            MCPConnection.self,
            from: Data(#"{"owner":"user","name":"main","integration":"github","template":"oauth","provider":"default","oauthClient":"app"}"#.utf8)
        )
        #expect(decoded == legacyOAuth)
        // ... but evaluates fail-closed once declared scopes exist.
        #expect(evaluateScopeGap(
            declared: ["read"], grantedScopes: grantedScopes(fromOAuthScope: decoded.oauthScope),
            oauthClient: decoded.oauthClient,
            integration: decoded.integration, connection: decoded.name, operation: "op"
        )?.missing == ["read"])
        #expect(evaluateScopeGap(
            declared: [], grantedScopes: grantedScopes(fromOAuthScope: decoded.oauthScope),
            oauthClient: decoded.oauthClient,
            integration: decoded.integration, connection: decoded.name, operation: "op"
        ) == nil)
    }
}
