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
            # -----END"
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
}

extension Result where Failure == VarlockSchemaError {
    fileprivate var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}
