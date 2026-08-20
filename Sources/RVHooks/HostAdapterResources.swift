import Foundation

/// Failure when an embedded Host adapter resource cannot be decoded.
package enum HostAdapterResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingTemplate(HookHost)

    package var description: String {
        switch self {
        case .missingTemplate(let host):
            return "missing Host adapter template for \(host.rawValue)"
        }
    }
}

/// An embedded Host adapter template for one `HookHost`.
package struct HostAdapterResource: Sendable {
    private let template: String

    fileprivate init(template: String) {
        self.template = template
    }

    /// Returns the adapter source with the rv-binary placeholder replaced by `rvPath`.
    package func rendered(rvPath: String) -> String {
        template.replacingOccurrences(of: HostAdapterResources.rvPlaceholder, with: rvPath)
    }

    /// True when `existing` is this adapter with any single baked rv path.
    package func matchesCurrent(_ existing: String) -> Bool {
        let parts = template.components(separatedBy: HostAdapterResources.rvPlaceholder)
        guard parts.count > 1 else { return existing == template }
        let prefix = parts[0]
        guard existing.hasPrefix(prefix) else { return false }
        let afterPrefix = existing.dropFirst(prefix.count)
        let second = parts[1]
        let substitution: String
        if second.isEmpty {
            substitution = String(afterPrefix)
        } else {
            guard let range = afterPrefix.range(of: second) else { return false }
            substitution = String(afterPrefix[..<range.lowerBound])
        }
        return parts.joined(separator: substitution) == existing
    }
}

/// Embedded Host adapter templates for the three v1 hosts.
package enum HostAdapterResources {
    fileprivate static let rvPlaceholder = "__RV_BINARY__"

    /// Returns the embedded adapter resource for `host`.
    ///
    /// - Throws: `HostAdapterResourceError.missingTemplate` when the resource is
    ///   missing, empty, or lacks the placeholder.
    package static func load(
        for host: HookHost
    ) throws(HostAdapterResourceError) -> HostAdapterResource {
        let bytes: [UInt8]
        switch host {
        case .grok:
            bytes = PackageResources.rv_json_tmpl
        case .pi:
            bytes = PackageResources.rv_guard_ts_tmpl
        case .opencode:
            bytes = PackageResources.rv_guard_js_tmpl
        }
        guard let text = String(bytes: bytes, encoding: .utf8),
              text.isEmpty == false,
              text.contains(rvPlaceholder)
        else {
            throw HostAdapterResourceError.missingTemplate(host)
        }
        return HostAdapterResource(template: text)
    }
}
