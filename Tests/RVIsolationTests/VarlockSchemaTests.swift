import Foundation
import Testing
@testable import RVIsolation

@Suite("Varlock schema import")
struct VarlockSchemaTests {
    private static let schema = """
        # @plugin(@varlock/infisical-plugin)
        # @initInfisical(projectId=proj, environment=dev, secretPath=/)
        # @initAws(region=us-east-1)
        # @initGsm(projectId=my-project)
        # @initAzure(vaultUrl="https://my-vault.vault.azure.net/")
        # @defaultSensitive=false
        # ---
        # OpenAI API key
        # @required @sensitive @type=string(startsWith=sk-)
        OPENAI_API_KEY=op(op://Eng/OpenAI/credential)

        PORT=3000

        # @sensitive
        LITERAL=sk-live-abcdefghijklmnopqrstuvwxyz

        # @sensitive @type=string
        DATABASE_URL=infisical()

        # @sensitive
        NAMED=infisical("STRIPE_SECRET_KEY")

        # @sensitive
        API_KEY=gsm("api-key@5")

        # @sensitive
        FULL=gsm("projects/other/secrets/db-url/versions/3")

        # @sensitive
        DB=azureSecret()

        # @sensitive
        PINNED=azureSecret("api-key@abc123")

        # @sensitive
        BW=bitwarden("12345678-1234-1234-1234-123456789abc")

        # @sensitive
        TOKEN=vaultSecret("secret/app#token")

        # @sensitive
        AWS=awsSecret("prod/thing#key")

        # @sensitive
        PUBLIC_KEY=op(dev, op://Eng/Public/key)
        """

