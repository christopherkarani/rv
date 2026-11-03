import Foundation

extension SecretGateway.Entry {
    /// How the gateway spends an entry's value. The two modes share nothing,
    /// so an AWS entry cannot hold a placeholder prefix or substitution
    /// surfaces and a substitution entry cannot hold a signing binding.
    enum SpendMode: Sendable, Equatable {
        /// Swap the placeholder, minted with `prefix`, for `value` on these request surfaces.
        case substitute(prefix: String, surfaces: Set<GatewaySurface>)
        /// AWS SigV4: `value` is a credential set, and the gateway re-signs
        /// instead of substituting.
        case sign(AWSSigningBinding)
    }

    /// A substitution entry.
    init(
        secret: String, prefix: String, value: SecretValue, upstream: URL, fingerprint: String?, runtime: String?,
        surfaces: Set<GatewaySurface> = GatewaySurface.defaults, rules: [GatewayAccessRule] = [],
        processGroup: ProcessGroupFact? = nil, expires: Date? = nil, refresh: SecretRefreshPolicy? = nil,
        approvals: [GatewayAccessRule] = [], approver: SecretRequestApprover? = nil,
        binaries: [GatewayBinaryPin] = [], generation: Int = 0, previous: [SecretValue] = [],
        rotation: SecretRotationState? = nil
    ) {
        self.init(
            secret: secret, value: value, upstream: upstream, fingerprint: fingerprint, runtime: runtime,
            mode: .substitute(prefix: prefix, surfaces: surfaces), rules: rules, processGroup: processGroup,
            expires: expires, refresh: refresh, approvals: approvals, approver: approver, binaries: binaries,
            generation: generation, previous: previous, rotation: rotation)
    }

    /// An AWS signing entry. It takes no surfaces and no prefix: the agent's
    /// key id is the bare placeholder, which is all `admitAWS` accepts.
    init(
        secret: String, value: SecretValue, upstream: URL, fingerprint: String?, runtime: String?,
        rules: [GatewayAccessRule] = [], processGroup: ProcessGroupFact? = nil, expires: Date? = nil,
        refresh: SecretRefreshPolicy? = nil, signing: AWSSigningBinding, approvals: [GatewayAccessRule] = [],
        approver: SecretRequestApprover? = nil, binaries: [GatewayBinaryPin] = [], generation: Int = 0,
        previous: [SecretValue] = [], rotation: SecretRotationState? = nil
    ) {
        self.init(
            secret: secret, value: value, upstream: upstream, fingerprint: fingerprint, runtime: runtime,
            mode: .sign(signing), rules: rules, processGroup: processGroup, expires: expires, refresh: refresh,
            approvals: approvals, approver: approver, binaries: binaries, generation: generation,
            previous: previous, rotation: rotation)
    }

    /// The prefix the agent's placeholder carries. Empty for an AWS entry,
    /// whose key id is the bare placeholder.
    var prefix: String {
        switch mode {
        case .substitute(let prefix, _): prefix
        case .sign: ""
        }
    }

    /// Surfaces a placeholder may appear on. Empty for an AWS entry, whose
    /// credential set is never written into a request.
    var surfaces: Set<GatewaySurface> {
        switch mode {
        case .substitute(_, let surfaces): surfaces
        case .sign: []
        }
    }

    /// The SigV4 binding, for an AWS entry.
    var signingBinding: AWSSigningBinding? {
        switch mode {
        case .substitute: nil
        case .sign(let binding): binding
        }
    }

    var isSigning: Bool {
        switch mode {
        case .substitute: false
        case .sign: true
        }
    }
}
