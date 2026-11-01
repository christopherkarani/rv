import Foundation

/// One `.env.schema` turned into rv secret definitions. Literal values are
/// never copied. Only sensitive items with a provider reference are imported;
/// everything else is a note.
public struct VarlockImportPlan: Sendable, Equatable {
    public var secrets: [SecretDefinition] = []
    public var notes: [String] = []
}

public struct VarlockSchemaError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum VarlockSchema {
    public static let maximumBytes = 1024 * 1024

    public static func plan(_ text: String) -> Result<VarlockImportPlan, VarlockSchemaError> {
        guard text.utf8.count <= maximumBytes else {
            return .failure(VarlockSchemaError("schema is larger than 1 MiB"))
        }
        guard text.utf8.allSatisfy({ $0 != 0 }) else {
            return .failure(VarlockSchemaError("schema contains NUL"))
        }
        let document: Document
        switch parse(text) {
        case .success(let parsed): document = parsed
        case .failure(let error): return .failure(error)
        }
        for item in document.items {
            if let repeated = repeatedDecorator(item) {
                return .failure(VarlockSchemaError("\(item.name): decorator @\(repeated) is used twice"))
            }
        }
        switch document.disable {
        case .no: break
        case .yes: return .success(VarlockImportPlan(notes: ["schema is turned off by @disable; nothing imported"]))
        case .conditional:
            return .success(VarlockImportPlan(notes: ["schema has a conditional @disable rv cannot evaluate; nothing imported"]))
        }
        var plan = VarlockImportPlan()
        var seen = Set<String>()
        var exported = Set<String>()
        for item in document.items {
            guard seen.insert(item.name).inserted else {
                plan.notes.append("skip \(item.name): named more than once; kept the first")
                continue
            }
            switch definition(item, inits: document.inits, defaultSensitive: document.defaultSensitive) {
            case .skip(let reason): plan.notes.append("skip \(item.name): \(reason)")
            case .secret(let secret, let notes):
                // secrets.json refuses two secrets setting one variable.
                if let taken = secret.exportedVariables.first(where: exported.contains) {
                    plan.notes.append("skip \(item.name): another imported secret already sets $\(taken)")
                    continue
                }
                exported.formUnion(secret.exportedVariables)
                plan.secrets.append(secret)
                plan.notes += notes.map { "note \(item.name): \($0)" }
            }
        }
        return .success(plan)
    }

    /// Varlock rejects a value decorator used twice on one item
    /// (config-item.ts:332-345); call forms such as `@docs(...)` may repeat.
    private static func repeatedDecorator(_ item: Item) -> String? {
        var seen = Set<String>()
        return item.decorators.first { decorator in
            if case .call = decorator.form { return false }
            return seen.insert(decorator.name).inserted == false
        }?.name
    }

    private typealias Decorator = EnvSpec.Decorator

    private struct Item {
        var name: String
        var value: EnvSpec.Value?
        /// Pre-comment decorators, then post-comment ones (`KEY=v # @sensitive`).
        var decorators: [Decorator]
        var description: String?
    }

    /// One `@initX(...)` provider instance.
    private struct Init {
        var decorator: String
        var id: String?
        var fields: [String: String]
        /// Fields set to a `$REF` or a call, which Varlock resolves at load time and rv cannot.
        var references: Set<String>

        func has(_ key: String) -> Bool { fields[key] != nil || references.contains(key) }

        /// A literal field. A reference is never taken as its own text.
        func literal(_ key: String) throws(Skip) -> String? {
            guard references.contains(key) == false else {
                throw Skip("@\(decorator) \(key) is a reference rv cannot resolve")
            }
            return fields[key]
        }
    }

    private struct Document {
        var inits: [String: [Init]] = [:]
        var defaultSensitive: Sensitivity = .all
        var disable: Disable = .no
        var items: [Item] = []
    }

    /// Root `@disable` turns the whole file off in Varlock (data-source.ts:341-359).
    private enum Disable {
        case no
        case yes
        case conditional
    }