    @Test func mapsDecoratorsAndProviderRefsAndDropsLiterals() throws {
        let plan = try VarlockSchema.plan(Self.schema).get()
        let openai = try #require(plan.secrets.first { $0.name == "OPENAI_API_KEY" })
        #expect(openai.description == "OpenAI API key")
        #expect(openai.type == "string(startsWith=sk-)")
        #expect(openai.delivery == .environment)
        #expect(openai.source == .onePassword(reference: "op://Eng/OpenAI/credential"))

        #expect(plan.secrets.contains { $0.name == "PORT" } == false)
        #expect(plan.notes.contains { $0.contains("PORT") && $0.contains("not sensitive") })
        #expect(plan.secrets.contains { $0.name == "LITERAL" } == false)
        #expect(plan.notes.contains { $0 == "skip LITERAL: literal value not copied" })

        #expect(plan.secrets.first { $0.name == "DATABASE_URL" }?.source == .infisical(
            name: "DATABASE_URL", project: "proj", environment: "dev", path: "/"))
        #expect(plan.secrets.first { $0.name == "NAMED" }?.source == .infisical(
            name: "STRIPE_SECRET_KEY", project: "proj", environment: "dev", path: "/"))
        #expect(plan.secrets.first { $0.name == "API_KEY" }?.source == .gcp(
            secret: "api-key", project: "my-project", version: "5"))
        #expect(plan.secrets.first { $0.name == "FULL" }?.source == .gcp(secret: "db-url", project: "other", version: "3"))
        #expect(plan.secrets.first { $0.name == "DB" }?.source == .azure(vault: "my-vault", name: "db", version: nil))
        #expect(plan.secrets.first { $0.name == "PINNED" }?.source == .azure(vault: "my-vault", name: "api-key", version: "abc123"))
        #expect(plan.secrets.first { $0.name == "BW" }?.source == .bitwarden(id: "12345678-1234-1234-1234-123456789abc"))
        #expect(plan.secrets.first { $0.name == "TOKEN" }?.source == .vault(path: "secret/data/app", field: "token", address: nil))
        #expect(plan.secrets.first { $0.name == "AWS" }?.source == .awsSecretsManager(
            secretID: "prod/thing", field: "key", region: "us-east-1"))
        #expect(plan.secrets.first { $0.name == "PUBLIC_KEY" }?.source == .onePassword(reference: "op://Eng/Public/key"))

        let encoded = String(decoding: SecretsConfiguration(secrets: plan.secrets).encoded(), as: UTF8.self)
        #expect(encoded.contains("sk-live-") == false)
        #expect(encoded.contains("abcdefghijklmnopqrstuvwxyz") == false)
        #expect(plan.notes.joined(separator: "\n").contains("sk-live-") == false)
    }

    @Test func unmarkedItemsAreSensitiveUnlessTheHeaderSaysOtherwise() throws {
        let implicit = try VarlockSchema.plan("KEY=op(op://v/i/f)\n").get()
        #expect(implicit.secrets.map(\.name) == ["KEY"])
        let prefix = try VarlockSchema.plan("""
            # @defaultSensitive=inferFromPrefix(PUBLIC_)
            PUBLIC_TOKEN=op(op://v/i/public)
            # @sensitive
            PUBLIC_OVERRIDE=op(op://v/i/override)
            PRIVATE=op(op://v/i/private)
            """).get()
        #expect(prefix.secrets.map(\.name) == ["PUBLIC_OVERRIDE", "PRIVATE"])
    }

    @Test func unmatchedInstanceIsSkippedNotRebound() throws {
        let plan = try VarlockSchema.plan("""
            # @initInfisical(id=prod, projectId=PROJPROD)
            # @initInfisical(id=dev, projectId=PROJDEV)
            # @sensitive
            K=infisical("typo-id", "MYSECRET")
            # @sensitive
            J=infisical("prod", "OTHER")
            """).get()
        #expect(plan.secrets.map(\.name) == ["J"])
        #expect(plan.secrets.first?.source == .infisical(name: "OTHER", project: "PROJPROD", environment: nil, path: nil))
        #expect(plan.notes.contains { $0.contains("typo-id") && $0.contains("not one of the declared instances") })
    }

    @Test func spacedAssignmentImports() throws {
        let plan = try VarlockSchema.plan("# @sensitive\nSPACED = op(op://v/i/f)\n").get()
        #expect(plan.secrets.map(\.name) == ["SPACED"])
    }

    @Test func roundTripsTheNewSourceKinds() throws {
        let secret = SecretDefinition(
            name: "DB", description: "database", source: .azure(vault: "my-vault", name: "db", version: nil),
            delivery: .environment, type: "string")
        let decoded = try SecretsConfiguration.decode(SecretsConfiguration(secrets: [secret]).encoded()).get()
        #expect(decoded.secrets == [secret])
    }

    private static func encoded(_ plan: VarlockImportPlan) -> String {
        String(decoding: SecretsConfiguration(secrets: plan.secrets).encoded(), as: UTF8.self)
    }

    // MARK: Commented-out items (Varlock classes.ts:454-468)

    @Test func commentedOutItemsNeverReachTheDescription() throws {
        let plan = try VarlockSchema.plan("""
            # Stripe key
            # OLD_KEY=sk-live-oldvalue
            # # export LEGACY.KEY = sk-live-legacy
            # @sensitive
            STRIPE=op(op://v/i/f)

            # Kept
            # PEM="-----BEGIN
            # sk-live-continued
            # sk-live-end"
            # @sensitive
            PEM_KEY=op(op://v/i/pem)
            """).get()
        #expect(plan.secrets.first { $0.name == "STRIPE" }?.description == "Stripe key")
        #expect(plan.secrets.first { $0.name == "PEM_KEY" }?.description == "Kept")
        #expect(Self.encoded(plan).contains("sk-live") == false)
    }

    // MARK: Provider signatures (each plugin's resolver process())

    @Test func awsSecretMatchesThePluginSignature() throws {
        let plan = try VarlockSchema.plan("""
            # @initAws(region=eu-west-1, namePrefix=prod/)
            # ---
            # @sensitive
            HASHED=awsSecret("db#password")
            # @sensitive
            KEYED=awsSecret("db#ignored", key=user)
            # @sensitive
            INFERRED=awsSecret()
            # @sensitive
            PARAM=awsParam("/app/param")
            # @sensitive
            OLD=awsSecretsManager("prod/thing", field="key")
            """).get()
        func source(_ name: String) -> SecretSource? { plan.secrets.first { $0.name == name }?.source }
        #expect(source("HASHED") == .awsSecretsManager(secretID: "prod/db", field: "password", region: "eu-west-1"))
        #expect(source("KEYED") == .awsSecretsManager(secretID: "prod/db", field: "user", region: "eu-west-1"))
        #expect(source("INFERRED") == .awsSecretsManager(secretID: "prod/INFERRED", field: nil, region: "eu-west-1"))
        #expect(plan.notes.contains { $0.hasPrefix("skip PARAM:") && $0.contains("Parameter Store") })
        #expect(plan.notes.contains("skip OLD: no supported provider reference"))
    }

    @Test func vaultSecretMatchesThePluginSignature() throws {
        let plan = try VarlockSchema.plan("""
            # @initHcpVault(url="https://vault.example.com:8200", defaultPath=secret/app)
            # @initHcpVault(id=team, url="https://vault.example.com:8200", pathPrefix=team/)
            # ---
            # @sensitive
            DEFAULTED=vaultSecret()
            # @sensitive
            HASHED=vaultSecret("kv/db#password")
            # @sensitive
            KEYED=vaultSecret("kv/db", key=user)
            # @sensitive
            PREFIXED=vaultSecret(team, "kv/db")
            # @sensitive
            RAW=vaultSecret("kv/db", raw=true)
            """).get()
        let address = URL(string: "https://vault.example.com:8200")
        func source(_ name: String) -> SecretSource? { plan.secrets.first { $0.name == name }?.source }
        #expect(source("DEFAULTED") == .vault(path: "secret/data/app", field: "DEFAULTED", address: address))
        #expect(source("HASHED") == .vault(path: "kv/data/db", field: "password", address: address))
        #expect(source("KEYED") == .vault(path: "kv/data/db", field: "user", address: address))
        #expect(source("PREFIXED") == .vault(path: "team/data/kv/db", field: "PREFIXED", address: address))
        #expect(plan.notes.contains { $0.hasPrefix("skip RAW:") })
        #expect(throws: Never.self) { try SecretsConfiguration.decode(SecretsConfiguration(secrets: plan.secrets).encoded()).get() }
    }

    @Test func infisicalAndAzureMatchThePluginSignatures() throws {
        let plan = try VarlockSchema.plan("""
            # @initInfisical(projectId=proj, environment=dev, secretPath=/base)
            # @initInfisical(id=other, projectId=proj2, environment=prd)
            # @initAzure(vaultUrl="https://my-vault.vault.azure.net/")
            # ---
            # @sensitive
            DEFAULTED=infisical()
            # @sensitive
            INSTANCE=infisical(other, "NAME")
            # @sensitive
            PATHED=infisical(other, "NAME", "/billing")
            # @sensitive
            UNKNOWN=infisical("NAME", "/billing")
            # @sensitive
            VERSIONED=azureSecret("api-key@old", version=abc)
            # @sensitive
            JSON_KEY=azureSecret("api-key", key=password)
            """).get()
        func source(_ name: String) -> SecretSource? { plan.secrets.first { $0.name == name }?.source }
        #expect(source("DEFAULTED") == .infisical(name: "DEFAULTED", project: "proj", environment: "dev", path: "/base"))
        #expect(source("INSTANCE") == .infisical(name: "NAME", project: "proj2", environment: "prd", path: nil))
        #expect(source("PATHED") == .infisical(name: "NAME", project: "proj2", environment: "prd", path: "/billing"))
        #expect(plan.notes.contains { $0.hasPrefix("skip UNKNOWN:") && $0.contains("not one of the declared instances") })
        #expect(source("VERSIONED") == .azure(vault: "my-vault", name: "api-key", version: "abc"))
        #expect(plan.notes.contains { $0.hasPrefix("skip JSON_KEY:") })
    }

    @Test func referencesAreNeverTakenLiterally() throws {
        let plan = try VarlockSchema.plan("""
            # @initInfisical(projectId=$INFISICAL_PROJECT, environment=dev)
            # @initAws(region=$AWS_REGION)
            # @initHcpVault(url=$VAULT_URL)
            # ---
            # @sensitive
            INF=infisical()
            # @sensitive
            AWS=awsSecret("x")
            # @sensitive
            VAULT=vaultSecret("kv/x")
            # @sensitive
            GSM=gsm($SECRET_NAME)
            """).get()
        #expect(plan.notes.contains { $0.hasPrefix("skip INF:") && $0.contains("reference") })
        #expect(plan.secrets.first { $0.name == "AWS" }?.source == .awsSecretsManager(secretID: "x", field: nil, region: nil))
        #expect(plan.notes.contains { $0.hasPrefix("note AWS:") && $0.contains("region") })
        #expect(plan.secrets.first { $0.name == "VAULT" }?.source == .vault(path: "kv/data/x", field: "VAULT", address: nil))
        #expect(plan.notes.contains { $0.hasPrefix("note VAULT:") && $0.contains("VAULT_ADDR") })
        #expect(plan.notes.contains { $0.hasPrefix("skip GSM:") && $0.contains("reference") })
        #expect(Self.encoded(plan).contains("$") == false)
    }

    // MARK: Sensitivity (config-item.ts:724-765)

    @Test func publicFalseMeansSensitive() throws {
        let plan = try VarlockSchema.plan("""
            # @defaultSensitive=false
            # ---
            # @public=false
            HIDDEN=op(op://v/i/hidden)
            # @public
            SHOWN=op(op://v/i/shown)
            # @public=true
            SHOWN_TOO=op(op://v/i/shown2)
            # @sensitive=false
            PLAIN=op(op://v/i/plain)
            """).get()
        #expect(plan.secrets.map(\.name) == ["HIDDEN"])
    }

    @Test func sensitiveObjectFormKeepsSensitivityAndSaysWhatIsDropped() throws {
        let plan = try VarlockSchema.plan("""
            # @defaultSensitive=false
            # ---
            # @sensitive={preventLeaks=false, redact=true}
            OPTIONED=op(op://v/i/a)
            # @sensitive={enabled=false}
            DISABLED=op(op://v/i/b)
            """).get()
        #expect(plan.secrets.map(\.name) == ["OPTIONED"])
        #expect(plan.notes.contains { $0.hasPrefix("note OPTIONED:") && $0.contains("preventLeaks") })
        #expect(plan.notes.contains("skip DISABLED: not sensitive"))
    }

    // MARK: Lines the importer cannot use must not leak comments forward

    @Test func exportAndDottedKeysConsumeTheirOwnComments() throws {
        let plan = try VarlockSchema.plan("""
            # @defaultSensitive=false
            # ---
            # Exported
            # @sensitive
            export EXPORTED=op(op://v/i/e)
            # Dotted note
            # @sensitive
            my.dotted-key=op(op://v/i/d)
            NEXT=op(op://v/i/n)
            """).get()
        #expect(plan.secrets.map(\.name) == ["EXPORTED"])
        #expect(plan.secrets.first?.description == "Exported")
        #expect(plan.notes.contains("skip my.dotted-key: not an environment variable name"))
        #expect(plan.notes.contains("skip NEXT: not sensitive"))
    }

    // MARK: Schema errors (config-item.ts:332-345)

    @Test func repeatedValueDecoratorIsASchemaError() {
        let sameLine = VarlockSchema.plan("# @sensitive @sensitive=false\nKEY=op(op://v/i/f)\n")
        #expect(sameLine.failureMessage?.contains("KEY") == true)
        #expect(sameLine.failureMessage?.contains("@sensitive") == true)
        let acrossLines = VarlockSchema.plan("# @type=string\n# @type=url\nKEY=op(op://v/i/f)\n")
        #expect(acrossLines.failureMessage?.contains("@type") == true)
        let functions = VarlockSchema.plan("# @docs(a) @docs(b) @sensitive\nKEY=op(op://v/i/f)\n")
        #expect(functions.failureMessage == nil)
    }

    // MARK: Root decorators

    @Test func disabledSchemaImportsNothing() throws {
        let disabled = try VarlockSchema.plan("# @disable\n# ---\nKEY=op(op://v/i/f)\n").get()
        #expect(disabled.secrets.isEmpty)
        #expect(disabled.notes.contains { $0.contains("@disable") })
        let conditional = try VarlockSchema.plan("# @disable=forEnv(test)\n# ---\nKEY=op(op://v/i/f)\n").get()
        #expect(conditional.secrets.isEmpty)
        #expect(conditional.notes.contains { $0.contains("@disable") })
        let enabled = try VarlockSchema.plan("# @disable=false\n# ---\nKEY=op(op://v/i/f)\n").get()
        #expect(enabled.secrets.map(\.name) == ["KEY"])
    }

    @Test func everyCommentBlockBeforeTheFirstItemIsHeader() throws {
        let plan = try VarlockSchema.plan("""
            # @plugin(@varlock/infisical-plugin)
            # @initInfisical(projectId=proj, environment=dev)

            # @defaultSensitive=false
            # ---

            PORT=op(op://v/i/port)
            # @sensitive
            KEY=infisical()
            """).get()
        #expect(plan.secrets.map(\.name) == ["KEY"])
        #expect(plan.secrets.first?.source == .infisical(name: "KEY", project: "proj", environment: "dev", path: nil))
    }

    // MARK: Values that secrets.json cannot hold degrade, not abort

    @Test func overlongTypeIsDroppedWithANote() throws {
        let long = "string(startsWith=" + String(repeating: "a", count: 150) + ")"
        let plan = try VarlockSchema.plan("""
            # Zero\u{200B}width description
            # @sensitive @type=\(long)
            KEY=op(op://v/i/f)
            """).get()
        let secret = try #require(plan.secrets.first)
        #expect(secret.type == nil)
        #expect(plan.notes.contains { $0.hasPrefix("note KEY:") && $0.contains("type") })
        #expect(throws: Never.self) { try SecretsConfiguration.decode(SecretsConfiguration(secrets: plan.secrets).encoded()).get() }
    }

    @Test func postCommentDecoratorsApply() throws {
        let plan = try VarlockSchema.plan("""
            # @defaultSensitive=false
            # ---
            TOKEN=op(op://v/i/token) # @sensitive @type=string
            PUBLIC=op(op://v/i/public) # just a note
            """).get()
        #expect(plan.secrets.map(\.name) == ["TOKEN"])
        #expect(plan.secrets.first?.type == "string")
        #expect(plan.notes == ["skip PUBLIC: not sensitive"])
    }

    @Test func multiLineQuotedValueIsOneItem() throws {
        let plan = try VarlockSchema.plan("""
            NOTE="first line
            HIDDEN=op(op://v/i/hidden)
            # @public
            last line"
            BLOCK=```
            RAW=op(op://v/i/raw)
            ```
            # @sensitive
            REAL=op(op://v/i/real)
            """).get()
        #expect(plan.secrets.map(\.name) == ["REAL"])
        #expect(plan.notes.allSatisfy { $0.contains("HIDDEN") == false && $0.contains("RAW") == false })
    }

    @Test func quotedValuesKeepAtSpacesAndHash() throws {
        let plan = try VarlockSchema.plan("""
            # @type="string(a @ b # c)" @sensitive # trailing comment
            KEY=vaultSecret("secret/app#token") # @docs("https://example.com/#anchor")
            """).get()
        let secret = try #require(plan.secrets.first)
        #expect(secret.type == "string(a @ b # c)")
        #expect(secret.source == .vault(path: "secret/data/app", field: "token", address: nil))
    }

    @Test func escapedDollarIsLiteral() throws {
        let plan = try VarlockSchema.plan(#"""
            # @sensitive
            ESCAPED=vaultSecret("secret/app", key="pa\$s")
            # @sensitive
            EXPANDED=vaultSecret("secret/app", key="pa$s")
            """#).get()
        #expect(plan.secrets.map(\.name) == ["ESCAPED"])
        #expect(plan.secrets.first?.source == .vault(path: "secret/data/app", field: "pa$s", address: nil))
    }

    @Test func invalidSyntaxNamesTheLineButNoText() {
        let parsed = VarlockSchema.plan("A=op(op://v/i/f)\nB=\"sk-live-unclosed\nC=1\n")
        #expect(parsed.failureMessage == "line 2 is not valid .env.schema syntax")
    }

    // @proxy/@placeholder/@type semantics follow Varlock (MIT):
    // decorators.ts:1063-1085, placeholder.ts:25-127, config-item.ts:700-717.
    private static func gateway(_ upstream: String, _ baseURLEnv: String, _ prefix: String = "") -> SecretDelivery {
        .gateway(SecretGatewayBinding(upstream: URL(string: upstream)!, baseURLEnv: baseURLEnv, placeholderPrefix: prefix))
    }

    @Test func proxyDomainBecomesGatewayDelivery() throws {
        let plan = try VarlockSchema.plan("""
            # @proxy(domain="API.Example.com") @type=string(startsWith=ak_)
            ACME_KEY=op(op://Eng/Acme/key)
            # @proxy(domain=api.anthropic.com)
            ANTHROPIC_API_KEY=op(op://Eng/Anthropic/key)
            # @proxy(domain=api.openai.com) @type=string(startsWith=sk-proj-)
            OPENAI_API_KEY=op(op://Eng/OpenAI/key)
            # @proxy(domain=openai.internal.example.com)
            GITHUB_TOKEN=op(op://Eng/GitHub/token)
            # @sensitive
            PLAIN=op(op://Eng/Plain/key)
            """).get()
        let delivery = Dictionary(uniqueKeysWithValues: plan.secrets.map { ($0.name, $0.delivery) })
        #expect(delivery["ACME_KEY"] == Self.gateway("https://api.example.com", "ACME_KEY_BASE_URL", "ak_"))
        #expect(delivery["ANTHROPIC_API_KEY"] == Self.gateway("https://api.anthropic.com", "ANTHROPIC_BASE_URL", "sk-ant-"))
        // A known name keeps its curated path when the domain matches; startsWith wins over the curated prefix.
        #expect(delivery["OPENAI_API_KEY"] == Self.gateway("https://api.openai.com/v1", "OPENAI_BASE_URL", "sk-proj-"))
        #expect(delivery["GITHUB_TOKEN"] == Self.gateway("https://openai.internal.example.com", "GITHUB_API_URL"))
        #expect(delivery["PLAIN"] == .environment)
        #expect(plan.notes.contains("note ACME_KEY: point the client at $ACME_KEY_BASE_URL; rv sends the value only to api.example.com"))
        #expect(plan.notes.contains { $0.hasPrefix("note ANTHROPIC_API_KEY") } == false)
    }

    @Test func proxyMakesAnItemSensitive() throws {
        let plan = try VarlockSchema.plan("""
            # @defaultSensitive=false
            # ---
            # @public @proxy(domain=api.example.com)
            ACME_KEY=op(op://Eng/Acme/key)
            # @proxy=passthrough
            PASSED=op(op://Eng/Passed/key)
            """).get()
        #expect(plan.secrets.map(\.name) == ["ACME_KEY"])
        #expect(plan.notes.contains("skip PASSED: not sensitive"))
    }

    @Test func proxyValueFormsKeepOrWithholdTheValue() throws {
        let plan = try VarlockSchema.plan("""
            # @sensitive @proxy=passthrough
            PASSED=op(op://Eng/Passed/key)
            # @sensitive @proxy=omit
            OMITTED=op(op://Eng/Omitted/key)
            # @sensitive @proxy
            BARE=op(op://Eng/Bare/key)
            """).get()
        #expect(plan.secrets.map(\.name) == ["PASSED"])
        #expect(plan.secrets.first?.delivery == .environment)
        #expect(plan.notes.contains("skip OMITTED: @proxy=omit withholds it from the agent"))
        #expect(plan.notes.contains("skip BARE: @proxy needs domain=, passthrough, or omit"))
    }

    @Test func proxyDomainsAreStrictHttpsHosts() throws {
        let rejected = [
            "\"*.amazonaws.com\"", "10.0.0.1", "\"[::1]\"", "\"api.example.com:8443\"", "\"https://api.example.com\"",
            "localhost", "\"api.example.com/v1\"", "\"api.example.com.\"", "\"-bad.example.com\"", "\"api.exämple.com\"",
            "$HOST",
        ]
        for domain in rejected {
            let plan = try VarlockSchema.plan("""
                # @proxy(domain=\(domain))
                KEY=op(op://Eng/Key/key)
                """).get()
            #expect(plan.secrets.isEmpty, "\(domain) should not import")
            #expect(plan.notes.count == 1)
            #expect(plan.notes.first?.contains("api.example") == false, "a rejected domain is never echoed")
        }
    }

    @Test func proxyKeepsTheFirstDomainAndNotesWhatRvDrops() throws {
        let plan = try VarlockSchema.plan("""
            # @proxy(domain=[api.a.example, api.b.example], path="/v1/**", method=POST)
            # @proxy(domain=api.c.example)
            # @placeholder=ak_test_000 @type=string(startsWith="ak.", endsWith=_x)
            ACME_KEY=op(op://Eng/Acme/key)
            """).get()
        let secret = try #require(plan.secrets.first)
        #expect(secret.delivery == Self.gateway("https://api.a.example", "ACME_KEY_BASE_URL"))
        #expect(plan.notes.contains("note ACME_KEY: rv sends to api.a.example only; 2 more @proxy domains are not carried over"))
        #expect(plan.notes.contains("note ACME_KEY: @proxy options method, path are not carried over; the gateway allows any method and path"))
        #expect(plan.notes.contains("note ACME_KEY: @placeholder is not carried over; rv makes a fresh placeholder each launch"))
        #expect(plan.notes.contains("note ACME_KEY: @type startsWith is not a usable placeholder prefix (up to 32 of A-Z a-z 0-9 _ -)"))
        #expect(plan.notes.contains("note ACME_KEY: @type endsWith/isLength do not shape rv's placeholder"))
    }
}

extension Result where Failure == VarlockSchemaError {
    fileprivate var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}
