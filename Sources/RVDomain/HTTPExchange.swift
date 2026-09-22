import Foundation
import Synchronization

/// Cooperative cancel for one HTTPS GET. `finish` on the runtime sets it.
public final class HTTPCancellation: @unchecked Sendable {
    private let state = Mutex(false)

    public init() {}

    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}

/// No socket was opened.
public enum HTTPNotOpened: String, Sendable, Equatable, Codable {
    case cancelled
    case forbiddenDestination
    case unavailable
}

/// The transfer started. None of these follow a redirect or keep the extra body.
public enum HTTPOpenFailure: Sendable, Equatable, Codable {
    case redirect(status: Int, location: String?)
    case responseTooLarge
    case timedOut
    case cancelled
    case transport
    case malformedResponse
    case unsupportedTransfer
    case tooManyHeaders
}

public enum HTTPEgressFailure: Error, Sendable, Equatable {
    case notOpened(HTTPNotOpened)
    case opened(HTTPOpenFailure)
}

public struct HTTPResponseHeader: Sendable, Equatable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Bounded result returned to the agent. Platform socket types stay out of this value.
public struct HTTPExecutionReceipt: Sendable, Equatable, Codable {
    public var status: Int
    public var destination: String
    public var headers: [HTTPResponseHeader]
    public var body: Data

    public init(status: Int, destination: String, headers: [HTTPResponseHeader], body: Data) {
        self.status = status
        self.destination = destination
        self.headers = headers
        self.body = body
    }
}

public struct HTTPExchangeLimits: Sendable, Equatable {
    public var maxBodyBytes: Int
    public var maxHeaderBlockBytes: Int
    public var maxHeaderCount: Int
    public var maxHeaderValueBytes: Int
    public var readSliceMilliseconds: Int

    public init(
        maxBodyBytes: Int,
        maxHeaderBlockBytes: Int,
        maxHeaderCount: Int,
        maxHeaderValueBytes: Int,
        readSliceMilliseconds: Int
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderBlockBytes = maxHeaderBlockBytes
        self.maxHeaderCount = maxHeaderCount
        self.maxHeaderValueBytes = maxHeaderValueBytes
        self.readSliceMilliseconds = readSliceMilliseconds
    }

    public static let production = HTTPExchangeLimits(
        maxBodyBytes: HTTPEgressLimits.maxResponseBodyBytes,
        maxHeaderBlockBytes: HTTPEgressLimits.maxHeaderBlockBytes,
        maxHeaderCount: HTTPEgressLimits.maxHeaderCount,
        maxHeaderValueBytes: HTTPEgressLimits.maxHeaderValueBytes,
        readSliceMilliseconds: HTTPEgressLimits.readSliceMilliseconds
    )
}

public enum HTTPTransferFault: Error, Sendable, Equatable {
    case failed
}

public enum HTTPTransferRead: Sendable, Equatable {
    case bytes(Data)
    case waiting
    case end
}

/// Byte pipe for one already-chosen peer. It does not pick a destination.
public struct HTTPTransfer: Sendable {
    public var write: @Sendable (Data) -> Result<Void, HTTPTransferFault>
    public var read: @Sendable (_ maximumBytes: Int, _ waitMilliseconds: Int) -> Result<
        HTTPTransferRead, HTTPTransferFault
    >
    public var stop: @Sendable () -> Void

    public init(
        write: @escaping @Sendable (Data) -> Result<Void, HTTPTransferFault>,
        read: @escaping @Sendable (_ maximumBytes: Int, _ waitMilliseconds: Int) -> Result<
            HTTPTransferRead, HTTPTransferFault
        >,
        stop: @escaping @Sendable () -> Void
    ) {
        self.write = write
        self.read = read
        self.stop = stop
    }
}

enum HTTPRequestMessage {
    static func bytes(for destination: HTTPDestination) -> Data {
        let head = [
            "GET \(destination.requestTarget) HTTP/1.1",
            "Host: \(destination.hostHeader)",
            "User-Agent: \(HTTPEgressLimits.userAgent)",
            "Accept: */*",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8)
    }
}

