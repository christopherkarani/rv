import Foundation
import RVPolicy

extension JSONValue {
    /// The same value in RVDomain's model, which RVPolicy rules evaluate.
    /// Integers a `Double` cannot hold exactly become their digits as a
    /// string, as RVDomain's own decoder does, so equality stays exact.
    public var domainValue: ToolArgumentRule.Value {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(\.domainValue))
        case .object(let object):
            var members: [String: ToolArgumentRule.Value] = [:]
            for (key, value) in object.entries { members[key] = value.domainValue }
            return .object(members)
        case .number(let spelling):
            if let whole = Int64(spelling) {
                return Int64(exactly: Double(whole)) == whole ? .number(Double(whole)) : .string(String(whole))
            }
            if let whole = UInt64(spelling) {
                return UInt64(exactly: Double(whole)) == whole ? .number(Double(whole)) : .string(String(whole))
            }
            return Double(spelling).map(ToolArgumentRule.Value.number) ?? .string(spelling)
        }
    }

    init(domain value: ToolArgumentRule.Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .string(let text): self = .string(text)
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
