#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import Synchronization

/// What has to happen before an `oauth` source can mint again.
enum OAuthRecovery: String, Sendable, Equatable {
    /// Transient: the next request tries again.
    case retry
    /// rv stopped mid-exchange; the refresh token may have rotated. Not retried.
    case investigate
    /// The refresh token is dead or may have rotated. Not retried.
    case reauthorize
    /// The issuer rejected the client, grant type, or scope.
    case fixConfiguration
}

/// The access token an `oauth` source resolves to and when it expires.
/// It crosses the resolver as `{"access_token": …, "expires_at": epoch}` so
/// the broker can bound the gateway entry by it, as with an AWS credential set.
struct OAuthAccessToken: Sendable {
    static let unusable = "the token endpoint's answer could not be used"

    let token: SecretValue
    let expires: Date?

    init?(_ value: SecretValue) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(value.bytes))) as? [String: Any],
            let text = object["access_token"] as? String, OAuthTokenMinter.usableToken(text),
            let token = SecretValue(text)
        else { return nil }
        self.token = token
        expires = (object["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    static func encode(token: String, expires: Date?) -> SecretValue? {
        var object: [String: Any] = ["access_token": token]
        if let expires {
            // A date this far out has no epoch second to write; leave it off rather than trap.
            guard let epoch = Int(exactly: expires.timeIntervalSince1970.rounded(.down)) else { return nil }
            object["expires_at"] = epoch
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SecretValue(String(decoding: data, as: UTF8.self))
    }
}

/// Mints access tokens at an RFC 6749 token endpoint from credentials held
/// in the Keychain. A refresh token that rotates is written back; an
/// exchange whose outcome is unknown blocks that refresh token for good,
/// because resending a rotated one can make the issuer revoke the grant.
struct OAuthTokenMinter: Sendable {
    enum Exchange: Sendable, Equatable {
        case response(status: Int, body: Data)
        /// Failed before the request could reach the issuer (DNS, connect, TLS).
        case notSent
        /// Sent, and no complete answer came back.
        case noAnswer
    }

    var send: @Sendable (URLRequest) -> Exchange
    var read: @Sendable (SecretKeychainItem) -> SecretValue?
    var write: @Sendable (SecretKeychainItem, SecretValue) -> Bool
    /// `<config>/secrets-oauth`: per-refresh-token lock and state files. No secret is stored there.
    var stateDirectory: URL
    var now: @Sendable () -> Date
    /// How long to wait for another rv process mid-exchange; past the 30 s request timeout.
    var lockWait: TimeInterval = 40

    static let directoryName = "secrets-oauth"
    /// Leaves room for the JSON wrapper inside `SecretValue.maximumBytes`.
    static let maximumTokenBytes = 8 * 1024
    /// `expires_in` is clamped to this range: an issuer claiming more than a day
    /// would otherwise keep a token past a re-mint for as long as it likes.
    static let lifetimeRange: ClosedRange<TimeInterval> = 1...86_400

    static func live(home: String) -> OAuthTokenMinter {
        let configDirectory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true).appendingPathComponent("rv", isDirectory: true)
        return OAuthTokenMinter(
            send: liveSend,
            read: { item in KeychainReader.live.read(item.service, item.account).flatMap { SecretValue(Array($0)) } },
            write: { item, value in SecretKeychainWriter.live.store(item.service, item.account, Data(value.bytes)) },
            stateDirectory: configDirectory.appendingPathComponent(directoryName, isDirectory: true),
            now: { Date() })
    }

    func mint(_ source: OAuthSource) -> Result<SecretValue, SecretResolutionError> {
        var clientSecret: SecretValue?
        if let item = source.clientSecret {
            guard let value = read(item) else { return .failure(.notFound(Self.describe(item))) }
            guard value.text != nil else { return .failure(.invalidValue("\(Self.describe(item)) is not text")) }
            clientSecret = value
        }
        guard let item = source.refreshToken else {
            return mintClientCredentials(source, clientSecret: clientSecret)
        }
        var result: Result<SecretValue, SecretResolutionError>?
        let locked = withLock(item) { result = mintRefreshing(source, item: item, clientSecret: clientSecret) }
        guard locked, let result else {
            return .failure(.failed("another rv process is refreshing \(Self.describe(item)); try again"))
        }
        return result
    }

    // MARK: Refresh grant

    private func mintRefreshing(
        _ source: OAuthSource, item: SecretKeychainItem, clientSecret: SecretValue?
    ) -> Result<SecretValue, SecretResolutionError> {
        // Read inside the lock: another process may have just rotated it.
        guard let refreshToken = read(item) else { return .failure(.notFound(Self.describe(item))) }
        guard let text = refreshToken.text, Self.usableToken(text) else {
            return .failure(.invalidValue("\(Self.describe(item)) does not hold a refresh token (printable ASCII, up to 8 KiB)"))
        }
        guard let fingerprint = SecretFingerprinter.load(configDirectory: stateDirectory.deletingLastPathComponent())?
            .fingerprint(refreshToken)
        else { return .failure(.failed("rv could not load its fingerprint key, so it will not refresh")) }
        let stateURL = stateFile(item)
        if let state = OAuthRefreshState.load(stateURL) {
            // A different token means the item was replaced since: the block is lifted.
            if state.token == fingerprint { return .failure(Self.failure(state.recovery, item: item, detail: nil)) }
            try? FileManager.default.removeItem(at: stateURL)
        }
        guard OAuthRefreshState(recovery: .investigate, token: fingerprint).save(stateURL) else {
            return .failure(.failed("rv could not record the refresh in \(Self.directoryName), so it did not send it"))
        }
        let outcome = Self.classify(
            send(request(source, refreshToken: refreshToken, clientSecret: clientSecret)), grant: .refreshToken)
        switch outcome {
        case .minted(let token, let expires, let rotated):
            if let rotated, let next = SecretValue(rotated), next != refreshToken, write(item, next) == false {
                // The old token is spent and the new one is lost: never send the old one again.
                _ = OAuthRefreshState(recovery: .reauthorize, token: fingerprint).save(stateURL)
                return .failure(Self.failure(
                    .reauthorize, item: item, detail: "the issuer rotated the refresh token and the Keychain write failed"))
            }
            try? FileManager.default.removeItem(at: stateURL)
            return encodedResult(token, expires: expires)
        case .failed(var recovery, var detail, let rotated):
            // The issuer rotated while rejecting the access token: the new token is the grant.
            if let rotated, let next = SecretValue(rotated), next != refreshToken, write(item, next) == false {
                recovery = .reauthorize
                detail = "the issuer rotated the refresh token and the Keychain write failed"
            }
            if recovery == .reauthorize || recovery == .investigate {
                _ = OAuthRefreshState(recovery: recovery, token: fingerprint).save(stateURL)
            } else {
                try? FileManager.default.removeItem(at: stateURL)
            }
            return .failure(Self.failure(recovery, item: item, detail: detail))
        }
    }

    // MARK: Client credentials

    private func mintClientCredentials(
        _ source: OAuthSource, clientSecret: SecretValue?
    ) -> Result<SecretValue, SecretResolutionError> {
        switch Self.classify(send(request(source, refreshToken: nil, clientSecret: clientSecret)), grant: .clientCredentials) {
        case .minted(let token, let expires, _): return encodedResult(token, expires: expires)
        case .failed(let recovery, let detail, _): return .failure(Self.failure(recovery, item: nil, detail: detail))
        }
    }

    // MARK: Exchange

    enum Grant: Sendable { case refreshToken, clientCredentials }

    enum Outcome: Sendable, Equatable {
        case minted(token: String, expires: TimeInterval?, refreshToken: String?)
        /// `refreshToken`: a usable rotated refresh token that came with the failure.
        case failed(OAuthRecovery, detail: String, refreshToken: String? = nil)
    }

    /// RFC 6749 §5.1 / §5.2. A complete error response means the issuer
    /// issued nothing (§5.2), so only a missing or unusable success is ambiguous.
    static func classify(_ exchange: Exchange, grant: Grant) -> Outcome {
        let rotating = grant == .refreshToken
        switch exchange {
        case .notSent:
            return .failed(.retry, detail: "the token endpoint could not be reached")
        case .noAnswer:
            return .failed(rotating ? .reauthorize : .retry, detail: "the token endpoint did not answer")
        case .response(let status, let body):
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            // Only the `error` code, filtered: issuers put anything in descriptions.
            let code = (json?["error"] as? String).map(safeCode) ?? ""
            if status == 200, json?["error"] == nil || json?["access_token"] != nil {
                let rotated = json?["refresh_token"] as? String
                let usableRotation = rotated.flatMap { usableToken($0) ? $0 : nil }
                guard let token = json?["access_token"] as? String, usableToken(token),
                    (json?["token_type"] as? String)?.lowercased() == "bearer"
                else {
                    return .failed(
                        rotating ? .reauthorize : .fixConfiguration,
                        detail: "the token endpoint answered without a usable bearer token", refreshToken: usableRotation)
                }
                if rotated != nil, usableRotation == nil {
                    return .failed(.reauthorize, detail: "the token endpoint returned an unusable refresh token")
                }
                let lifetime = (json?["expires_in"] as? NSNumber)?.doubleValue
                return .minted(
                    token: token,
                    expires: lifetime.flatMap { $0 > 0 ? min(max($0, lifetimeRange.lowerBound), lifetimeRange.upperBound) : nil },
                    refreshToken: rotated)
            }
            if (300..<400).contains(status) {
                return .failed(.fixConfiguration, detail: "the token endpoint redirected (HTTP \(status)); set tokenURL to the final URL")
            }
            let shown = code.isEmpty ? "HTTP \(status)" : "\(code), HTTP \(status)"
            switch code {
            case "invalid_grant":
                return .failed(rotating ? .reauthorize : .fixConfiguration, detail: "the token endpoint refused (\(shown))")
            case "invalid_client", "unauthorized_client", "invalid_scope", "unsupported_grant_type", "invalid_request":
                return .failed(.fixConfiguration, detail: "the token endpoint refused (\(shown))")
            default:
                // A proxy can answer 5xx after the issuer already rotated the token; resending a spent
                // refresh token can make the issuer revoke the grant, so only an RFC 6749 error retries.
                if rotating, code.isEmpty, (500..<600).contains(status) {
                    return .failed(.reauthorize, detail: "the token endpoint failed (\(shown)) without an OAuth error, so the refresh may have been spent")
                }
                return .failed(.retry, detail: "the token endpoint failed (\(shown))")
            }
        }
    }

    static func usableToken(_ text: String) -> Bool {
        text.isEmpty == false && text.utf8.count <= maximumTokenBytes && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static func safeCode(_ text: String) -> String {
        String(text.prefix(64).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
    }

    func request(_ source: OAuthSource, refreshToken: SecretValue?, clientSecret: SecretValue?) -> URLRequest {
        var pairs: [(String, String)] = refreshToken.map { [("grant_type", "refresh_token"), ("refresh_token", $0.text ?? "")] }
            ?? [("grant_type", "client_credentials")]
        if let scope = source.scope { pairs.append(("scope", scope)) }
        pairs.append(("client_id", source.clientID))
        if let clientSecret { pairs.append(("client_secret", clientSecret.text ?? "")) }
        var request = URLRequest(url: source.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.form(pairs).utf8)
        return request
    }

    static func form(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    private func encodedResult(_ token: String, expires: TimeInterval?) -> Result<SecretValue, SecretResolutionError> {
        Self.encoded(token, expires: expires.map { now().addingTimeInterval($0) })
    }

    private static func encoded(_ token: String, expires: Date?) -> Result<SecretValue, SecretResolutionError> {
        guard let value = OAuthAccessToken.encode(token: token, expires: expires) else {
            return .failure(.invalidValue(OAuthAccessToken.unusable))
        }
        return .success(value)
    }

    static func describe(_ item: SecretKeychainItem) -> String {
        "keychain item \(DisplayedText.field(item.service)) / \(DisplayedText.field(item.account))"
    }

    static func failure(_ recovery: OAuthRecovery, item: SecretKeychainItem?, detail: String?) -> SecretResolutionError {
        let prefix = detail.map { "\($0); " } ?? ""
        let place = item.map(describe) ?? "the refresh token's keychain item"
        switch recovery {
        case .retry:
            return .providerUnavailable("\(prefix)rv tries again on the next request (retry)")
        case .investigate:
            return .failed(
                "\(prefix)a refresh with \(place) did not finish, so the issuer may have rotated it; "
                    + "check the grant, then store a working refresh token in that item; if the issuer does not rotate "
                    + "refresh tokens, `rv secrets oauth-reset <secret>` lifts the block (investigate)")
        case .reauthorize:
            return .failed(
                "\(prefix)rv will not send that refresh token again; store a new refresh token in \(place), or if the "
                    + "issuer does not rotate refresh tokens run `rv secrets oauth-reset <secret>` (reauthorize)")
        case .fixConfiguration:
            return .failed("\(prefix)fix tokenURL, clientID, clientSecret, or scope in secrets.json (fixConfiguration)")
        }
    }

    // MARK: Files

    func stateFile(_ item: SecretKeychainItem) -> URL {
        stateDirectory.appendingPathComponent("\(Self.key(item)).json", isDirectory: false)
    }

    /// Names the files after the item without spelling it out.
    static func key(_ item: SecretKeychainItem) -> String {
        String(RVDigest.sha256Hex(Array("\(item.service)\u{0}\(item.account)".utf8)).prefix(32))
    }

    /// flock on `.<key>.lock`, bounded by `lockWait`. Serializes exchanges of
    /// one refresh token across threads and rv processes.
    private func withLock(_ item: SecretKeychainItem, _ body: () -> Void) -> Bool {
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = stateDirectory.appendingPathComponent(".\(Self.key(item)).lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockWait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                body()
                _ = flock(fd, LOCK_UN)
                return true
            }
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return false }
            usleep(50_000)
        }
    }

    /// Removes the block recorded for `item`'s refresh token, waiting out an
    /// exchange in flight. True when there was a block to remove.
    func clearBlock(_ item: SecretKeychainItem) -> Bool? {
        var cleared = false
        let locked = withLock(item) {
            let url = stateFile(item)
            cleared = FileManager.default.fileExists(atPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return locked ? cleared : nil
    }

    // MARK: Live transport

    static let liveSend: @Sendable (URLRequest) -> Exchange = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // A redirect would re-send the credentials somewhere else.
        let session = URLSession(configuration: configuration, delegate: DirectHTTP.NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let outcome = Mutex<Exchange>(.noAnswer)
        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, error == nil {
                outcome.withLock { $0 = .response(status: http.statusCode, body: data ?? Data()) }
            } else if let code = (error as? URLError)?.code, notSentCodes.contains(code) {
                outcome.withLock { $0 = .notSent }
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + request.timeoutInterval + 5) == .success else { return .noAnswer }
        return outcome.withLock { $0 }
    }

    /// Failures that happen before the request body can reach the issuer.
    static let notSentCodes: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
        .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection, .internationalRoamingOff,
        .dataNotAllowed, .callIsActive,
    ]
}

/// `<key>.json`: why the refresh token with fingerprint `token` must not be sent.
/// Written as `investigate` before every exchange and removed after a clean one,
/// so a crash in between leaves it blocked.
struct OAuthRefreshState: Equatable {
    var recovery: OAuthRecovery
    /// `SecretFingerprinter` HMAC of the refresh token, never the token.
    var token: String

    /// Writes are atomic, so a file is either a whole record or absent.
    static func load(_ url: URL) -> OAuthRefreshState? {
        guard let data = try? Data(contentsOf: url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
            let recovery = object["recovery"].flatMap(OAuthRecovery.init(rawValue:)), let token = object["token"]
        else { return nil }
        return OAuthRefreshState(recovery: recovery, token: token)
    }

    /// Owner-only (0600) and atomic: the file names a refresh token's
    /// fingerprint, so it is kept as private as the rest of rv's config.
    func save(_ url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["recovery": recovery.rawValue, "token": token], options: [.sortedKeys])
        else { return false }
        return OwnerOnlyFile.write(data, to: url)
    }
}

/// The block `OAuthTokenMinter` records against a refresh token, for `rv secrets oauth-reset`.
/// State lives in `<config>/secrets-oauth/<key>.json`, one file per refresh-token Keychain
/// item; it holds a recovery class and an HMAC of the token, never the token.
public enum OAuthRefreshBlock {
    public static func stateFile(_ item: SecretKeychainItem, configDirectory: URL) -> URL {
        minter(configDirectory).stateFile(item)
    }

    /// Lifts the block on `item`'s refresh token. True when one was recorded; nil
    /// when another rv process held the exchange lock for the whole wait.
    public static func clear(_ item: SecretKeychainItem, configDirectory: URL) -> Bool? {
        minter(configDirectory).clearBlock(item)
    }

    private static func minter(_ configDirectory: URL) -> OAuthTokenMinter {
        OAuthTokenMinter(
            send: { _ in .notSent }, read: { _ in nil }, write: { _, _ in false },
            stateDirectory: configDirectory.appendingPathComponent(OAuthTokenMinter.directoryName, isDirectory: true),
            now: { Date() })
    }
}