/// Speaks one HTTP/1.1 GET on a transfer RV already opened.
///
/// Redirects are returned. They are not a second connection.
public enum HTTPExchange {
    public static func perform(
        destination: HTTPDestination,
        transfer: HTTPTransfer,
        deadline: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        shouldStop: @escaping @Sendable () -> Bool = { false },
        limits: HTTPExchangeLimits = .production
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        guard destination.isPublicPinned else {
            return .failure(.notOpened(.forbiddenDestination))
        }
        if destination.requestTarget.contains("\r") || destination.requestTarget.contains("\n")
            || destination.hostHeader.contains("\r") || destination.hostHeader.contains("\n")
        {
            return .failure(.notOpened(.unavailable))
        }
        if shouldStop() {
            return .failure(.notOpened(.cancelled))
        }
        switch transfer.write(HTTPRequestMessage.bytes(for: destination)) {
        case .failure:
            transfer.stop()
            return .failure(.opened(.transport))
        case .success:
            break
        }
        var reader = HTTPResponseReader(destination: destination, limits: limits)
        while true {
            if shouldStop() {
                transfer.stop()
                return .failure(.opened(.cancelled))
            }
            if now() >= deadline {
                transfer.stop()
                return .failure(.opened(.timedOut))
            }
            let remaining = max(1, Int(deadline.timeIntervalSince(now()) * 1_000))
            let wait = min(limits.readSliceMilliseconds, remaining)
            switch transfer.read(reader.maximumRead, wait) {
            case .failure:
                transfer.stop()
                return .failure(.opened(.transport))
            case .success(.waiting):
                continue
            case .success(.end):
                transfer.stop()
                return reader.finish()
            case .success(.bytes(let data)):
                switch reader.feed(data) {
                case .needMore:
                    continue
                case .success(let receipt):
                    transfer.stop()
                    return .success(receipt)
                case .failure(let failure):
                    transfer.stop()
                    return .failure(.opened(failure))
                }
            }
        }
    }
}

private enum HTTPReadStep {
    case needMore
    case success(HTTPExecutionReceipt)
    case failure(HTTPOpenFailure)
}

private struct HTTPResponseReader {
    var destination: HTTPDestination
    var limits: HTTPExchangeLimits
    private var buffer = Data()
    private var phase = Phase.headers
    private var status = 0
    private var headers: [HTTPResponseHeader] = []
    private var body = Data()
    private var contentLength: Int?
    private var chunk = ChunkState.size
    private var chunkRemaining = 0

    private enum Phase {
        case headers
        case contentLength
        case chunked
        case untilClose
        case done
    }

    private enum ChunkState {
        case size
        case data
        case dataEnding
        case trailer
    }

    var maximumRead: Int {
        switch phase {
        case .headers:
            return limits.maxHeaderBlockBytes + 1
        case .contentLength:
            let remaining = (contentLength ?? 0) - body.count
            return min(8_192, max(remaining, 1))
        case .chunked, .untilClose, .done:
            let room = limits.maxBodyBytes + 1 - body.count
            return min(8_192, max(room, 1))
        }
    }

    mutating func feed(_ data: Data) -> HTTPReadStep {
        guard phase != .done else { return .failure(.malformedResponse) }
        guard data.isEmpty == false else { return .needMore }
        buffer.append(data)
        return pump()
    }

