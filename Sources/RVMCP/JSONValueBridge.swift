import Foundation
import RVPolicy

extension JSONValue {
    /// The same value in RVDomain's model, which RVPolicy rules evaluate.
    /// The conversion itself is the `JSONSpellingValue` interface in
    /// RVPolicy, shared with the managed-policy adapter: exact integers keep
    /// their digits, and anything `Double` would round fails closed as text.
    public var domainValue: ToolArgumentRule.Value {
        spellingValue.domainValue()
    }

    /// The same value in the parser module's spelling model.
    var spellingValue: JSONSpellingValue {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let spelling): return .number(spelling)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(\.spellingValue))
        case .object(let object):
            return .object(object.entries.map { .init(key: $0.key, value: $0.value.spellingValue) })
        }
    }

    init(spelling value: JSONSpellingValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .number(let spelling): self = .number(spelling)
        case .string(let text): self = .string(text)
        case .array(let items): self = .array(items.map(JSONValue.init(spelling:)))
        case .object(let entries):
            var object = JSONObject()
            for entry in entries { object[entry.key] = JSONValue(spelling: entry.value) }
            self = .object(object)
        }
    }

    /// The value with exact-integer spellings rewritten to canonical digits.
    /// Nil when a number is not an exact integer and is not a finite non-integer
    /// below 2^53. A fraction `Double` would round onto an integer is not forwarded.
    func withExactNumbers() -> JSONValue? {
        switch self {
        case .string(let text):
            // A client-supplied string carrying the number marker would
            // compare equal to a numeric rule value. Only the converters
            // may produce the marker; in client input it fails closed.
            return text.hasPrefix(JSONExactInteger.numberMarker) ? nil : self
        case .number(let spelling):
            if let digits = JSONExactInteger.digits(spelling) { return .number(digits) }
            guard JSONExactInteger.finiteNonInteger(spelling) != nil else { return nil }
            return self
        case .array(let items):
            var rewritten: [JSONValue] = []
            for item in items {
                guard let next = item.withExactNumbers() else { return nil }
                rewritten.append(next)
            }
            return .array(rewritten)
        case .object(let object):
            var copy = JSONObject()
            for (key, value) in object.entries {
                guard let next = value.withExactNumbers() else { return nil }
                copy[key] = next
            }
            return .object(copy)
        default:
            return self
        }
    }

    init(domain value: ToolArgumentRule.Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .string(let text):
            // A marked string is a JSON number in the domain model; writing
            // it back (mcp.json rewrites) must emit the number spelling,
            // never a "\u0000…" string other readers cannot match.
            if text.hasPrefix(JSONExactInteger.numberMarker) {
                let spelling = String(text.dropFirst(JSONExactInteger.numberMarker.count))
                if spelling.first.map({ $0.isNumber || $0 == "-" }) == true, spelling.count > (spelling.first == "-" ? 1 : 0) {
                    self = .number(spelling)
                } else {
                    self = .string(text)
                }
            } else {
                self = .string(text)
            }
        case .array(let items): self = .array(items.map(JSONValue.init(domain:)))
        case .object(let members):
            var object = JSONObject()
            for key in members.keys.sorted() { object[key] = members[key].map(JSONValue.init(domain:)) }
            self = .object(object)
        case .number(let number):
            if let whole = Int64(exactly: number) {
                self = .number(String(whole))
            } else {
                self = .number(String(number))
            }
        }
    }
}
