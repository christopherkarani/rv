import Foundation

public protocol AnalyticsSink: Sendable {
    func capture(_ payload: AnalyticsPayload) async
}

public struct NoOpAnalyticsSink: AnalyticsSink {
    public init() {}

    public func capture(_ payload: AnalyticsPayload) async {
        _ = payload
    }
}

public protocol HTTPPosting: Sendable {
    func post(url: URL, body: Data, contentType: String) async throws
}

public struct URLSessionHTTPPoster: HTTPPosting {
    public init() {}

    public func post(url: URL, body: Data, contentType: String) async throws {
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

    public func capture(_ payload: AnalyticsPayload) async {
        guard apiKey.isEmpty == false else { return }
        guard let body = try? Self.encodeBatch(apiKey: apiKey, payload: payload) else { return }
        let url = host.appendingPathComponent("batch/")
        try? await poster.post(url: url, body: body, contentType: "application/json")
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
        guard JSONSerialization.isValidJSONObject(root) else {
            throw AnalyticsTransportError.encodingFailed
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}