    mutating func finish() -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        switch phase {
        case .untilClose:
            if body.count > limits.maxBodyBytes {
                return .failure(.opened(.responseTooLarge))
            }
            return .success(receipt)
        case .done:
            return .success(receipt)
        case .headers, .contentLength, .chunked:
            return .failure(.opened(.malformedResponse))
        }
    }

    private mutating func pump() -> HTTPReadStep {
        while true {
            switch phase {
            case .headers:
                switch takeHeaders() {
                case .needMore:
                    if buffer.count > limits.maxHeaderBlockBytes {
                        return .failure(.tooManyHeaders)
                    }
                    return .needMore
                case .success:
                    continue
                case .failure(let failure):
                    return .failure(failure)
                }
            case .contentLength:
                guard let contentLength else { return .failure(.malformedResponse) }
                let need = contentLength - body.count
                if need <= 0 {
                    phase = .done
                    buffer.removeAll()
                    return .success(receipt)
                }
                if buffer.isEmpty { return .needMore }
                let take = min(need, buffer.count)
                appendBody(buffer.prefix(take))
                buffer.removeFirst(take)
                if body.count > limits.maxBodyBytes {
                    return .failure(.responseTooLarge)
                }
                if body.count == contentLength {
                    phase = .done
                    buffer.removeAll()
                    return .success(receipt)
                }
            case .chunked:
                switch takeChunk() {
                case .needMore:
                    return .needMore
                case .success:
                    continue
                case .failure(let failure):
                    return .failure(failure)
                }
            case .untilClose:
                if buffer.isEmpty { return .needMore }
                appendBody(buffer)
                buffer.removeAll()
                if body.count > limits.maxBodyBytes {
                    return .failure(.responseTooLarge)
                }
                return .needMore
            case .done:
                return .success(receipt)
            }
        }
    }

    private mutating func takeHeaders() -> HTTPReadStep {
        guard let marker = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .needMore
        }
        let headerBytes = buffer[..<marker.lowerBound]
        if headerBytes.count > limits.maxHeaderBlockBytes {
            return .failure(.tooManyHeaders)
        }
        buffer.removeSubrange(..<marker.upperBound)
        guard let text = String(bytes: headerBytes, encoding: .utf8) else {
            return .failure(.malformedResponse)
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, parseStatus(statusLine) else {
            return .failure(.malformedResponse)
        }
        if lines.count - 1 > limits.maxHeaderCount {
            return .failure(.tooManyHeaders)
        }
        if (100..<200).contains(status) {
            return .failure(.malformedResponse)
        }
        var contentLengths: [Int] = []
        var transfer: String?
        var location: String?
        var selected: [HTTPResponseHeader] = []
        for line in lines.dropFirst() {
            if line.isEmpty { return .failure(.malformedResponse) }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                return .failure(.malformedResponse)
            }
            guard let parsed = parseHeader(line) else { return .failure(.malformedResponse) }
            switch parsed.name {
            case "content-length":
                guard let length = strictLength(parsed.value) else {
                    return .failure(.malformedResponse)
                }
                contentLengths.append(length)
            case "transfer-encoding":
                if transfer != nil { return .failure(.unsupportedTransfer) }
                transfer = parsed.value
            case "location":
                location = parsed.value
            default:
                break
            }
            if returnedHeaderNames.contains(parsed.name),
                parsed.value.utf8.count <= limits.maxHeaderValueBytes
            {
                selected.append(HTTPResponseHeader(name: parsed.name, value: parsed.value))
            }
        }
        headers = selected
        if contentLengths.count > 1 { return .failure(.malformedResponse) }
        if let transfer {
            if contentLengths.isEmpty == false { return .failure(.malformedResponse) }
            guard transfer.lowercased() == "chunked" else {
                return .failure(.unsupportedTransfer)
            }
        }
        if (300..<400).contains(status) {
            return .failure(.redirect(status: status, location: sanitizeLocation(location)))
        }
        if transfer != nil {
            phase = .chunked
            return .success(receipt)
        }
        if let length = contentLengths.first {
            if length > limits.maxBodyBytes {
                return .failure(.responseTooLarge)
            }
            contentLength = length
            phase = .contentLength
            return .success(receipt)
        }
        phase = .untilClose
        return .success(receipt)
    }

    private mutating func takeChunk() -> HTTPReadStep {
        switch chunk {
        case .size:
            guard let marker = buffer.range(of: Data("\r\n".utf8)) else {
                if buffer.count > 64 { return .failure(.malformedResponse) }
                return .needMore
            }
            let line = buffer[..<marker.lowerBound]
            if line.count > 16 || line.isEmpty { return .failure(.malformedResponse) }
            guard let text = String(bytes: line, encoding: .utf8), text.contains(";") == false,
                let size = Int(text, radix: 16), size >= 0
            else {
                return .failure(.malformedResponse)
            }
            buffer.removeSubrange(..<marker.upperBound)
            if size > limits.maxBodyBytes - body.count {
                return .failure(.responseTooLarge)
            }
            if size == 0 {
                chunk = .trailer
                return .success(receipt)
            }
            chunkRemaining = size
            chunk = .data
            return .success(receipt)
        case .data:
            if buffer.isEmpty { return .needMore }
            let take = min(chunkRemaining, buffer.count)
            appendBody(buffer.prefix(take))
            buffer.removeFirst(take)
            chunkRemaining -= take
            if body.count > limits.maxBodyBytes {
                return .failure(.responseTooLarge)
            }
            if chunkRemaining == 0 {
                chunk = .dataEnding
            }
            return .success(receipt)
        case .dataEnding:
            guard buffer.count >= 2 else { return .needMore }
            guard buffer.prefix(2) == Data("\r\n".utf8) else {
                return .failure(.malformedResponse)
            }
            buffer.removeFirst(2)
            chunk = .size
            return .success(receipt)
        case .trailer:
            if buffer.isEmpty { return .needMore }
            guard buffer.count >= 2 else { return .needMore }
            guard buffer.prefix(2) == Data("\r\n".utf8) else {
                return .failure(.malformedResponse)
            }
            buffer.removeFirst(2)
            phase = .done
            return .success(receipt)
        }
    }

    private var receipt: HTTPExecutionReceipt {
        HTTPExecutionReceipt(
            status: status,
            destination: destination.canonicalURL,
            headers: headers,
            body: body
        )
    }

    private mutating func appendBody(_ bytes: any Sequence<UInt8>) {
        let data = Data(bytes)
        let room = limits.maxBodyBytes + 1 - body.count
        if room <= 0 {
            return
        }
        if data.count <= room {
            body.append(data)
        } else {
            body.append(data.prefix(room))
        }
    }

    private mutating func parseStatus(_ line: String) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        guard parts[0] == "HTTP/1.0" || parts[0] == "HTTP/1.1" else { return false }
        guard parts[1].count == 3, let code = Int(parts[1]), (100..<600).contains(code) else {
            return false
        }
        status = code
        return true
    }

    private func parseHeader(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon])
        guard name.isEmpty == false, name.allSatisfy(isHeaderToken) else { return nil }
        var value = String(line[line.index(after: colon)...])
        value = value.trimmingCharacters(in: .whitespaces)
        if value.contains("\0") { return nil }
        return (name.lowercased(), value)
    }

    private func strictLength(_ text: String) -> Int? {
        guard text.count >= 1, text.count <= 12 else { return nil }
        if text.count > 1, text.first == "0" { return nil }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), value >= 0 else {
            return nil
        }
        return value
    }
}

private let returnedHeaderNames: Set<String> = [
    "accept-ranges",
    "cache-control",
    "content-encoding",
    "content-language",
    "content-length",
    "content-type",
    "date",
    "etag",
    "last-modified",
    "vary",
]

private func isHeaderToken(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return ascii > 32 && ascii < 127 && ascii != UInt8(ascii: ":")
}

private func sanitizeLocation(_ location: String?) -> String? {
    guard var text = location else { return nil }
    if text.contains("\r") || text.contains("\n") || text.contains("\0") { return nil }
    if let scheme = text.range(of: "://") {
        let authorityStart = scheme.upperBound
        let rest = text[authorityStart...]
        let authorityEnd = rest.firstIndex(of: "/") ?? text.endIndex
        let authority = text[authorityStart..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            text.removeSubrange(authorityStart...at)
        }
    }
    if text.count > 512 {
        text = String(text.prefix(512))
    }
    return text
}
