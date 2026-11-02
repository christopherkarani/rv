import Foundation
import RVMCP
import RVPolicy

/// RVDomain's JSON (merge logic). `RVDomain.JSONValue` is shadowed by the
/// `RVDomain` namespace enum, so reach it through RVPolicy's alias.
typealias DomainJSON = ToolArgumentRule.Value
/// Insertion-ordered JSON that keeps each number's source spelling.
typealias LayoutJSON = RVMCP.JSONValue

/// Round-trip for shared user configs (Claude/Codex/Cursor/Antigravity
/// hooks, OpenCode, Muse). Merges keep operating on RVDomain values; this
/// type parses the user's bytes so exact integers beyond 2^53 survive (as
/// RVPolicy's marked digits), and encodes against the original document so
/// untouched members keep their key order and number spelling. Keys rv adds
/// are appended in sorted order.
enum SharedConfigJSON {
    /// The top-level object, or nil when `data` is not strict JSON with an
    /// object root (duplicate keys and strings carrying RVPolicy's number marker included).
    static func parseObject(_ data: Data) -> [String: DomainJSON]? {
        guard let layout = try? LayoutJSON.parse(data),
              case .object = layout,
              containsMarkedString(layout) == false
        else {
            return nil
        }
        return layout.domainValue.asObject
    }

    /// Two-space pretty JSON with a trailing newline, laid out like
    /// `original` wherever the merged value still matches it.
    static func encode(_ root: [String: DomainJSON], preservingLayoutOf original: Data?) -> Data {
        let guide = original.flatMap { try? LayoutJSON.parse($0) }
        return Data(layout(.object(root), guide: guide).prettyText.utf8)
    }

    private static func layout(_ value: DomainJSON, guide: LayoutJSON?) -> LayoutJSON {
        if let guide, guide.domainValue == value {
            return guide
        }
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return .bool(flag)
        case .string(let text):
            if let spelling = JSONExactInteger.markedDigits(value) {
                return .number(spelling)
            }
            return .string(text)
        case .number(let number):
            return .number(Int64(exactly: number).map(String.init) ?? String(number))
        case .array(let items):
            return .array(layout(items, guides: guide?.arrayValue ?? []))
        case .object(let members):
            return .object(layout(members, guide: guide?.objectValue))
        }
    }

    /// Unchanged elements reuse their original spelling wherever they moved;
    /// edited elements take the original at the same index as a layout hint.
    private static func layout(_ items: [DomainJSON], guides: [LayoutJSON]) -> [LayoutJSON] {
        let guideValues = guides.map(\.domainValue)
        var used = Set<Int>()
        return items.enumerated().map { index, item in
            if let match = guideValues.indices.first(where: { used.contains($0) == false && guideValues[$0] == item }) {
                used.insert(match)
                return guides[match]
            }
            return layout(item, guide: guides.indices.contains(index) ? guides[index] : nil)
        }
    }

    private static func layout(_ members: [String: DomainJSON], guide: JSONObject?) -> JSONObject {
        var object = JSONObject()
        for key in guide?.keys ?? [] {
            guard let value = members[key] else { continue }
            object[key] = layout(value, guide: guide?[key])
        }
        for key in members.keys.sorted() where object[key] == nil {
            if let value = members[key] {
                object[key] = layout(value, guide: nil)
            }
        }
        return object
    }

    private static func containsMarkedString(_ value: LayoutJSON) -> Bool {
        switch value {
        case .string(let text):
            return text.hasPrefix(JSONExactInteger.numberMarker)
        case .array(let items):
            return items.contains(where: containsMarkedString)
        case .object(let object):
            return object.entries.contains { containsMarkedString($0.value) }
        case .null, .bool, .number:
            return false
        }
    }
}
