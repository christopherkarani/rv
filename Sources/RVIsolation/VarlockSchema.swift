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
        let document = parse(text)
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
        for item in document.items {
            guard seen.insert(item.name).inserted else {
                plan.notes.append("skip \(item.name): named more than once; kept the first")
                continue
            }
            switch definition(item, inits: document.inits, defaultSensitive: document.defaultSensitive) {
            case .skip(let reason): plan.notes.append("skip \(item.name): \(reason)")
            case .secret(let secret, let notes):
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
        return item.decorators.first { $0.arguments == nil && seen.insert($0.name).inserted == false }?.name
    }

    private struct Decorator {
        var name: String
        var value: String?
        var arguments: String?
    }

    private struct Item {
        var name: String
        var value: String
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

    private static func parse(_ text: String) -> Document {
        var document = Document()
        var comments: [String] = []
        var pastHeader = false
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let body = commentBody(raw)
            if let body, decoratorLine(body) {
                var gathered = body
                var depth = parenDepth(body)
                while depth > 0, index + 1 < lines.count, let next = commentBody(lines[index + 1]) {
                    index += 1
                    gathered += next
                    depth = parenDepth(gathered)
                }
                comments.append(gathered)
                index += 1
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || body == "---" {
                // Every comment block before the first item is header
                // (Varlock classes.ts:497-528), not only the first one.
                if pastHeader == false { applyHeader(comments, to: &document) }
                comments = []
                index += 1
                continue
            }
            if let body {
                comments.append(body)
                index += 1
                continue
            }
            if let item = assignment(raw) {
                var decorators = comments.filter(decoratorLine).flatMap(decorators(in:))
                if pastHeader == false {
                    let roots = decorators.filter { rootDecorator($0.name) }
                    apply(roots, to: &document)
                    decorators.removeAll { rootDecorator($0.name) }
                    pastHeader = true
                }
                document.items.append(Item(
                    name: item.name, value: item.value, decorators: decorators,
                    description: description(comments)))
            }
            // A line that is no item still ends its comment block, so its
            // decorators never attach to the next item.
            comments = []
            index += 1
        }
        return document
    }

    /// Prose above an item, minus commented-out items such as `# OLD_KEY=value`,
    /// which often hold real values. One that opens a multi-line value hides
    /// where it ends, so the rest of the block is dropped (Varlock classes.ts:454-468).
    private static func description(_ comments: [String]) -> String? {
        var lines: [String] = []
        for comment in comments where decoratorLine(comment) == false {
            if let value = commentedOutValue(comment) {
                if valueContinues(value) { break }
                continue
            }
            lines.append(comment)
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

    private static func applyHeader(_ comments: [String], to document: inout Document) {
        apply(comments.filter(decoratorLine).flatMap(decorators(in:)), to: &document)
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
                document.disable = switch decorator.value {
                case nil, "true": .yes
                case "false": .no
                default: .conditional
                }
            case "initInfisical", "initGsm", "initAzure", "initBitwarden", "initAws", "initHcpVault", "initOp":
                let fields = arguments(decorator.arguments ?? "")
                document.inits[decorator.name, default: []].append(Init(
                    decorator: decorator.name, id: fields.named["id"], fields: fields.named,
                    references: fields.references))
            default:
                break
            }
        }
    }

    private static func sensitivity(_ decorator: Decorator) -> Sensitivity {
        let raw = decorator.value ?? decorator.arguments ?? "true"
        if raw == "false" { return .none }
        if raw.hasPrefix("inferFromPrefix("), raw.hasSuffix(")") {
            let prefix = String(raw.dropFirst("inferFromPrefix(".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            return .unlessPrefix(prefix)
        }
        return .all
    }

    private static func definition(_ item: Item, inits: [String: [Init]], defaultSensitive: Sensitivity) -> Mapped {
        guard SecretsConfiguration.isVariableName(item.name),
            SecretsDecoding.reservedVariables.contains(item.name) == false
        else { return .skip("not an environment variable name") }
        guard isSensitive(item, defaultSensitive: defaultSensitive) else { return .skip("not sensitive") }
        var type = item.decorators.last { $0.name == "type" }.flatMap { $0.value ?? $0.arguments }
        var notes: [String] = []
        // secrets.json holds a short single-line type; one that does not fit
        // is dropped rather than failing the whole import on write.
        if let text = type, SecretsDecoding.label(text, max: 128) == false {
            type = nil
            notes.append("@type is not stored: longer than 128 bytes or not single-line text")
        }
        let description = item.description.flatMap { clipped($0, max: 256) }
        let value = stripTrailingComment(item.value).trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return .skip("no provider reference") }
        if value.hasPrefix("op://") == false, functionCall(value) == nil {
            return .skip("literal value not copied")
        }
        do {
            let resolved = try source(item, inits: inits)
            return .secret(
                SecretDefinition(
                    name: item.name, description: description, source: resolved.source, delivery: .environment,
                    type: type),
                notes: notes + resolved.notes + [droppedSensitiveOptions(item)].compactMap { $0 })
        } catch {
            return .skip(error.reason)
        }
    }

    /// A literal value is never a provider reference, so it is not imported.
    /// Calls follow each Varlock plugin's resolver `process()`.
    private static func source(_ item: Item, inits: [String: [Init]]) throws(Skip) -> Resolved {
        let value = stripTrailingComment(item.value).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("op://") {
            guard let resolved = onePassword(value) else { throw unsupported }
            return Resolved(source: resolved)
        }
        guard let call = functionCall(value) else { throw unsupported }
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

    /// The first `@sensitive` or `@public` decides (config-item.ts:724-765);
    /// `@public=false` means sensitive. A value rv cannot evaluate, such as
    /// `forEnv(prod)`, counts as sensitive: importing only hands it to rv.
    private static func isSensitive(_ item: Item, defaultSensitive: Sensitivity) -> Bool {
        if let explicit = item.decorators.first(where: { $0.name == "sensitive" || $0.name == "public" }) {
            let flag: Bool? = switch explicit.value {
            case nil, "true": true
            case "false": false
            case let value? where value.hasPrefix("{"): sensitiveOptions(value)["enabled"] != "false"
            default: nil
            }
            guard let flag else { return true }
            return explicit.name == "public" ? flag == false : flag
        }
        switch defaultSensitive {
        case .all: return true
        case .none: return false
        case .unlessPrefix(let prefix): return item.name.hasPrefix(prefix) == false
        }
    }

    /// `@sensitive={...}` options rv has no per-secret field for.
    private static func droppedSensitiveOptions(_ item: Item) -> String? {
        guard let value = item.decorators.first(where: { $0.name == "sensitive" })?.value, value.hasPrefix("{") else {
            return nil
        }
        let dropped = sensitiveOptions(value).keys.filter { $0 != "enabled" }.sorted()
        guard dropped.isEmpty == false else { return nil }
        return "@sensitive options \(dropped.joined(separator: ", ")) are not carried over"
    }

    private static func sensitiveOptions(_ value: String) -> [String: String] {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return [:] }
        return arguments(String(value.dropFirst().dropLast())).named
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

    private static func commentBody(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func decoratorLine(_ body: String) -> Bool {
        body.first == "@"
    }

    private static func parenDepth(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote, character == open { quote = nil; continue }
            if quote != nil { continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
        }
        return depth
    }

    /// `[export ]KEY=value` with Varlock's key grammar `[a-zA-Z_][a-zA-Z0-9_.-]*`
    /// (grammar.peggy:28-45). Keys that are not variable names still parse, so
    /// they keep their own comments; `definition` skips them.
    private static func assignment(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("export "), let exported = assignment(key: trimmed.dropFirst(7)) { return exported }
        return assignment(key: Substring(trimmed))
    }

    private static func assignment(key line: Substring) -> (name: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces)
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        guard let first = name.utf8.first, letter(first),
            name.utf8.allSatisfy({ letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 })
        else { return nil }
        return (name, String(line[line.index(after: eq)...]))
    }

    private static func stripTrailingComment(_ value: String) -> String {
        var quote: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", index > value.startIndex, value[value.index(before: index)] == " " {
                return String(value[..<index])
            }
            index = value.index(after: index)
        }
        return value
    }

    private static func decorators(in line: String) -> [Decorator] {
        var found: [Decorator] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "@" else { index = line.index(after: index); continue }
            let nameStart = line.index(after: index)
            var cursor = nameStart
            while cursor < line.endIndex, line[cursor].isLetter || line[cursor].isNumber { cursor = line.index(after: cursor) }
            let name = String(line[nameStart..<cursor])
            guard name.isEmpty == false else { index = line.index(after: index); continue }
            if cursor < line.endIndex, line[cursor] == "=" {
                let valueStart = line.index(after: cursor)
                let valueEnd = tokenEnd(line, from: valueStart)
                found.append(Decorator(name: name, value: String(line[valueStart..<valueEnd]), arguments: nil))
                index = valueEnd
            } else if cursor < line.endIndex, line[cursor] == "(" {
                let close = matchingParen(line, open: cursor)
                let arguments = String(line[line.index(after: cursor)..<close])
                found.append(Decorator(name: name, value: nil, arguments: arguments))
                index = close < line.endIndex ? line.index(after: close) : close
            } else {
                found.append(Decorator(name: name, value: nil, arguments: nil))
                index = cursor
            }
        }
        return found
    }

    private static func tokenEnd(_ line: String, from start: String.Index) -> String.Index {
        var depth = 0
        var cursor = start
        while cursor < line.endIndex {
            let character = line[cursor]
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth = max(0, depth - 1) }
            if depth == 0, character == " " || character == "@" { break }
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private static func matchingParen(_ line: String, open: String.Index) -> String.Index {
        var depth = 0
        var cursor = open
        var quote: Character?
        while cursor < line.endIndex {
            let character = line[cursor]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = line.index(after: cursor)
        }
        return line.endIndex
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

    private static func functionCall(_ value: String) -> Call? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")"), value.startIndex < open else { return nil }
        let name = String(value[..<open])
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), name.isEmpty == false else { return nil }
        let inside = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
        return Call(name: name, arguments: arguments(inside))
    }

    private static func arguments(_ text: String) -> Arguments {
        var result = Arguments()
        for piece in splitArgs(text) {
            let part = piece.trimmingCharacters(in: .whitespaces)
            guard part.isEmpty == false else { continue }
            if let eq = part.firstIndex(of: "="), part[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let key = String(part[..<eq])
                let raw = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                result.named[key] = unquote(raw)
                if isReference(raw) { result.references.insert(key) }
            } else {
                result.positional.append(unquote(part))
            }
            result.hasReference = result.hasReference || isReference(part)
        }
        return result
    }

    private static func splitArgs(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; current.append(character); continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// `$REF`, `${REF}`, or a nested call such as `fallback(...)`. Single
    /// quotes do not expand in Varlock, so a single-quoted value is literal.
    private static func isReference(_ raw: String) -> Bool {
        guard raw.hasPrefix("'") == false else { return false }
        if raw.contains("$") { return true }
        return raw.hasPrefix("\"") == false && raw.hasPrefix("`") == false && raw.contains("(")
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
