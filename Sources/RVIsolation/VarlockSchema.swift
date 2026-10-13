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
        var plan = VarlockImportPlan()
        var seen = Set<String>()
        for item in document.items {
            guard seen.insert(item.name).inserted else {
                plan.notes.append("skip \(item.name): named more than once; kept the first")
                continue
            }
            switch definition(item, inits: document.inits, defaultSensitive: document.defaultSensitive) {
            case .skip(let reason): plan.notes.append("skip \(item.name): \(reason)")
            case .secret(let secret): plan.secrets.append(secret)
            }
        }
        return .success(plan)
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

    private struct Init {
        var id: String?
        var fields: [String: String]
    }

    private struct Document {
        var inits: [String: [Init]] = [:]
        var defaultSensitive: Sensitivity = .all
        var items: [Item] = []
    }

    private enum Sensitivity {
        case all
        case none
        case unlessPrefix(String)
    }

    private enum Mapped {
        case secret(SecretDefinition)
        case skip(String)
    }

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
                if pastHeader == false, body == "---" || comments.isEmpty == false {
                    applyHeader(comments, to: &document)
                    comments = []
                    pastHeader = true
                } else {
                    comments = []
                }
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
                let prose = comments.filter { decoratorLine($0) == false }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                document.items.append(Item(
                    name: item.name, value: item.value, decorators: decorators,
                    description: prose.isEmpty ? nil : prose))
                comments = []
            }
            index += 1
        }
        return document
    }

    private static func applyHeader(_ comments: [String], to document: inout Document) {
        apply(comments.filter(decoratorLine).flatMap(decorators(in:)), to: &document)
    }

    private static func rootDecorator(_ name: String) -> Bool {
        ["defaultSensitive", "plugin", "initInfisical", "initGsm", "initAzure", "initBitwarden"].contains(name)
    }

    private static func apply(_ found: [Decorator], to document: inout Document) {
        for decorator in found {
            switch decorator.name {
            case "defaultSensitive":
                document.defaultSensitive = sensitivity(decorator)
            case "initInfisical", "initGsm", "initAzure", "initBitwarden":
                let fields = arguments(decorator.arguments ?? "")
                let id = fields.named["id"]
                document.inits[decorator.name, default: []].append(Init(id: id, fields: fields.named))
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
        let type = item.decorators.last { $0.name == "type" }.flatMap { $0.value ?? $0.arguments }
        let description = item.description.flatMap { clipped($0, max: 256) }
        let value = stripTrailingComment(item.value).trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return .skip("no provider reference") }
        if value.hasPrefix("op://") == false, functionCall(value) == nil {
            return .skip("literal value not copied")
        }
        guard let source = source(item, inits: inits) else {
            return .skip("no supported provider reference")
        }
        return .secret(SecretDefinition(
            name: item.name, description: description, source: source, delivery: .environment, type: type))
    }

    /// A literal value is never a provider reference, so it is not imported.
    private static func source(_ item: Item, inits: [String: [Init]]) -> SecretSource? {
        let value = stripTrailingComment(item.value).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("op://") { return onePassword(value) }
        guard let call = functionCall(value) else { return nil }
        let instance = call.positional.first.flatMap { token in
            inits[initName(call.name)]?.contains { $0.id == token } == true ? token : nil
        }
        let positional = instance == nil ? call.positional : Array(call.positional.dropFirst())
        let chosen = pick(inits[initName(call.name)] ?? [], id: instance)
        switch call.name {
        case "op":
            return positional.first { $0.hasPrefix("op://") }.flatMap(onePassword)
        case "infisical":
            let name = call.named["secretName"] ?? positional.first ?? item.name
            guard SecretsDecoding.cliToken(name) else { return nil }
            return .infisical(
                name: name, project: chosen?["projectId"], environment: chosen?["environment"],
                path: call.named["secretPath"] ?? call.named["path"] ?? chosen?["path"])
        case "bitwarden":
            guard let id = positional.first, SecretsDecoding.uuid(id) else { return nil }
            return .bitwarden(id: id.lowercased())
        case "gsm":
            return gcp(positional.first ?? item.name, project: chosen?["projectId"])
        case "azureSecret":
            return azure(positional.first ?? kebab(item.name), vaultURL: chosen?["vaultUrl"])
        case "vaultSecret":
            guard let path = positional.first, SecretsDecoding.vaultPath(path),
                let field = call.named["field"], SecretsDecoding.label(field, max: 128)
            else { return nil }
            return .vault(path: path, field: field, address: nil)
        case "awsSecretsManager":
            guard let id = positional.first, SecretsDecoding.cliToken(id), id.hasPrefix("-") == false else { return nil }
            let field = call.named["field"]
            guard field == nil || SecretsDecoding.label(field ?? "", max: 128) else { return nil }
            return .awsSecretsManager(secretID: id, field: field, region: call.named["region"])
        default:
            return nil
        }
    }

    private static func initName(_ call: String) -> String {
        switch call {
        case "infisical": "initInfisical"
        case "gsm": "initGsm"
        case "azureSecret": "initAzure"
        case "bitwarden": "initBitwarden"
        default: ""
        }
    }

    private static func pick(_ inits: [Init], id: String?) -> [String: String]? {
        if let id { return inits.first { $0.id == id }?.fields }
        if inits.count == 1 { return inits[0].fields }
        return inits.first { $0.id == nil }?.fields
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

    private static func isSensitive(_ item: Item, defaultSensitive: Sensitivity) -> Bool {
        if let explicit = item.decorators.last(where: { $0.name == "sensitive" || $0.name == "public" }) {
            if explicit.name == "public" { return false }
            return explicit.value != "false"
        }
        switch defaultSensitive {
        case .all: return true
        case .none: return false
        case .unlessPrefix(let prefix): return item.name.hasPrefix(prefix) == false
        }
    }

    private static func clipped(_ text: String, max: Int) -> String? {
        let clean = text.unicodeScalars.filter { $0.properties.generalCategory != .control }
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

    private static func assignment(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[..<eq])
        guard SecretsConfiguration.isVariableName(name) else { return nil }
        return (name, String(trimmed[trimmed.index(after: eq)...]))
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
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
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
    }

    private static func functionCall(_ value: String) -> (name: String, positional: [String], named: [String: String])? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")"), value.startIndex < open else { return nil }
        let name = String(value[..<open])
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), name.isEmpty == false else { return nil }
        let inside = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
        let parsed = arguments(inside)
        return (name, parsed.positional, parsed.named)
    }

    private static func arguments(_ text: String) -> Arguments {
        var result = Arguments()
        for piece in splitArgs(text) {
            let part = piece.trimmingCharacters(in: .whitespaces)
            guard part.isEmpty == false else { continue }
            if let eq = part.firstIndex(of: "="), part[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let key = String(part[..<eq])
                result.named[key] = unquote(String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            } else {
                result.positional.append(unquote(part))
            }
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

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
