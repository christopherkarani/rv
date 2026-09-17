import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of handing an event to an analytics sink.
public enum AnalyticsDelivery: Sendable, Equatable {
    /// The sink accepted the event for transport.
    case accepted
    /// The sink dropped the event (no credentials, encode failure, or transport error).
    case dropped
}

public protocol AnalyticsSink: Sendable {
    /// Returns `.accepted` only when the event was accepted by the transport.
    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery
}

public struct NoOpAnalyticsSink: AnalyticsSink {
    public init() {}

    public func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        _ = payload
        return .dropped
    }
}

public protocol HTTPPosting: Sendable {
    func post(to url: URL, body: Data, contentType: String) async throws
}

public struct URLSessionHTTPPoster: HTTPPosting {
    public init() {}

    public func post(to url: URL, body: Data, contentType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw AnalyticsTransportError.httpStatus(http.statusCode)
        }
    }
}

public enum AnalyticsTransportError: Error, Sendable, Equatable {
    case httpStatus(Int)
    case encodingFailed
}

/// PostHog `/batch/` sink. Never logs payload contents.
public struct PostHogSink: AnalyticsSink {
    private let apiKey: String
    private let host: URL
    private let poster: any HTTPPosting

    public init(apiKey: String, host: URL = AnalyticsCredentials.defaultHost, poster: any HTTPPosting) {
        self.apiKey = apiKey
        self.host = host
        self.poster = poster
    }

    public func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        guard apiKey.isEmpty == false else { return .dropped }
        guard let body = try? Self.encodeBatch(apiKey: apiKey, payload: payload) else { return .dropped }
        let url = host.appendingPathComponent("batch/")
        do {
            try await poster.post(to: url, body: body, contentType: "application/json")
            return .accepted
        } catch {
            return .dropped
        }
    }

    package static func encodeBatch(apiKey: String, payload: AnalyticsPayload) throws -> Data {
        var properties: [String: Any] = ["distinct_id": payload.distinctID]
        for (key, value) in payload.properties {
            properties[key] = value.jsonObject
        }
        let root: [String: Any] = [
            "api_key": apiKey,
            "batch": [
                [
                    "event": payload.event,
                    "properties": properties,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }
}
