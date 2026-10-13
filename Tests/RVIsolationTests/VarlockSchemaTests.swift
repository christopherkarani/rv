import Foundation
import Testing
@testable import RVIsolation

@Suite("Varlock schema import")
struct VarlockSchemaTests {
    private static let schema = """
        # @plugin(@varlock/infisical-plugin)
        # @initInfisical(projectId=proj, environment=dev, path=/)
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
        NAMED=infisical("STRIPE_SECRET_KEY", secretPath="/billing")

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
        TOKEN=vaultSecret("secret/data/app", field="token")

        # @sensitive
        AWS=awsSecretsManager("prod/thing", field="key", region=us-east-1)

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
            name: "STRIPE_SECRET_KEY", project: "proj", environment: "dev", path: "/billing"))
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

    @Test func roundTripsTheNewSourceKinds() throws {
        let secret = SecretDefinition(
            name: "DB", description: "database", source: .azure(vault: "my-vault", name: "db", version: nil),
            delivery: .environment, type: "string")
        let decoded = try SecretsConfiguration.decode(SecretsConfiguration(secrets: [secret]).encoded()).get()
        #expect(decoded.secrets == [secret])
    }
}
