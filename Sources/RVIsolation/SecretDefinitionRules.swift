import Foundation

/// The limits that apply only to gateway-mediated deliveries. They live in the
/// gateway payloads, so an environment secret cannot carry them.
public struct SecretGatewayLimits: Sendable, Equatable {
    /// Re-resolve from the provider this often while a runtime lives.
    public var refresh: SecretRefreshInterval?
    /// Absolute paths of the binaries that may spend the value. A request is
    /// served only when every runtime process holding its connection runs one
    /// of them, or descends from one that does.
    public var binaries: [String]?

    public init(refresh: SecretRefreshInterval? = nil, binaries: [String]? = nil) {
        self.refresh = refresh
        self.binaries = binaries
    }
}

/// A cross-field rule a secret definition broke. `reason` is the text
/// `secrets.json is invalid: ` is followed by.
public enum SecretDefinitionError: Error, Sendable, Equatable {
    case awsProfileNeedsAWSSigV4(String)
    case oauthNeedsGateway(String)
    case awsSigV4NeedsAWSProfile(String)
    case refreshNeedsGateway(String)
    case binariesNeedGateway(String)

    public var reason: String {
        switch self {
        case .awsProfileNeedsAWSSigV4(let name): "\(name).source.awsProfile needs awsSigV4 delivery"
        case .oauthNeedsGateway(let name): "\(name).source.oauth needs gateway delivery"
        case .awsSigV4NeedsAWSProfile(let name): "\(name).delivery.awsSigV4 needs an awsProfile source"
        case .refreshNeedsGateway(let name):
            "\(name).refresh applies to gateway delivery; a value in the environment cannot change after launch"
        case .binariesNeedGateway(let name):
            "\(name).binaries applies to gateway delivery; rv cannot see which process reads an environment variable"
        }
    }

    /// The source x delivery rules, in the order the decoder has always applied them.
    static func pairing(_ name: String, _ source: SecretSource, _ delivery: SecretDelivery) -> Self? {
        switch (source, delivery) {
        // A profile's value is a credential set, not a token, and signing needs one.
        case (.awsProfile, .awsSigV4): nil
        case (.awsProfile, _): .awsProfileNeedsAWSSigV4(name)
        // An access token outlives no runtime: it is minted for, and refreshed by, gateway requests.
        case (.oauth, .gateway): nil
        case (.oauth, _): .oauthNeedsGateway(name)
        case (_, .awsSigV4): .awsSigV4NeedsAWSProfile(name)
        default: nil
        }
    }

    /// The error for limits set on a delivery that cannot carry them.
    static func refresh(_ name: String, _ delivery: SecretDelivery) -> Self? {
        delivery.limits == nil ? .refreshNeedsGateway(name) : nil
    }

    static func binaries(_ name: String, _ delivery: SecretDelivery) -> Self? {
        delivery.limits == nil ? .binariesNeedGateway(name) : nil
    }
}

extension SecretDelivery {
    /// Nil for environment delivery, which cannot carry limits.
    public var limits: SecretGatewayLimits? {
        switch self {
        case .gateway(let binding): binding.limits
        case .awsSigV4(let binding): binding.limits
        case .environment: nil
        }
    }

    /// This delivery with `limits` in its payload; environment ignores them.
    func with(limits: SecretGatewayLimits) -> SecretDelivery {
        switch self {
        case .gateway(var binding):
            binding.limits = limits
            return .gateway(binding)
        case .awsSigV4(var binding):
            binding.limits = limits
            return .awsSigV4(binding)
        case .environment: return self
        }
    }

    /// What a running placeholder is bound to: equality of routes ignores limits.
    var route: SecretDelivery { with(limits: SecretGatewayLimits()) }
}

extension SecretDefinition {
    /// Gateway only: re-resolve from the provider this often while a runtime lives.
    /// Read-only here so an environment secret cannot silently drop a write; set it
    /// with `setRefresh(_:)` or through the gateway payload's `limits`.
    public var refresh: SecretRefreshInterval? { delivery.limits?.refresh }

    /// Gateway only: absolute paths of the binaries that may spend the value.
    public var binaries: [String]? { delivery.limits?.binaries }

    /// Sets or clears the refresh interval. Clearing always succeeds; setting
    /// one on an environment secret is refused.
    public mutating func setRefresh(_ interval: SecretRefreshInterval?) throws(SecretDefinitionError) {
        guard var limits = delivery.limits else {
            if interval != nil, let error = SecretDefinitionError.refresh(name, delivery) { throw error }
            return
        }
        limits.refresh = interval
        delivery = delivery.with(limits: limits)
    }
}
