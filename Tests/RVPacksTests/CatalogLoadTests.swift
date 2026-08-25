import Foundation
import Testing
import RVDomain
@testable import RVPacks

let frozenPackIDs: Set<String> = [
    "apigateway.apigee", "apigateway.aws", "apigateway.kong",
    "backup.borg", "backup.rclone", "backup.restic", "backup.velero",
    "careful_company_running_windows.chat", "careful_company_running_windows.email",
    "careful_company_running_windows.guardrails", "careful_company_running_windows.transfer",
    "careful_company_running_windows.tunnel", "careful_company_running_windows.upload",
    "cdn.cloudflare_workers", "cdn.cloudfront", "cdn.fastly",
    "cicd.circleci", "cicd.github_actions", "cicd.gitlab_ci", "cicd.jenkins",
    "cloud.aws", "cloud.azure", "cloud.gcp",
    "containers.compose", "containers.docker", "containers.podman",
    "core.filesystem", "core.git",
    "database.bigquery", "database.mongodb", "database.mysql", "database.postgresql",
    "database.redis", "database.snowflake", "database.sqlite", "database.supabase",
    "dns.cloudflare", "dns.generic", "dns.route53",
    "email.mailgun", "email.postmark", "email.sendgrid", "email.ses",
    "featureflags.flipt", "featureflags.launchdarkly", "featureflags.split", "featureflags.unleash",
    "infrastructure.ansible", "infrastructure.atmos", "infrastructure.pulumi", "infrastructure.terraform",
    "kubernetes.helm", "kubernetes.kubectl", "kubernetes.kustomize",
    "loadbalancer.elb", "loadbalancer.haproxy", "loadbalancer.nginx", "loadbalancer.traefik",
    "messaging.kafka", "messaging.nats", "messaging.rabbitmq", "messaging.sqs_sns",
    "monitoring.datadog", "monitoring.newrelic", "monitoring.pagerduty", "monitoring.prometheus",
    "monitoring.splunk",
    "package_managers",
    "payment.braintree", "payment.square", "payment.stripe",
    "platform.github", "platform.gitlab", "platform.kamal", "platform.modal", "platform.railway",
    "remote.rsync", "remote.scp", "remote.ssh",
    "search.algolia", "search.elasticsearch", "search.meilisearch", "search.opensearch",
    "secrets.aws_secrets", "secrets.doppler", "secrets.onepassword", "secrets.vault",
    "storage.azure_blob", "storage.gcs", "storage.minio", "storage.s3",
    "strict_git",
    "system.disk", "system.permissions", "system.services",
]

@Test func catalogLoad_decodesNinetyFivePacksWithoutWindowsOSCatalogs() throws {
    let index = try PackRegistry.loadIndex()
    #expect(index.packCount == 95)
    #expect(index.categories.count == 26)
    #expect(index.categories["windows"] == nil)
    #expect(index.categories["careful_company_running_windows"]?.count == 6)
    #expect(index.presets["careful_company_running_windows"]?.contains("windows.filesystem") == false)
    #expect(index.presets["careful_company_running_windows"]?.count == 26)
    #expect(Set(index.defaultEnabled) == Set(["core.filesystem", "core.git"]))
    #expect(Set(index.packIDs) == frozenPackIDs)

    let documents = try PackRegistry.loadAllDocuments()
    #expect(documents.count == 95)
    #expect(Set(documents.map(\.id.rawValue)) == frozenPackIDs)
}

@Test func catalogLoad_resourcesAreIndexPlusNinetyFive() throws {
    let packsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVPacks/Resources/packs")
    let jsonFiles = try FileManager.default.contentsOfDirectory(
        at: packsDir,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    let names = Set(jsonFiles.map(\.lastPathComponent))
    #expect(names.count == 96)
    #expect(names.contains("index.json"))
    #expect(names.contains("core.git.json"))
    #expect(names.contains("core.filesystem.json"))
}
