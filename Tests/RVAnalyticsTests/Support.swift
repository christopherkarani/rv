import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
@testable import RVAnalytics

actor RecordingAnalyticsSink: AnalyticsSink {
    private(set) var events: [AnalyticsPayload] = []

    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        events.append(payload)
        return .accepted
    }
}

actor FailingAnalyticsSink: AnalyticsSink {
    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        _ = payload
        return .dropped
    }
}

actor RecordingHTTPPoster: HTTPPosting {
    private(set) var count = 0
    private(set) var lastURL: URL?
    private(set) var lastContentType: String?
    private(set) var lastBody: Data = Data()

    func post(to url: URL, body: Data, contentType: String) async throws {
        lastURL = url
        lastBody = body
        lastContentType = contentType
        count += 1
    }
}

actor ThrowingHTTPPoster: HTTPPosting {
    func post(to url: URL, body: Data, contentType: String) async throws {
        _ = url
        _ = body
        _ = contentType
        throw AnalyticsTransportError.httpStatus(503)
    }
}

func temporaryConfigRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-analytics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = year
    components.month = month
    components.day = day
    return components.date ?? Date(timeIntervalSince1970: 0)
}

func expectNoCommandOrPath(_ payload: AnalyticsPayload, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        payload.properties.keys.contains("command") == false,
        sourceLocation: sourceLocation
    )
    #expect(
        payload.properties.keys.contains("path") == false,
        sourceLocation: sourceLocation
    )
    #expect(
        payload.properties.keys.contains("secret") == false,
        sourceLocation: sourceLocation
    )
}

struct LoopbackHTTPError: Error, Sendable {}

/// Loopback HTTP/1.1 listener for sink transport tests. Never leaves 127.0.0.1.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32

    private init(port: Int, listenFD: Int32) {
        self.port = port
        self.listenFD = listenFD
    }

    var origin: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    static func start(statusCode: Int) throws -> LoopbackHTTPServer {
#if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
#endif
        guard fd >= 0 else {
            throw LoopbackHTTPError()
        }
        var reuse: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw LoopbackHTTPError()
        }
        var named = sockaddr_in()
        var namedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedOK = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &namedLength)
            }
        }
        guard namedOK == 0 else {
            close(fd)
            throw LoopbackHTTPError()
        }
        let port = Int(UInt16(bigEndian: named.sin_port))
        let server = LoopbackHTTPServer(port: port, listenFD: fd)
        DispatchQueue.global().async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Self.reply(client: client, statusCode: statusCode)
                close(client)
            }
        }
        return server
    }

    func stop() {
        close(listenFD)
    }

    private static func reply(client: Int32, statusCode: Int) {
        var gathered = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while gathered.count < 65_536 {
            let readCount = read(client, &buffer, buffer.count)
            if readCount <= 0 { break }
            gathered.append(contentsOf: buffer.prefix(readCount))
            guard let headerEnd = gathered.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(data: gathered[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let length = contentLength(in: headerText)
            if gathered.count - headerEnd.upperBound >= length { break }
        }
        let reason = statusCode == 200 ? "OK" : "Error"
        let header =
            "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let response = Array(header.utf8)
        var written = 0
        response.withUnsafeBytes { raw in
            while written < response.count {
                let n = write(client, raw.baseAddress?.advanced(by: written), response.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    private static func contentLength(in headerText: String) -> Int {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "Content-Length:"
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            return Int(trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}
