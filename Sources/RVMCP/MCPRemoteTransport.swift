import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Incremental `text/event-stream` parser (WHATWG server-sent events). An
/// event that is still open when the stream ends is dropped, as the spec says.
struct MCPEventStream {
    struct Event: Sendable, Equatable {
        var name: String
        var data: String
        var id: String?
    }

    static let maximumEventBytes = MCPGatewayRuntime.maximumLineBytes

    private var line: [UInt8] = []
    private var afterCR = false
    private var started = false
    private var name = ""
    private var data: [UInt8] = []
    private var hasData = false
    private var id: String?
    /// An event grew past the cap; the stream must be abandoned.
    private(set) var overflowed = false

    mutating func feed(_ bytes: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        for byte in bytes where overflowed == false {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                afterCR = true
                endLine(into: &events)
            case 0x0A:
                endLine(into: &events)
            default:
                line.append(byte)
                if line.count + data.count > Self.maximumEventBytes { overflowed = true }
            }
        }
        return events
    }

    private mutating func endLine(into events: inout [Event]) {
        defer { line.removeAll(keepingCapacity: true) }
        if started == false {
            started = true
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard line.isEmpty == false else {
            if hasData { events.append(Event(name: name.isEmpty ? "message" : name, data: String(decoding: data, as: UTF8.self), id: id)) }
            name = ""
            data.removeAll(keepingCapacity: true)
            hasData = false
            return
        }
        guard line.first != 0x3A else { return }
        let colon = line.firstIndex(of: 0x3A)
        let field = String(decoding: line[..<(colon ?? line.endIndex)], as: UTF8.self)
        var value = colon.map { line[line.index(after: $0)...] } ?? []
        if value.first == 0x20 { value = value.dropFirst() }
        switch field {
        case "event":
            name = String(decoding: value, as: UTF8.self)
        case "data":
            if hasData { data.append(0x0A) }
            data += value
            hasData = true
        case "id" where value.contains(0) == false:
            id = String(decoding: value, as: UTF8.self)
        default:
            break
        }
    }
}

/// The HTTP side of one remote upstream that does not need a socket:
/// building requests and turning replies and failures into JSON-RPC.
enum MCPHTTPExchange {
    static let maximumBodyBytes = MCPGatewayRuntime.maximumLineBytes
    static let requestTimeout: TimeInterval = 300

    static func request(
        url: URL, method: String, headers: [String: String], sessionID: String?, protocolVersion: String?, body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if method == "GET" {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        return request
    }

    /// A JSON body holds one message or a batch.
    static func messages(inJSON data: Data) -> [JSONValue]? {
        guard let value = try? JSONValue.parse(data) else { return nil }
        if let batch = value.arrayValue { return batch.filter { $0.objectValue != nil } }
        return value.objectValue == nil ? nil : [value]
    }

    static func isRequest(_ message: JSONValue) -> Bool {
        message["method"] != nil && message["id"] != nil
    }

    /// The JSON-RPC error the gateway core sees when a request got no answer.
    static func failure(for message: JSONValue, _ text: String) -> JSONValue? {
        guard isRequest(message), let id = message["id"] else { return nil }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(-32603), "message": .string(text)])])
    }

    /// Visible ASCII only (MCP transports spec), bounded.
    static func isSessionID(_ text: String) -> Bool {
        (1...512).contains(text.utf8.count) && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left == right
    }

    static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, key.lowercased() == wanted { return value as? String }
        }
        return nil
    }
}
