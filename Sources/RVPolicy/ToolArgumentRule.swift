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
    /// RVDomain's JSON, named so modules with their own `JSONValue` can reach it.
    public typealias Value = JSONValue

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
    /// A `<` or `>` whose value is present but not an exact number denies:
    /// a non-match would reveal the weaker decision, and an upstream may coerce the value.
    public static func strictest(_ rules: [Decided], tool: String, arguments: JSONValue) -> ManagedPolicy.Decision? {
        let named = rules.filter { $0.rule.namesTool(tool) }
        if named.contains(where: { $0.rule.refusesIncomparable(arguments) }) { return .deny }
        return named.filter { $0.rule.matches(tool: tool, arguments: arguments) }.map(\.decision).max()
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
            guard exactQuantity(value) != nil else { throw ToolArgumentRuleError("\"\(op.rawValue)\" needs a number (\(at))") }
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
        case .less, .greater:
            guard let lhs = exactQuantity(actual), let rhs = exactQuantity(expected),
                let order = compareQuantities(lhs, rhs)
            else { return false }
            return op == .less ? order == .orderedAscending : order == .orderedDescending
        case .oneOf:
            return expected.asArray?.contains(actual) == true
        case .glob:
            guard let text = actual.string, let pattern = expected.string else { return false }
            return ManagedPolicy.glob(pattern, text)
        }
    }

    /// A `<` or `>` points at a value that is present and not an exact number,
    /// or at two quantities that cannot be compared without rounding.
    func refusesIncomparable(_ arguments: JSONValue) -> Bool {
        conditions.contains { condition in
            guard condition.op == .less || condition.op == .greater else { return false }
            guard let actual = Self.resolve(condition.pointer, in: arguments) else { return false }
            guard let lhs = Self.exactQuantity(actual), let rhs = Self.exactQuantity(condition.value),
                Self.compareQuantities(lhs, rhs) != nil
            else { return true }
            return false
        }
    }

    /// An integer's decimal digits, or a finite non-integer. Digit strings
    /// compare exactly, including integers a `Double` cannot hold.
    private enum Quantity {
        case integer(DigitInteger)
        case real(Double)
    }

    private struct DigitInteger {
        var negative: Bool
        var digits: String
    }

    private static func exactQuantity(_ value: JSONValue) -> Quantity? {
        switch value {
        case .number(let number):
            guard number.isFinite else { return nil }
            if let whole = Int64(exactly: number) {
                return .integer(DigitInteger(negative: whole < 0, digits: whole == 0 ? "0" : String(whole.magnitude)))
            }
            return .real(number)
        case .string(let text):
            return digitInteger(text).map(Quantity.integer)
        default:
            return nil
        }
    }

    /// `0`, `-0`, or a decimal integer with no leading zero and an optional sign.
    private static func digitInteger(_ text: String) -> DigitInteger? {
        var rest = text
        var negative = false
        if rest.first == "-" {
            negative = true
            rest.removeFirst()
        }
        guard rest == "0" || (rest.first != "0" && rest.allSatisfy(isDigit) && rest.isEmpty == false) else { return nil }
        if rest == "0" { negative = false }
        return DigitInteger(negative: negative, digits: rest)
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9")
    }

    private static func compareQuantities(_ lhs: Quantity, _ rhs: Quantity) -> ComparisonResult? {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)):
            return compareIntegers(left, right)
        case let (.real(left), .real(right)):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case let (.integer(integer), .real(real)):
            return compareInteger(integer, to: real)
        case let (.real(real), .integer(integer)):
            guard let order = compareInteger(integer, to: real) else { return nil }
            if order == .orderedSame { return .orderedSame }
            return order == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }

    private static func compareIntegers(_ lhs: DigitInteger, _ rhs: DigitInteger) -> ComparisonResult {
        if lhs.negative != rhs.negative {
            if lhs.digits == "0", rhs.digits == "0" { return .orderedSame }
            return lhs.negative ? .orderedAscending : .orderedDescending
        }
        let magnitude = compareMagnitudes(lhs.digits, rhs.digits)
        guard lhs.negative else { return magnitude }
        if magnitude == .orderedAscending { return .orderedDescending }
        if magnitude == .orderedDescending { return .orderedAscending }
        return .orderedSame
    }

    private static func compareMagnitudes(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Nil when the integer is outside the range `Double` holds exactly and
    /// `real` is too large to order against it without rounding.
    private static func compareInteger(_ integer: DigitInteger, to real: Double) -> ComparisonResult? {
        guard real.isFinite else { return nil }
        if let asDouble = Double(integer.digits), let whole = Int64(exactly: asDouble), String(whole) == integer.digits {
            let value = integer.negative ? -asDouble : asDouble
            if value < real { return .orderedAscending }
            if value > real { return .orderedDescending }
            return .orderedSame
        }
        let exactLimit = 9_007_199_254_740_992.0
        guard real < exactLimit, real > -exactLimit else { return nil }
        if integer.negative || integer.digits == "0" { return .orderedAscending }
        return .orderedDescending
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
