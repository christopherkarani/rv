import Foundation

/// A parsed JSON value that keeps booleans, integers and other numbers
/// apart on every platform (`JSONSerialization` folds them into
/// `NSNumber`, and Linux and Darwin fold them differently).
indirect enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var integer: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }
}

/// The JSON Schema subset the OCSF schema server's class exports use:
/// `$ref` into `$defs`, `type`, `properties`, `additionalProperties`
/// (boolean), `required`, `enum`, `const`, `items` and `anyOf` (OCSF's
/// "at least one of" constraints). Anything else in a schema fails the
/// check, so a refreshed export that needs more keywords cannot pass
/// silently.
struct OCSFSchemaValidator {
    struct Violation: Equatable, CustomStringConvertible {
        var path: String
        var message: String
        var description: String { "\(path): \(message)" }
    }

    static let version = "1.3.0"
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ocsf-\(version)", isDirectory: true)

    static let understoodKeywords: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "title", "type", "properties", "additionalProperties", "required",
        "enum", "const", "items", "anyOf",
    ]

    /// Every vendored schema, keyed by its file stem
    /// (`<class>@<profile>+<profile>`, profiles sorted).
    let schemas: [String: JSONValue]

    init(directory: URL = Self.directory) throws {
        var schemas: [String: JSONValue] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            schemas[file.deletingPathExtension().lastPathComponent] = try JSONValue.parse(text)
        }
        self.schemas = schemas
    }

    /// The vendored schema for this event's class and declared profiles.
    func schema(for event: JSONValue) -> (stem: String, schema: JSONValue)? {
        guard let classUID = event["class_uid"]?.integer else { return nil }
        var profiles: [String] = []
        if case .array(let items)? = event["metadata"]?["profiles"] {
            profiles = items.compactMap(\.string).sorted()
        }
        for (stem, schema) in schemas where schema["properties"]?["class_uid"]?["const"]?.integer == classUID {
            let parts = stem.split(separator: "@", maxSplits: 1)
            let declared = parts.count == 2 ? parts[1].split(separator: "+").map(String.init) : []
            if declared == profiles { return (stem, schema) }
        }
        return nil
    }

    /// All violations of `event` against its schema, plus the OCSF rules a
    /// JSON Schema cannot state: the version, and `type_uid` being
    /// `class_uid * 100 + activity_id`.
    func validate(_ event: JSONValue) -> [Violation] {
        var violations: [Violation] = []
        if event["metadata"]?["version"]?.string != Self.version {
            violations.append(Violation(path: "/metadata/version", message: "is not \(Self.version)"))
        }
        guard let (stem, schema) = schema(for: event) else {
            let classUID = event["class_uid"]?.integer.map(String.init) ?? "none"
            violations.append(Violation(
                path: "/class_uid",
                message: "no vendored OCSF \(Self.version) schema for class_uid \(classUID) with the declared profiles"))
            return violations
        }
        if let classUID = event["class_uid"]?.integer, let activity = event["activity_id"]?.integer,
            event["type_uid"]?.integer != classUID * 100 + activity
        {
            violations.append(Violation(path: "/type_uid", message: "is not class_uid * 100 + activity_id"))
        }
        check(event, against: schema, root: schema, path: "", into: &violations)
        return violations.map { Violation(path: $0.path, message: "\($0.message) [\(stem)]") }
    }

    private func check(
        _ value: JSONValue, against schema: JSONValue, root: JSONValue, path: String, into violations: inout [Violation]
    ) {
        guard case .object(let rules) = schema else {
            violations.append(Violation(path: path, message: "schema node is not an object"))
            return
        }
        for keyword in rules.keys where Self.understoodKeywords.contains(keyword) == false {
            violations.append(Violation(path: path, message: "schema keyword \(keyword) is not supported"))
        }
        if let reference = rules["$ref"]?.string {
            let prefix = "#/$defs/"
            guard reference.hasPrefix(prefix), let target = root["$defs"]?[String(reference.dropFirst(prefix.count))]
            else {
                violations.append(Violation(path: path, message: "unresolvable $ref \(reference)"))
                return
            }
            check(value, against: target, root: root, path: path, into: &violations)
        }
        if let type = rules["type"]?.string, Self.matches(value, type: type) == false {
            violations.append(Violation(path: path, message: "is not of type \(type)"))
            return
        }
        if let constant = rules["const"], constant != value {
            violations.append(Violation(path: path, message: "is not the constant the class requires"))
        }
        if case .array(let allowed)? = rules["enum"], allowed.contains(value) == false {
            violations.append(Violation(path: path, message: "is not one of the enumerated values"))
        }
        if case .array(let branches)? = rules["anyOf"] {
            let passing = branches.contains { branch in
                var scratch: [Violation] = []
                check(value, against: branch, root: root, path: path, into: &scratch)
                return scratch.isEmpty
            }
            if passing == false {
                violations.append(Violation(path: path, message: "satisfies none of the anyOf branches"))
            }
        }
        switch value {
        case .object(let fields):
            if case .array(let required)? = rules["required"] {
                for name in required.compactMap(\.string) where fields[name] == nil {
                    violations.append(Violation(path: path + "/" + name, message: "is required"))
                }
            }
            let properties: [String: JSONValue]
            if case .object(let declared)? = rules["properties"] { properties = declared } else { properties = [:] }
            for (name, field) in fields {
                if let property = properties[name] {
                    check(field, against: property, root: root, path: path + "/" + name, into: &violations)
                } else if rules["additionalProperties"] == .bool(false) {
                    violations.append(Violation(path: path + "/" + name, message: "is not defined by the schema"))
                }
            }
        case .array(let items):
            if let item = rules["items"] {
                for (index, element) in items.enumerated() {
                    check(element, against: item, root: root, path: path + "/\(index)", into: &violations)
                }
            }
        default:
            break
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("integer", .integer),
            ("number", .integer), ("number", .number), ("null", .null):
            return true
        default:
            return false
        }
    }
}