    private enum Sensitivity {
        case all
        case none
        case unlessPrefix(String)
    }

    private enum Mapped {
        case secret(SecretDefinition, notes: [String])
        case skip(String)
    }

    /// Why an item is not imported. Names schema fields, never values.
    private struct Skip: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private struct Resolved {
        var source: SecretSource
        var notes: [String] = []
    }

    private static let unsupported = Skip("no supported provider reference")

    /// A provider reference that an item's value names.
    private enum Reference {
        case onePassword(String)
        case call(Call)
    }

    /// Every comment block before the first item is header (Varlock
    /// classes.ts:497-528). Root decorators on the first item count too.
    private static func parse(_ text: String) -> Result<Document, VarlockSchemaError> {
        let file: EnvSpec.File
        switch EnvSpec.parse(text) {
        case .success(let parsed): file = parsed
        case .failure(let error): return .failure(VarlockSchemaError("line \(error.line) is not valid .env.schema syntax"))
        }
        var document = Document()
        for node in file.nodes {
            switch node {
            case .block(let comments) where document.items.isEmpty:
                apply(decorators(comments), to: &document)
            case .item(let item):
                var found = decorators(item.preComments + [item.postComment].compactMap { $0 })
                if document.items.isEmpty {
                    apply(found.filter { rootDecorator($0.name) }, to: &document)
                    found.removeAll { rootDecorator($0.name) }
                }
                document.items.append(Item(
                    name: item.key, value: item.value, decorators: found, description: description(item.preComments)))
            default:
                break
            }
        }
        return .success(document)
    }

    private static func decorators(_ comments: [EnvSpec.Comment]) -> [Decorator] {
        comments.flatMap { comment -> [Decorator] in
            if case .decorators(let found) = comment { found } else { [] }
        }
    }

    private static func description(_ comments: [EnvSpec.Comment]) -> String? {
        var lines: [String] = []
        for case .text(let comment) in comments {
            if let value = commentedOutValue(comment) {
                if valueContinues(value) { break }
                continue
            }
            lines.append(comment.trimmingCharacters(in: .whitespaces))
        }
        let prose = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return prose.isEmpty ? nil : prose
    }

    /// The value of a commented-out item, matching Varlock's
    /// `^[#\s]*(?:export\s+)?[a-zA-Z_][a-zA-Z0-9_.-]*\s*=`, or nil.
    private static func commentedOutValue(_ body: String) -> Substring? {
        var rest = Substring(body).drop { $0 == "#" || $0.isWhitespace }
        if rest.hasPrefix("export"), rest.dropFirst(6).first?.isWhitespace == true {
            rest = rest.dropFirst(6).drop(while: \.isWhitespace)
        }
        guard let first = rest.first, first.isASCII, first.isLetter || first == "_" else { return nil }
        let key = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
        let after = rest.dropFirst(key.count).drop(while: \.isWhitespace)
        guard after.first == "=" else { return nil }
        return after.dropFirst().drop(while: \.isWhitespace)
    }

