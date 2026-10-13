import Foundation
import RVDomain

public struct ToolArgumentRuleError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// An MCP tool rule that also looks at the call's arguments:
/// `{"tool": "<glob>", "when": {"<JSON pointer>": {"<op>": value, ...}}}`.
/// Every condition must hold. A pointer that resolves to nothing never
/// matches, whatever the operator.
public struct ToolArgumentRule: Sendable, Equatable {
    public enum Operator: String, Sendable, Equatable, CaseIterable {
        case equal = "=="
        case notEqual = "!="
        case less = "<"
        case greater = ">"
        case oneOf = "in"
        case glob
    }

    public struct Condition: Sendable, Equatable {
        public var pointer: String
        public var op: Operator
        public var value: JSONValue

        public init(pointer: String, op: Operator, value: JSONValue) {
            self.pointer = pointer
            self.op = op
            self.value = value
        }
    }

    /// A rule with the decision it carries in a policy list.
    public struct Decided: Sendable, Equatable {
        public var decision: ManagedPolicy.Decision
        public var rule: ToolArgumentRule

        public init(decision: ManagedPolicy.Decision, rule: ToolArgumentRule) {
            self.decision = decision
            self.rule = rule
        }
    }

    public static let maximumConditions = 16
    public static let maximumListItems = 256

    public var tool: String
    /// Sorted by pointer, then operator, so equal rules compare equal.
    public var conditions: [Condition]

    public init(tool: String, conditions: [Condition]) {
        self.tool = tool
        self.conditions = conditions.sorted(by: Self.order)
    }

    public func namesTool(_ name: String) -> Bool {
        ManagedPolicy.glob(tool, name)
    }

    public func matches(tool name: String, arguments: JSONValue) -> Bool {
        namesTool(name) && conditions.allSatisfy { condition in
            guard let actual = Self.resolve(condition.pointer, in: arguments) else { return false }
            return Self.holds(condition.op, actual: actual, expected: condition.value)
        }
    }

    /// The strictest decision among rules that match, or nil when none do.
    public static func strictest(_ rules: [Decided], tool: String, arguments: JSONValue) -> ManagedPolicy.Decision? {
        rules.filter { $0.rule.matches(tool: tool, arguments: arguments) }.map(\.decision).max()
    }

    /// `pay when /amount > 100, /currency in ["usd"]`
    public var summary: String {
        let parts = conditions.map { "\($0.pointer) \($0.op.rawValue) \(Self.text($0.value))" }
        return "\(tool) when " + parts.joined(separator: ", ")
    }

    public var encoded: JSONValue {
        var when: [String: JSONValue] = [:]
        for condition in conditions {
            var ops = when[condition.pointer]?.asObject ?? [:]
            ops[condition.op.rawValue] = condition.value
            when[condition.pointer] = .object(ops)
        }
        return .object(["tool": .string(tool), "when": .object(when)])
    }

    public static func decode(_ value: JSONValue) throws -> ToolArgumentRule {
        guard let object = value.asObject else { throw ToolArgumentRuleError("a tool rule must be an object") }
        if let unknown = object.keys.sorted().first(where: { $0 != "tool" && $0 != "when" }) {
            throw ToolArgumentRuleError("tool rule has unknown key \"\(unknown)\"")
        }
        guard let tool = object["tool"]?.string, tool.isEmpty == false, tool.count <= 256 else {
            throw ToolArgumentRuleError("tool rule needs a \"tool\" glob")
        }
        guard let when = object["when"]?.asObject, when.isEmpty == false else {
            throw ToolArgumentRuleError("tool rule for \(tool) needs a non-empty \"when\" object")
        }
        var conditions: [Condition] = []
        for pointer in when.keys.sorted() {
            guard isPointer(pointer) else {
                throw ToolArgumentRuleError("\"\(pointer)\" in the rule for \(tool) is not a JSON pointer (\"/key/0\")")
            }
            guard let ops = when[pointer]?.asObject, ops.isEmpty == false else {
                throw ToolArgumentRuleError("\(pointer) in the rule for \(tool) needs at least one operator")
            }
            for name in ops.keys.sorted() {
                guard let op = Operator(rawValue: name), let expected = ops[name] else {
                    throw ToolArgumentRuleError("unknown operator \"\(name)\" in the rule for \(tool) (use == != < > in glob)")
                }
                try validate(op, expected, pointer: pointer, tool: tool)
                conditions.append(Condition(pointer: pointer, op: op, value: expected))
            }
        }
        guard conditions.count <= maximumConditions else {
            throw ToolArgumentRuleError("the rule for \(tool) has more than \(maximumConditions) conditions")
        }
        return ToolArgumentRule(tool: tool, conditions: conditions)
    }

    private static func validate(_ op: Operator, _ value: JSONValue, pointer: String, tool: String) throws {
        let at = "\(pointer) in the rule for \(tool)"
        switch op {
        case .equal, .notEqual:
            return
        case .less, .greater:
            guard value.double != nil else { throw ToolArgumentRuleError("\"\(op.rawValue)\" needs a number (\(at))") }
        case .oneOf:
            guard let items = value.asArray, items.count <= maximumListItems else {
                throw ToolArgumentRuleError("\"in\" needs an array of at most \(maximumListItems) values (\(at))")
            }
        case .glob:
            guard let pattern = value.string, pattern.isEmpty == false, pattern.count <= 256 else {
                throw ToolArgumentRuleError("\"glob\" needs a non-empty string (\(at))")
            }
        }
    }

    static func holds(_ op: Operator, actual: JSONValue, expected: JSONValue) -> Bool {
        switch op {
        case .equal:
            return actual == expected
        case .notEqual:
            return actual != expected
        case .less:
            guard let lhs = actual.double, let rhs = expected.double else { return false }
            return lhs < rhs
        case .greater:
            guard let lhs = actual.double, let rhs = expected.double else { return false }
            return lhs > rhs
        case .oneOf:
            return expected.asArray?.contains(actual) == true
        case .glob:
            guard let text = actual.string, let pattern = expected.string else { return false }
            return ManagedPolicy.glob(pattern, text)
        }
    }

    /// RFC 6901. Array indexes are decimal without leading zeros.
    public static func resolve(_ pointer: String, in document: JSONValue) -> JSONValue? {
        guard pointer.isEmpty == false else { return document }
        var current = document
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let object):
                guard let next = object[token] else { return nil }
                current = next
            case .array(let items):
                guard token == "0" || (token.first != "0" && token.allSatisfy(\.isASCII)),
                    let index = Int(token), items.indices.contains(index)
                else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    static func isPointer(_ text: String) -> Bool {
        guard text.isEmpty || text.hasPrefix("/"), text.count <= 512 else { return false }
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "~" {
                guard let next = characters.next(), next == "0" || next == "1" else { return false }
            }
        }
        return true
    }

    private static func order(_ lhs: Condition, _ rhs: Condition) -> Bool {
        if lhs.pointer != rhs.pointer { return lhs.pointer < rhs.pointer }
        return lhs.op.rawValue < rhs.op.rawValue
    }

    static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }
}
