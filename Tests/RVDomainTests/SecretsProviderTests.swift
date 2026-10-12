import Testing
import RVDomain

private struct MappingStubSecretsProvider: SecretsProvider {
    let id: String

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        .text("value-for-" + ref.item)
    }

    func health() async -> ProviderHealth {
        ProviderHealth(ok: true, identity: id + "-identity")
    }
}

private struct FixedStubSecretsProvider: SecretsProvider {
    let id: String
    let result: Result<SecretValue, SecretsError>
    let status: ProviderHealth

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        _ = ref
        return try result.get()
    }

    func health() async -> ProviderHealth { status }
}

struct SecretsProviderTests {
    @Test("every allowed provider constructs", arguments: ["file", "keychain", "vault-http", "env", "exec"])
    func allowedProvider_constructs(provider: String) throws {
        let ref = try SecretRef(provider: provider, item: "api-token", field: "token")
        #expect(ref.provider == provider)
        #expect(ref.item == "api-token")
        #expect(ref.field == "token")
    }

    @Test func field_defaultsToNil() throws {
        let ref = try SecretRef(provider: "file", item: "api-token")
        #expect(ref.field == nil)
    }

    @Test func emptyProvider_throwsInvalidRef() {
        #expect(throws: SecretsError.invalidRef("")) {
            try SecretRef(provider: "", item: "api-token")
        }
    }

    @Test func emptyItem_throwsInvalidRefNamingProviderOnly() {
        do {
            _ = try SecretRef(provider: "file", item: "", field: "sekret-field")
            Issue.record("expected invalidRef for empty item")
        } catch {
            #expect(error as? SecretsError == SecretsError.invalidRef("file"))
            #expect(String(describing: error).contains("sekret-field") == false)
        }
    }

    @Test(
        "unknown provider rejected",
        arguments: [
            "vault", "s3", "1password", "FILE", "File", " file", "file ", "file\n",
            "filé", "🔑", "keychain;id", "../file", "vault-http-v2", " ", "\t",
        ]
    )
    func unknownProvider_throwsInvalidRef(provider: String) {
        #expect(throws: SecretsError.invalidRef(provider)) {
            try SecretRef(provider: provider, item: "item", field: "field")
        }
    }

    @Test func unicodeItem_acceptedVerbatim() throws {
        let ref = try SecretRef(provider: "keychain", item: "tökén-🔑-名前")
        #expect(ref.item == "tökén-🔑-名前")
    }

    @Test func unicodeField_acceptedVerbatim() throws {
        let ref = try SecretRef(provider: "env", item: "bundle", field: "clé-🔑")
        #expect(ref.field == "clé-🔑")
    }

    @Test func emptyField_passesThroughUnchanged() throws {
        let ref = try SecretRef(provider: "exec", item: "bundle", field: "")
        #expect(ref.field == "")
    }

    @Test func oversizedItem_acceptedAtTraitLevel() throws {
        let item = String(repeating: "a", count: 1 << 20)
        let ref = try SecretRef(provider: "file", item: item)
        #expect(ref.item.count == 1 << 20)
    }

    @Test func hostileItem_preservedVerbatim() throws {
        let ref = try SecretRef(provider: "file", item: "../etc/passwd\0\n injection")
        #expect(ref.item == "../etc/passwd\0\n injection")
    }

    @Test func allowedProviders_containsExactlySevenIds() {
        #expect(
            SecretRef.allowedProviders == [
                "file", "keychain", "vault-http", "env", "exec", "encrypted",
                "workos-vault",
            ]
        )
    }

    @Test func ref_hashableAsDictionaryKey() throws {
        let first = try SecretRef(provider: "file", item: "a", field: "f")
        let equal = try SecretRef(provider: "file", item: "a", field: "f")
        let fielded = try SecretRef(provider: "file", item: "a", field: "g")
        let unfielded = try SecretRef(provider: "file", item: "a")
        let values: [SecretRef: SecretValue] = [first: .text("one")]
        #expect(values[equal] == .text("one"))
        #expect(values[fielded] == nil)
        #expect(values[unfielded] == nil)
    }

    @Test func ref_inequalityAcrossPositions() throws {
        let base = try SecretRef(provider: "file", item: "a", field: "f")
        #expect(base != (try SecretRef(provider: "env", item: "a", field: "f")))
        #expect(base != (try SecretRef(provider: "file", item: "b", field: "f")))
        #expect(base != (try SecretRef(provider: "file", item: "a", field: "g")))
        #expect(base != (try SecretRef(provider: "file", item: "a")))
    }

    @Test func error_allNineCasesPairwiseDistinct() {
        let cases: [SecretsError] = [
            .invalidRef("file"), .notFound("keychain"), .denied("vault-http"),
            .identityRequired, .leaseExpired("env"), .providerDown("exec"),
            .oversized("file"), .policyDenied, .timeout("resolve"),
        ]
        #expect(cases.count == 9)
        for left in cases.indices {
            for right in cases.indices where right > left {
                #expect(cases[left] != cases[right])
            }
        }
    }

    @Test func error_payloadDistinguishesSameCase() {
        #expect(SecretsError.notFound("a") != SecretsError.notFound("b"))
        #expect(SecretsError.timeout("resolve") != SecretsError.timeout("health"))
        #expect(SecretsError.notFound("x") != SecretsError.denied("x"))
        #expect(SecretsError.invalidRef("x") == SecretsError.invalidRef("x"))
    }

    @Test func error_descriptionsNeverEchoItemFieldOrValue() {
        let cases: [SecretsError] = [
            .invalidRef("file"), .notFound("keychain"), .denied("vault-http"),
            .leaseExpired("env"), .providerDown("exec"), .oversized("file"),
            .timeout("resolve"), .identityRequired, .policyDenied,
        ]
        for error in cases {
            let text = String(describing: error)
            #expect(text.contains("super-secret-item") == false)
            #expect(text.contains("password-field") == false)
            #expect(text.contains("hunter2-value") == false)
        }
        #expect(String(describing: SecretsError.providerDown("exec")).contains("exec"))
        #expect(String(describing: SecretsError.timeout("resolve")).contains("resolve"))
    }

    @Test func error_bodilessCasesCarryNothing() {
        let identity: SecretsError = .identityRequired
        let policy: SecretsError = .policyDenied
        #expect(identity == .identityRequired)
        #expect(policy == .policyDenied)
        #expect(identity != policy)
        if case .identityRequired = identity {} else { Issue.record("identityRequired lost shape") }
        if case .policyDenied = policy {} else { Issue.record("policyDenied lost shape") }
    }

    @Test(
        "text round-trips",
        arguments: ["", "hunter2", "line one\nline two\n", "tökén-🔑-名前", String(repeating: "v", count: 16_384)]
    )
    func value_textRoundTrips(text: String) {
        if case .text(let held) = SecretValue.text(text) {
            #expect(held == text)
        } else {
            Issue.record("text case lost shape")
        }
    }

    @Test func value_filePathDistinctFromText() {
        #expect(SecretValue.filePath("/run/sock") != SecretValue.text("/run/sock"))
        #expect(SecretValue.filePath("/a") == SecretValue.filePath("/a"))
        #expect(SecretValue.filePath("/a") != SecretValue.filePath("/b"))
        #expect(SecretValue.text("a") != SecretValue.text("b"))
    }

    @Test func health_reportsOkAndIdentity() {
        let healthy = ProviderHealth(ok: true, identity: "approle-ci")
        #expect(healthy.ok)
        #expect(healthy.identity == "approle-ci")
        let down = ProviderHealth(ok: false)
        #expect(down.ok == false)
        #expect(down.identity == nil)
    }

    @Test func health_equality() {
        #expect(ProviderHealth(ok: true, identity: "a") == ProviderHealth(ok: true, identity: "a"))
        #expect(ProviderHealth(ok: true, identity: "a") != ProviderHealth(ok: true, identity: "b"))
        #expect(ProviderHealth(ok: true) != ProviderHealth(ok: false))
    }

    @Test func provider_resolveDeliversRefIntact() async throws {
        let stub = MappingStubSecretsProvider(id: "file")
        let ref = try SecretRef(provider: "file", item: "deploy-key", field: "private")
        #expect(try await stub.resolve(ref) == .text("value-for-deploy-key"))
    }

    @Test func provider_resolveThrowsProviderError() async throws {
        let stub = FixedStubSecretsProvider(
            id: "vault-http",
            result: .failure(.notFound("vault-http")),
            status: ProviderHealth(ok: true)
        )
        let ref = try SecretRef(provider: "vault-http", item: "super-secret-item")
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await stub.resolve(ref)
        }
    }

    @Test(
        "every stub error propagates through resolve",
        arguments: [
            SecretsError.denied("vault-http"),
            .leaseExpired("env"),
            .providerDown("exec"),
            .oversized("file"),
            .policyDenied,
            .timeout("resolve"),
        ]
    )
    func provider_resolveThrowsEachProviderError(error: SecretsError) async throws {
        let stub = FixedStubSecretsProvider(
            id: "vault-http",
            result: .failure(error),
            status: ProviderHealth(ok: true)
        )
        let ref = try SecretRef(provider: "vault-http", item: "super-secret-item")
        await #expect(throws: error) {
            try await stub.resolve(ref)
        }
    }

    @Test func whitespaceOnlyItem_acceptedPerNonEmptyContract() throws {
        let ref = try SecretRef(provider: "file", item: " ")
        #expect(ref.item == " ")
    }

    @Test func health_allowsDownWithIdentity() {
        let status = ProviderHealth(ok: false, identity: "stale-token")
        #expect(status.ok == false)
        #expect(status.identity == "stale-token")
    }

    @Test func provider_healthReportsStatus() async {
        let stub = FixedStubSecretsProvider(
            id: "keychain",
            result: .success(.text("unused")),
            status: ProviderHealth(ok: true, identity: "login-keychain")
        )
        let status = await stub.health()
        #expect(status == ProviderHealth(ok: true, identity: "login-keychain"))
    }

    @Test func provider_existentialRegistryDispatchesById() async throws {
        let file = FixedStubSecretsProvider(
            id: "file", result: .success(.text("file-value")),
            status: ProviderHealth(ok: true)
        )
        let vault = FixedStubSecretsProvider(
            id: "vault-http", result: .success(.text("vault-value")),
            status: ProviderHealth(ok: true)
        )
        let registry: [String: any SecretsProvider] = [file.id: file, vault.id: vault]
        #expect(try await registry["file"]?.resolve(try SecretRef(provider: "file", item: "a")) == .text("file-value"))
        #expect(try await registry["vault-http"]?.resolve(try SecretRef(provider: "vault-http", item: "b")) == .text("vault-value"))
        #expect(registry["keychain"] == nil)
    }

    @Test func provider_concurrentResolvesAllSucceed() async throws {
        let stub = MappingStubSecretsProvider(id: "file")
        let ref = try SecretRef(provider: "file", item: "token")
        let results = await withTaskGroup(of: SecretValue.self, returning: [SecretValue].self) { group in
            for _ in 0..<50 {
                group.addTask { (try? await stub.resolve(ref)) ?? .text("FAILED") }
            }
            var collected: [SecretValue] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }
        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == .text("value-for-token") })
    }

    @Test func ref_crossesTaskBoundariesIntact() async throws {
        let ref = try SecretRef(provider: "vault-http", item: "api/key", field: "token")
        let copies = await withTaskGroup(of: SecretRef.self, returning: [SecretRef].self) { group in
            for _ in 0..<8 {
                group.addTask { ref }
            }
            var collected: [SecretRef] = []
            for await copy in group {
                collected.append(copy)
            }
            return collected
        }
        #expect(copies.count == 8)
        #expect(copies.allSatisfy { $0 == ref })
    }

    @Test func brokerEntryRefFailsClosedOnEmptyItem() {
        #expect(
            RuntimeResourceProfile.BrokerEntry(provider: "file", item: "", env: "TOKEN").ref == nil
        )
        #expect(
            RuntimeResourceProfile.BrokerEntry(provider: "nope", item: "i", env: "TOKEN").ref == nil
        )
    }

    @Test func defaultProviderIsAllowlisted() {
        #expect(SecretRef.allowedProviders.contains(SecretRef.defaultProvider))
        #expect(SecretRef.defaultProvider == "file")
    }
}
