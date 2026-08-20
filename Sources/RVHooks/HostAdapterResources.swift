import Foundation

package enum HostAdapterResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingTemplate(HookHost)

    package var description: String {
        switch self {
        case .missingTemplate(let host):
            return "missing Host adapter template for \(host.rawValue)"
        }
    }
}

package struct HostAdapterResource: Sendable {
    private let template: String

    fileprivate init(template: String) {
        self.template = template
    }

    package func rendered(rvPath: String) -> String {
        template.replacingOccurrences(of: HostAdapterResources.rvPlaceholder, with: rvPath)
    }
}

package enum HostAdapterResources {
    fileprivate static let rvPlaceholder = "__RV_BINARY__"

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
