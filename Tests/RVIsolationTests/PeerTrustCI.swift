import Foundation

/// D13 option A switch: the `macos-peer-trust` CI job installs development
/// peer trust and sets RV_PEER_TRUST_CI=1. Unset, TRANSITIONAL-PEER-AUTH
/// tests stay skipped.
let peerTrustCI = ProcessInfo.processInfo.environment["RV_PEER_TRUST_CI"] == "1"
