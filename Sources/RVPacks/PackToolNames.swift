import RVDomain

/// Plain tool names for packs, for `rv protect <tool>` (G6, Packs v6b
/// "Name the tool. That's it."): `redis` is `database.redis`, `kubernetes`
/// is `kubernetes.kubectl`. Data only.
///
/// A pack answers to the last part of its id when no other pack shares it
/// (`terraform`, `docker`, `redis`), to its lowercased display name when
/// that is one word (`kubectl`), and to the names in `aliases`. A name two
/// packs share (`aws`: `cloud.aws` and `apigateway.aws`) is in `aliases`
/// or answers to neither. A pack id still works as itself.
public enum PackToolNames {
    /// Names a person says for a tool, where the derived name is missing,
    /// shared or not what people type.
    public static let aliases: [String: String] = [
        "aws": "cloud.aws",
        "gcp": "cloud.gcp",
        "gcloud": "cloud.gcp",
        "google cloud": "cloud.gcp",
        "az": "cloud.azure",
        "kubernetes": "kubernetes.kubectl",
        "k8s": "kubernetes.kubectl",
        "postgres": "database.postgresql",
        "psql": "database.postgresql",
        "mariadb": "database.mysql",
        "mongo": "database.mongodb",
        "mongosh": "database.mongodb",
        "sqlite3": "database.sqlite",
        "valkey": "database.redis",
        "redis-cli": "database.redis",
        "docker compose": "containers.compose",
        "docker-compose": "containers.compose",
        "tofu": "infrastructure.terraform",
        "opentofu": "infrastructure.terraform",
        "github": "platform.github",
        "gh": "platform.github",
        "gitlab": "platform.gitlab",
        "glab": "platform.gitlab",
        "github actions": "cicd.github_actions",
        "gitlab ci": "cicd.gitlab_ci",
        "cloudflare": "dns.cloudflare",
        "wrangler": "cdn.cloudflare_workers",
        "1password": "secrets.onepassword",
        "op": "secrets.onepassword",
        "aws secrets": "secrets.aws_secrets",
        "secrets manager": "secrets.aws_secrets",
        "s3": "storage.s3",
        "git": "core.git",
        "files": "core.filesystem",
        "filesystem": "core.filesystem",
        "disks": "system.disk",
        "disk": "system.disk",
        "npm": "package_managers",
        "pip": "package_managers",
        "packages": "package_managers",
    ]

    /// Every name → pack id, aliases first.
    public static func table(documents: [PackDocument]) -> [String: PackID] {
        var derived: [String: [PackID]] = [:]
        for document in documents {
            var names: Set<String> = []
            if let last = document.id.rawValue.split(separator: ".").last {
                names.insert(String(last).replacingOccurrences(of: "_", with: " "))
            }
            let display = document.name.lowercased()
            if display.contains(" ") == false, display.contains("/") == false { names.insert(display) }
            for name in names { derived[name, default: []].append(document.id) }
        }
        var table: [String: PackID] = [:]
        for (name, ids) in derived where ids.count == 1 { table[name] = ids[0] }
        let known = Set(documents.map(\.id))
        for (name, id) in aliases where known.contains(PackID(rawValue: id)) {
            table[name] = PackID(rawValue: id)
        }
        return table
    }
}