    /// Whether a commented-out value opens a quote, literal, or call that does
    /// not close on its own line (Varlock `commentedOutValueContinues`).
    private static func valueContinues(_ value: Substring) -> Bool {
        guard let first = value.first else { return false }
        let opensCall = (first.isLetter || first == "_")
            && value.drop { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.first == "("
        guard "\"'`[{".contains(first) || opensCall else { return false }
        guard let end = closingIndex(value) else { return true }
        let rest = value[end...].drop(while: \.isWhitespace)
        return rest.isEmpty == false && rest.first != "#"
    }

    /// The index just past the quoted string or balanced brackets that start
    /// `value`, or nil when they do not close.
    private static func closingIndex(_ value: Substring) -> Substring.Index? {
        if let quote = value.first, "\"'`".contains(quote) {
            let triple = String(repeating: quote, count: 3)
            let fence = quote != "'" && value.hasPrefix(triple) ? triple : String(quote)
            var cursor = value.index(value.startIndex, offsetBy: fence.count)
            while cursor < value.endIndex {
                if value[cursor] == "\\" {
                    cursor = value.index(cursor, offsetBy: 2, limitedBy: value.endIndex) ?? value.endIndex
                    continue
                }
                if value[cursor...].hasPrefix(fence) { return value.index(cursor, offsetBy: fence.count) }
                cursor = value.index(after: cursor)
            }
            return nil
        }
        var depth = 0
        var quote: Character?
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let character = value[cursor]
            cursor = value.index(after: cursor)
            if let open = quote {
                if character == open { quote = nil }
            } else if "\"'`".contains(character) {
                quote = character
            } else if "([{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }

    private static func rootDecorator(_ name: String) -> Bool {
        [
            "defaultSensitive", "disable", "plugin", "initInfisical", "initGsm", "initAzure", "initBitwarden", "initAws",
            "initHcpVault", "initOp",
        ].contains(name)
    }

    private static func apply(_ found: [Decorator], to document: inout Document) {
        for decorator in found {
            switch decorator.name {
            case "defaultSensitive":
                document.defaultSensitive = sensitivity(decorator)
            case "disable":
                document.disable = switch flag(decorator) {
                case true?: .yes
                case false?: .no
                case nil: .conditional
                }
            case "initInfisical", "initGsm", "initAzure", "initBitwarden", "initAws", "initHcpVault", "initOp":
                let fields = if case .call(let found) = decorator.form { arguments(found) } else { Arguments() }
                document.inits[decorator.name, default: []].append(Init(
                    decorator: decorator.name, id: fields.named["id"], fields: fields.named,
                    references: fields.references))
            default:
                break
            }
        }
    }

    private static func sensitivity(_ decorator: Decorator) -> Sensitivity {
        if flag(decorator) == false { return .none }
        if case .value(.call("inferFromPrefix", let found)) = decorator.form,
            let prefix = found.first.flatMap({ literal($0.value) })
        {
            return .unlessPrefix(prefix)
        }
        return .all
    }

    /// `@name`, `@name=true`, or `@name=false`; nil for a form rv cannot
    /// evaluate. A quoted `"false"` is a non-empty string, so it is nil too.
    private static func flag(_ decorator: Decorator) -> Bool? {
        switch decorator.form {
        case .flag, .value(.text("true", quote: nil)): true
        case .value(.text("false", quote: nil)): false
        default: nil
        }
    }

    private static func definition(_ item: Item, inits: [String: [Init]], defaultSensitive: Sensitivity) -> Mapped {
        guard SecretsConfiguration.isVariableName(item.name),
            SecretsDecoding.reservedVariables.contains(item.name) == false
        else { return .skip("not an environment variable name") }
        guard isSensitive(item, defaultSensitive: defaultSensitive) else { return .skip("not sensitive") }
        var type = item.decorators.last { $0.name == "type" }.flatMap { decorator -> String? in
            if case .value(let value) = decorator.form { render(value) } else { nil }
        }
        var notes: [String] = []
        // secrets.json holds a short single-line type; one that does not fit
        // is dropped rather than failing the whole import on write.
        if let text = type, SecretsDecoding.label(text, max: 128) == false {
            type = nil
            notes.append("@type is not stored: longer than 128 bytes or not single-line text")
        }
        let description = item.description.flatMap { clipped($0, max: 256) }
        guard let value = item.value else { return .skip("no provider reference") }
        guard let target = reference(value) else { return .skip("literal value not copied") }
        do {
            let resolved = try source(item, target, inits: inits)
            let routed = try delivery(item)
            return .secret(
                SecretDefinition(
                    name: item.name, description: description, source: resolved.source, delivery: routed.delivery,
                    type: type),
                notes: notes + resolved.notes + routed.notes + [droppedSensitiveOptions(item)].compactMap { $0 })
        } catch {
            return .skip(error.reason)
        }
    }

    /// A provider reference, or nil for a literal. `KEY = op(...)` parses as
    /// text because a call cannot follow a space; Varlock then rejects it as
    /// a malformed call, and rv reads it as the call.
    private static func reference(_ value: EnvSpec.Value) -> Reference? {
        switch value {
        case .text(let text, quote: nil) where text.hasPrefix("op://"): .onePassword(text)
        case .text(let text, quote: nil): EnvSpec.functionCall(text).flatMap(reference)
        case .call(let name, let found): .call(Call(name: name, arguments: arguments(found)))
        default: nil
        }
    }

    /// A literal value is never a provider reference, so it is not imported.
    /// Calls follow each Varlock plugin's resolver `process()`.
    private static func source(_ item: Item, _ reference: Reference, inits: [String: [Init]]) throws(Skip) -> Resolved {
        let call: Call
        switch reference {
        case .onePassword(let text):
            guard let resolved = onePassword(text) else { throw unsupported }
            return Resolved(source: resolved)
        case .call(let found):
            call = found
        }
        guard call.arguments.hasReference == false else { throw Skip("an argument is a reference rv cannot resolve") }
        let declared = inits[initName(call.name)] ?? []
        switch call.name {
        case "op": return try op(call, declared)
        case "infisical": return try infisical(item, call, declared)
        case "bitwarden":
            guard let id = try instance(call, declared, maximum: 2).rest.first, SecretsDecoding.uuid(id) else {
                throw unsupported
            }
            return Resolved(source: .bitwarden(id: id.lowercased()))
        case "gsm":
            let (config, rest) = try instance(call, declared, maximum: 2)
            let reference = rest.first ?? item.name
            let project = if reference.hasPrefix("projects/") { nil as String? } else { try config?.literal("projectId") }
            guard let resolved = gcp(reference, project: project) else { throw unsupported }
            return Resolved(source: resolved)
        case "azureSecret": return try azureSecret(item, call, declared)
        case "vaultSecret": return try vaultSecret(item, call, declared)
        case "awsSecret": return try awsSecret(item, call, declared)
        case "awsParam": throw Skip("rv has no AWS Parameter Store provider")
        default: throw unsupported
        }
    }

    private static func initName(_ call: String) -> String {
        switch call {
        case "op": "initOp"
        case "infisical": "initInfisical"
        case "gsm": "initGsm"
        case "azureSecret": "initAzure"
        case "bitwarden": "initBitwarden"
        case "vaultSecret": "initHcpVault"
        case "awsSecret": "initAws"
        default: ""
        }
    }

    /// Splits off Varlock's leading instance id: with more than one positional,
    /// the first names an `@initX(id=...)`. Otherwise the instance is the one
    /// declared without an id. A mistyped id is skipped, never rebound as a name.
    private static func instance(
        _ call: Call, _ declared: [Init], maximum: Int
    ) throws(Skip) -> (config: Init?, rest: [String]) {
        let positional = call.arguments.positional
        guard positional.count <= maximum else { throw Skip("\(call.name)() takes at most \(maximum) arguments") }
        guard positional.count > 1 else {
            let config = declared.first { $0.id == nil }
            if config == nil, declared.isEmpty == false {
                throw Skip("no @\(initName(call.name)) without an id; name the instance")
            }
            return (config, positional)
        }
        guard let config = declared.first(where: { $0.id == positional[0] }) else {
            throw Skip("instance \(positional[0]) is not one of the declared instances")
        }
        return (config, Array(positional.dropFirst()))
    }

    /// `op(ref)` or `op(id, ref)`. rv runs `op read`, which has no account
    /// selector, so a declared account is reported rather than dropped silently.
    private static func op(_ call: Call, _ declared: [Init]) throws(Skip) -> Resolved {
        let positional = call.arguments.positional
        guard let resolved = positional.first(where: { $0.hasPrefix("op://") }).flatMap(onePassword) else {
            throw unsupported
        }
        let id = positional.count > 1 ? positional[0] : nil
        guard declared.first(where: { $0.id == id })?.has("account") == true else { return Resolved(source: resolved) }
        return Resolved(source: resolved, notes: ["@initOp account is not carried over; `op read` uses OP_ACCOUNT"])
    }

    /// `infisical()`, `infisical(name)`, `infisical(id, name)`, or
    /// `infisical(id, name, path)`. Varlock reads a static first argument of
    /// two as an instance id; its `(name, path)` form needs a `$REF` name.
    private static func infisical(_ item: Item, _ call: Call, _ declared: [Init]) throws(Skip) -> Resolved {
        let (config, rest) = try instance(call, declared, maximum: 3)
        let name = rest.first ?? item.name
        let path = try rest.count > 1 ? rest[1] : config?.literal("secretPath")
        let project = try config?.literal("projectId")
        let environment = try config?.literal("environment")
        guard SecretsDecoding.cliToken(name),
            [project, environment, path].allSatisfy({ $0.map(SecretsDecoding.cliToken) ?? true })
        else { throw unsupported }
        return Resolved(source: .infisical(name: name, project: project, environment: environment, path: path))
    }

    /// `azureSecret(name[@version])` with named `version=` and `key=`. rv's
    /// Azure source returns the whole value, so a JSON key is not imported.
    private static func azureSecret(_ item: Item, _ call: Call, _ declared: [Init]) throws(Skip) -> Resolved {
        let (config, rest) = try instance(call, declared, maximum: 2)
        var reference = rest.first ?? kebab(item.name)
        guard reference.contains("#") == false, call.arguments.named["key"] == nil else {
            throw Skip("rv's Azure source cannot pick a JSON key")
        }
        if let version = call.arguments.named["version"] {
            reference = String(reference.prefix { $0 != "@" }) + "@" + version
        }
        guard let resolved = azure(reference, vaultURL: try config?.literal("vaultUrl")) else { throw unsupported }
        return Resolved(source: resolved)
    }

    /// `vaultSecret([id,] [path[#KEY]], key=)` against KV v2. The key defaults
    /// to the item name and the path to `@initHcpVault(defaultPath=)`.
    private static func vaultSecret(_ item: Item, _ call: Call, _ declared: [Init]) throws(Skip) -> Resolved {
        let (config, rest) = try instance(call, declared, maximum: 2)
        guard call.arguments.named["raw"] == nil else { throw Skip("raw=true reads a whole secret; rv reads one key") }
        guard config?.has("namespace") != true else { throw Skip("@initHcpVault namespace has no rv equivalent") }
        var path = rest.first ?? ""
        var key = item.name
        if let hash = path.firstIndex(of: "#") {
            let explicit = String(path[path.index(after: hash)...])
            if explicit.isEmpty == false { key = explicit }
            path = String(path[..<hash])
        }
        if let named = call.arguments.named["key"] { key = named }
        if path.isEmpty { path = try config?.literal("defaultPath") ?? "" }
        if let prefix = try config?.literal("pathPrefix") {
            path = String(prefix.reversed().drop { $0 == "/" }.reversed()) + "/" + path.drop { $0 == "/" }
        }
        // Varlock reads KV v2 `mount/rest` at `/v1/mount/data/rest`; rv's path is the API path.
        let mount = path.prefix { $0 != "/" }
        let apiPath = String(mount) + "/data" + path.dropFirst(mount.count)
        guard SecretsDecoding.vaultPath(apiPath), SecretsDecoding.label(key, max: 128) else { throw unsupported }
        var notes: [String] = []
        var address: URL?
        if config?.references.contains("url") == true {
            notes.append("@initHcpVault url is a reference; rv reads VAULT_ADDR")
        } else if let url = config?.fields["url"] {
            guard let origin = SecretsDecoding.httpsOrigin(url) else {
                throw Skip("@initHcpVault url is not an https origin")
            }
            address = origin
        }
        return Resolved(source: .vault(path: apiPath, field: key, address: address), notes: notes)
    }

    /// `awsSecret([id,] [secretId[#key]], key=)`, with `namePrefix` and
    /// `region` from `@initAws`. The id defaults to the item name.
    private static func awsSecret(_ item: Item, _ call: Call, _ declared: [Init]) throws(Skip) -> Resolved {
        let (config, rest) = try instance(call, declared, maximum: 2)
        guard config?.has("profile") != true else { throw Skip("@initAws profile has no rv equivalent") }
        var id = rest.first ?? item.name
        var field: String?
        if let hash = id.firstIndex(of: "#") {
            field = String(id[id.index(after: hash)...])
            id = String(id[..<hash])
        }
        if let named = call.arguments.named["key"] { field = named }
        if field?.isEmpty == true { field = nil }
        id = try (config?.literal("namePrefix") ?? "") + id
        guard SecretsDecoding.cliToken(id), field.map({ SecretsDecoding.label($0, max: 128) }) ?? true else {
            throw unsupported
        }
        var notes: [String] = []
        var region: String?
        if config?.references.contains("region") == true {
            notes.append("@initAws region is a reference; the AWS CLI picks the region")
        } else if let text = config?.fields["region"] {
            guard SecretsDecoding.regionName(text) else { throw Skip("@initAws region is not a region name") }
            region = text
        }
        return Resolved(source: .awsSecretsManager(secretID: id, field: field, region: region), notes: notes)
    }

    private static func onePassword(_ reference: String) -> SecretSource? {
        guard reference.hasPrefix("op://"), SecretsDecoding.label(reference, max: 512), reference.contains(" ") == false
        else { return nil }
        return .onePassword(reference: reference)
    }

    private static func gcp(_ reference: String, project defaultProject: String?) -> SecretSource? {
        if reference.hasPrefix("projects/") {
            let parts = reference.split(separator: "/").map(String.init)
            guard parts.count == 6, parts[0] == "projects", parts[2] == "secrets", parts[4] == "versions",
                SecretsDecoding.cliToken(parts[1]), SecretsDecoding.cliToken(parts[3]), SecretsDecoding.cliToken(parts[5])
            else { return nil }
            return .gcp(secret: parts[3], project: parts[1], version: parts[5])
        }
        let pieces = reference.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = pieces.first, SecretsDecoding.cliToken(name) else { return nil }
        let version = pieces.count == 2 ? pieces[1] : "latest"
        guard SecretsDecoding.cliToken(version) else { return nil }
        return .gcp(secret: name, project: defaultProject, version: version)
    }

    private static func azure(_ reference: String, vaultURL: String?) -> SecretSource? {
        guard let vaultURL, let host = URL(string: vaultURL)?.host else { return nil }
        let vault = host.split(separator: ".").first.map(String.init) ?? ""
        let pieces = reference.split(separator: "@", maxSplits: 1).map(String.init)
        guard SecretsDecoding.cliToken(vault), let name = pieces.first, SecretsDecoding.cliToken(name) else { return nil }
        let version = pieces.count == 2 ? pieces[1] : nil
        guard version == nil || SecretsDecoding.cliToken(version ?? "") else { return nil }
        return .azure(vault: vault, name: name, version: version)
    }

    private static func kebab(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Item-attached `@proxy(domain=...)` (decorators.ts:1063-1085) becomes
    /// gateway delivery: the agent holds a placeholder and rv sends the value
    /// only to that host. `@proxy=passthrough` and no `@proxy` stay
    /// environment delivery; `@proxy=omit` keeps the value from the agent.
    private static func delivery(_ item: Item) throws(Skip) -> (delivery: SecretDelivery, notes: [String]) {
        var rules: [[EnvSpec.Argument]] = []
        var passthrough = false
        for decorator in item.decorators where decorator.name == "proxy" {
            switch decorator.form {
            case .call(let arguments): rules.append(arguments)
            case .value(let value) where literal(value) == "passthrough": passthrough = true
            case .value(let value) where literal(value) == "omit": throw Skip("@proxy=omit withholds it from the agent")
            default: throw Skip("@proxy needs domain=, passthrough, or omit")
            }
        }
        guard rules.isEmpty == false else { return (.environment, []) }
        guard passthrough == false else { throw Skip("@proxy cannot both route and pass through") }
        var domains: [String] = []
        var dropped = Set<String>()
        for arguments in rules {
            for argument in arguments {
                guard argument.key == "domain" else {
                    dropped.insert(argument.key ?? "positional")
                    continue
                }
                let values = if case .array(let list) = argument.value { list } else { [argument.value] }
                for value in values {
                    guard let text = literal(value) else { throw Skip("@proxy domain is a reference rv cannot resolve") }
                    domains.append(text)
                }
            }
        }
        // Rejected text is never echoed: it comes from the repo, not the user.
        guard let first = domains.first else { throw Skip("@proxy has no domain") }
        guard let host = proxyHost(first) else {
            throw Skip("@proxy domain is not a plain DNS host (no wildcard, IP, port, scheme, or path)")
        }
        let known = KnownSecretDefaults.gateway(for: item.name)
        let curated = known.flatMap { URL(string: $0.upstream)?.host == host ? $0.upstream : nil }
        let baseURLEnv = known?.baseURLEnv ?? item.name + "_BASE_URL"
        guard let upstream = SecretsDecoding.httpsUpstream(curated ?? "https://" + host),
            SecretsDecoding.variable(baseURLEnv)
        else { throw Skip("name is too long for a gateway base-URL variable") }
        var notes: [String] = []
        var prefix = known?.placeholderPrefix ?? ""
        if known == nil {
            notes.append("point the client at $\(baseURLEnv); rv sends the value only to \(host)")
        }
        if domains.count > 1 {
            notes.append("rv sends to \(host) only; \(domains.count - 1) more @proxy domain\(domains.count == 2 ? " is" : "s are") not carried over")
        }
        if dropped.isEmpty == false {
            notes.append(
                "@proxy options \(dropped.sorted().joined(separator: ", ")) are not carried over; the gateway allows any method and path")
        }
        if item.decorators.contains(where: { $0.name == "placeholder" }) {
            notes.append("@placeholder is not carried over; rv makes a fresh placeholder each launch")
        }
        if let startsWith = typeOption(item, "startsWith"), startsWith.isEmpty == false {
            if startsWith.utf8.count <= 32, startsWith.utf8.allSatisfy(SecretsDecoding.placeholderByte) {
                prefix = startsWith
            } else {
                notes.append("@type startsWith is not a usable placeholder prefix (up to 32 of A-Z a-z 0-9 _ -)")
            }
        }
        if typeOption(item, "endsWith") != nil || typeOption(item, "isLength") != nil {
            notes.append("@type endsWith/isLength do not shape rv's placeholder")
        }
        return (.gateway(SecretGatewayBinding(upstream: upstream, baseURLEnv: baseURLEnv, placeholderPrefix: prefix)), notes)
    }

    /// A lowercase DNS name of two or more labels. rv binds one https origin,
    /// so wildcards, IP literals, ports, schemes, and paths are refused.
    private static func proxyHost(_ text: String) -> String? {
        let host = text.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
            labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
            }),
            labels.last?.allSatisfy(\.isNumber) == false
        else { return nil }
        return host
    }

    /// A static named option of the item's `@type=kind(...)`, such as `startsWith`.
    private static func typeOption(_ item: Item, _ key: String) -> String? {
        guard let type = item.decorators.last(where: { $0.name == "type" }),
            case .value(.call(_, let arguments)) = type.form
        else { return nil }
        return arguments.first { $0.key == key }.flatMap { literal($0.value) }
    }

    /// The first `@sensitive` or `@public` decides (config-item.ts:724-765);
    /// `@public=false` means sensitive. A value rv cannot evaluate, such as
    /// `forEnv(prod)`, counts as sensitive: importing only hands it to rv.
    private static func isSensitive(_ item: Item, defaultSensitive: Sensitivity) -> Bool {
        // A routed `@proxy(...)` item is always sensitive (config-item.ts:704-717).
        if item.decorators.contains(where: { decorator in
            if case .call = decorator.form { decorator.name == "proxy" } else { false }
        }) {
            return true
        }
        if let explicit = item.decorators.first(where: { $0.name == "sensitive" || $0.name == "public" }) {
            let enabled: Bool? = if case .value(.object(let options)) = explicit.form {
                options.first { $0.key == "enabled" }.flatMap { literal($0.value) } != "false"
            } else {
                flag(explicit)
            }
            guard let enabled else { return true }
            return explicit.name == "public" ? enabled == false : enabled
        }
        switch defaultSensitive {
        case .all: return true
        case .none: return false
        case .unlessPrefix(let prefix): return item.name.hasPrefix(prefix) == false
        }
    }

    /// `@sensitive={...}` options rv has no per-secret field for.
    private static func droppedSensitiveOptions(_ item: Item) -> String? {
        guard let sensitive = item.decorators.first(where: { $0.name == "sensitive" }),
            case .value(.object(let options)) = sensitive.form
        else { return nil }
        let dropped = Set(options.compactMap(\.key)).subtracting(["enabled"]).sorted()
        guard dropped.isEmpty == false else { return nil }
        return "@sensitive options \(dropped.joined(separator: ", ")) are not carried over"
    }

    /// Schema-like text for a value, such as `string(startsWith=sk-)`.
    private static func render(_ value: EnvSpec.Value) -> String {
        switch value {
        case .text(let text, _): text
        case .call(let name, let found): name + "(" + found.map(render).joined(separator: ", ") + ")"
        case .object(let found): "{" + found.map(render).joined(separator: ", ") + "}"
        case .array(let values): "[" + values.map(render).joined(separator: ", ") + "]"
        }
    }

    private static func render(_ argument: EnvSpec.Argument) -> String {
        argument.key.map { $0 + "=" + render(argument.value) } ?? render(argument.value)
    }

    private static func clipped(_ text: String, max: Int) -> String? {
        // The same scalars `SecretsDecoding.label` rejects, so the clipped text always decodes.
        let clean = text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
        guard clean.isEmpty == false else { return nil }
        var bytes = 0
        var kept = String.UnicodeScalarView()
        for scalar in clean {
            let next = bytes + String(scalar).utf8.count
            if next > max { break }
            kept.append(scalar)
            bytes = next
        }
        return kept.isEmpty ? nil : String(kept)
    }

    private struct Arguments {
        var positional: [String] = []
        var named: [String: String] = [:]
        /// Named keys whose value is a reference.
        var references: Set<String> = []
        var hasReference = false
    }

    private struct Call {
        var name: String
        var arguments: Arguments
    }

    private static func arguments(_ found: [EnvSpec.Argument]) -> Arguments {
        var result = Arguments()
        for argument in found {
            let text = literal(argument.value)
            if let key = argument.key {
                if let text { result.named[key] = text } else { result.references.insert(key) }
            } else if let text {
                result.positional.append(text)
            }
            result.hasReference = result.hasReference || text == nil
        }
        return result
    }

    /// The text of a static value, unescaped as Varlock's `unescapedValue`.
    /// A `$REF` expansion, call, or literal is resolved by Varlock at load
    /// time, so it is nil. Single quotes do not expand or unescape.
    private static func literal(_ value: EnvSpec.Value) -> String? {
        guard case .text(let text, let quote) = value else { return nil }
        guard quote != .single else { return text }
        guard text.replacingOccurrences(of: "\\$", with: "").contains("$") == false else { return nil }
        let dollars = text.replacingOccurrences(of: "\\$", with: "$")
        return quote == nil ? dollars : dollars.replacingOccurrences(of: "\\n", with: "\n")
    }
}
