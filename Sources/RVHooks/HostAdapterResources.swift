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

    /// Returns the rv path baked into `existing`, or `nil` when it is not this adapter.
    package func bakedRvPath(in existing: String) -> String? {
        let parts = template.components(separatedBy: HostAdapterResources.rvPlaceholder)
        guard parts.count > 1 else { return existing == template ? "" : nil }
        let prefix = parts[0]
        guard existing.hasPrefix(prefix) else { return nil }
        let afterPrefix = existing.dropFirst(prefix.count)
        let second = parts[1]
        let substitution: String
        if second.isEmpty {
            substitution = String(afterPrefix)
        } else {
            guard let range = afterPrefix.range(of: second) else { return nil }
            substitution = String(afterPrefix[..<range.lowerBound])
        }
        guard parts.joined(separator: substitution) == existing else { return nil }
        return substitution
    }

    /// True when `existing` is this adapter with any single baked rv path.
    package func matchesCurrent(_ existing: String) -> Bool {
        bakedRvPath(in: existing) != nil
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
