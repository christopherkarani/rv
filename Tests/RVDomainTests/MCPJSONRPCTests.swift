import Foundation
import Testing
import RVDomain

@Suite("MCPJSONRPC")
struct MCPJSONRPCTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    private func decode(_ json: String) -> Result<MCPJSONRPCInbound, MCPJSONRPCDecodeError> {
        MCPJSONRPCCodec.decode(body(json))
    }

    private func isMalformed(_ json: String) -> Bool {
        if case .failure(.malformed) = decode(json) { return true }
        return false
    }

    private func errorParts(_ text: String) -> (code: Int, message: String, id: JSONValue)? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body(text)) else {
            return nil
        }
        guard value["jsonrpc"]?.string == "2.0" else { return nil }
        guard let error = value["error"], let code = error["code"]?.int else { return nil }
        guard let message = error["message"]?.string else { return nil }
        return (code, message, value["id"] ?? .null)
    }

    // MARK: - Codec: requests

    @Test func decode_requestMinimal() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}")
        guard case .success(.request(let request)) = result else {
            Issue.record("expected request, got \(result)")
            return
        }
        #expect(request.id == .number(7))
        #expect(request.method == "tools/list")
        #expect(request.params == nil)
    }

    @Test func decode_requestStringIDAndParams() {
        let result = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"m\",\"params\":{\"a\":1,\"b\":\"x\"}}"
        )
        guard case .success(.request(let request)) = result else {
            Issue.record("expected request, got \(result)")
            return
        }
        #expect(request.id == .string("abc"))
        #expect(request.params?["a"] == .number(1))
        #expect(request.params?["b"] == .string("x"))
    }

    @Test func decode_requestUnknownKeyFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"extra\":true}"))
    }

    @Test func decode_requestWrongVersionFails() {
        #expect(isMalformed("{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"m\"}"))
    }

    @Test func decode_requestMissingVersionFails() {
        #expect(isMalformed("{\"id\":1,\"method\":\"m\"}"))
    }

    @Test func decode_requestMissingMethodFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1}"))
    }

    @Test func decode_requestFractionalIDFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"m\"}"))
    }

    @Test func decode_requestIntegralDoubleIDReadsAsInteger() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":1.0,\"method\":\"m\"}")
        guard case .success(.request(let request)) = result else {
            Issue.record("expected request, got \(result)")
            return
        }
        #expect(request.id == .number(1))
    }

    @Test func decode_requestNonScalarIDsFail() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"m\"}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"m\"}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"m\"}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":[1],\"method\":\"m\"}"))
    }

    @Test func decode_requestParamsMustBeObject() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":5}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":[1]}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":\"x\"}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":null}"))
    }

    @Test func decode_requestMethodLengthCap() {
        let ok = String(repeating: "m", count: 256)
        let over = String(repeating: "m", count: 257)
        guard case .success(.request(let request)) = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(ok)\"}"
        ) else {
            Issue.record("256-char method should decode")
            return
        }
        #expect(request.method == ok)
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(over)\"}"))
    }

    @Test func decode_requestStringIDLengthCap() {
        let ok = String(repeating: "i", count: 256)
        let over = String(repeating: "i", count: 257)
        guard case .success(.request(let request)) = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":\"\(ok)\",\"method\":\"m\"}"
        ) else {
            Issue.record("256-char id should decode")
            return
        }
        #expect(request.id == .string(ok))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":\"\(over)\",\"method\":\"m\"}"))
    }

    @Test func decode_requestEmptyMethodMirrorsSDK() {
        // The SDK's request schema accepts any string method; the codec does
        // not narrow it.
        guard case .success(.request(let request)) = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\"}"
        ) else {
            Issue.record("empty method should decode")
            return
        }
        #expect(request.method == "")
    }

    @Test func decode_requestIntegerIDs() {
        for (json, expected) in [
            ("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"m\"}", Int64(0)),
            ("{\"jsonrpc\":\"2.0\",\"id\":-3,\"method\":\"m\"}", Int64(-3)),
            ("{\"jsonrpc\":\"2.0\",\"id\":9223372036854775807,\"method\":\"m\"}", Int64.max),
        ] {
            guard case .success(.request(let request)) = decode(json) else {
                Issue.record("expected request for \(json)")
                continue
            }
            #expect(request.id == .number(expected))
        }
    }

    @Test func decode_requestIDBeyondInt64Fails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"method\":\"m\"}"))
    }

    @Test func decode_requestUnicodeRoundTrip() throws {
        let request = MCPJSONRPCRequest(
            id: .string("id-日本語🔧"), method: "tools/リスト🔧",
            params: ["q": .string("héllo 世界 🌊"), "n": .number(3)]
        )
        let data = try JSONEncoder().encode(request)
        guard case .success(.request(let back)) = MCPJSONRPCCodec.decode(data) else {
            Issue.record("unicode request should round-trip")
            return
        }
        #expect(back == request)
    }

    // MARK: - Codec: notifications

    @Test func decode_notificationMinimal() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        guard case .success(.notification(let notification)) = result else {
            Issue.record("expected notification, got \(result)")
            return
        }
        #expect(notification.method == "notifications/initialized")
        #expect(notification.params == nil)
    }

    @Test func decode_notificationWithParams() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":{\"a\":true}}")
        guard case .success(.notification(let notification)) = result else {
            Issue.record("expected notification, got \(result)")
            return
        }
        #expect(notification.params?["a"] == .bool(true))
    }

    @Test func decode_notificationUnknownKeyFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"extra\":1}"))
    }

    @Test func decode_notificationNullIDFails() {
        // An explicit null id is neither a request id nor a notification.
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"m\"}"))
    }

    @Test func decode_explicitNullsFailClosed() {
        // Only a missing key is absent; explicit null fails every optional.
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":null}"))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self,
                from: body("{\"code\":\"tool_blocked\",\"message\":\"m\",\"status\":null}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self, from: body("{\"ok\":true,\"data\":1,\"http\":null}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolErrorRecovery.self,
                from: body("{\"listConnectionsTool\":null}")
            )
        }
    }

    @Test func decode_notificationMissingMethodFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\"}"))
    }

    @Test func decode_notificationWrongVersionFails() {
        #expect(isMalformed("{\"jsonrpc\":\"1.0\",\"method\":\"m\"}"))
    }

    @Test func decode_notificationMethodLengthCap() {
        let over = String(repeating: "m", count: 257)
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"method\":\"\(over)\"}"))
    }

    // MARK: - Codec: responses

    @Test func decode_responseSuccessIntID() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"ok\":true}}")
        guard case .success(.response(let response)) = result else {
            Issue.record("expected response, got \(result)")
            return
        }
        #expect(response == .success(id: .number(9), result: .object(["ok": .bool(true)])))
    }

    @Test func decode_responseSuccessStringID() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"result\":[1,2]}")
        guard case .success(.response(let response)) = result else {
            Issue.record("expected response, got \(result)")
            return
        }
        #expect(response == .success(id: .string("r1"), result: .array([.number(1), .number(2)])))
    }

    @Test func decode_responseFailureNullID() {
        let result = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"boom\"}}"
        )
        guard case .success(.response(let response)) = result else {
            Issue.record("expected response, got \(result)")
            return
        }
        #expect(response == .failure(id: nil, error: MCPJSONRPCResponseError(
            code: -32603, message: "boom"
        )))
    }

    @Test func decode_responseFailureWithID() {
        let result = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"
        )
        guard case .success(.response(let response)) = result else {
            Issue.record("expected response, got \(result)")
            return
        }
        #expect(response == .failure(
            id: .number(4), error: MCPJSONRPCResponseError(code: -32601, message: "nope")
        ))
    }

    @Test func decode_responseBothResultAndErrorFails() {
        #expect(isMalformed(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{\"code\":1,\"message\":\"m\"}}"
        ))
    }

    @Test func decode_responseNeitherResultNorErrorFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1}"))
    }

    @Test func decode_responseMissingIDFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"result\":1}"))
    }

    @Test func decode_responseUnknownKeyFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"extra\":0}"))
    }

    @Test func decode_responseWrongVersionFails() {
        #expect(isMalformed("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":1}"))
    }

    @Test func decode_responseSuccessNullIDFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}"))
    }

    @Test func decode_responseErrorMessageLengthCap() {
        let ok = String(repeating: "e", count: 4_096)
        let over = String(repeating: "e", count: 4_097)
        guard case .success(.response(let response)) = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"\(ok)\"}}"
        ) else {
            Issue.record("4096-char message should decode")
            return
        }
        #expect(response == .failure(
            id: .number(1), error: MCPJSONRPCResponseError(code: 1, message: ok)
        ))
        #expect(isMalformed(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"\(over)\"}}"
        ))
    }

    @Test func decode_responseErrorShapeFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}"))
        #expect(isMalformed(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"x\",\"message\":\"m\"}}"
        ))
        #expect(isMalformed(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"m\",\"extra\":0}}"
        ))
    }

    // MARK: - Codec: batches and bodies

    @Test func decode_batchOfObjects() {
        let result = decode(
            "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"},{\"jsonrpc\":\"2.0\",\"method\":\"n\"}]"
        )
        guard case .success(.batch(let items)) = result else {
            Issue.record("expected batch, got \(result)")
            return
        }
        #expect(items.count == 2)
    }

    @Test func decode_batchEmptyFails() {
        #expect(isMalformed("[]"))
    }

    @Test func decode_batchItemCap() {
        let max = "[" + Array(repeating: "{}", count: 128).joined(separator: ",") + "]"
        let over = "[" + Array(repeating: "{}", count: 129).joined(separator: ",") + "]"
        guard case .success(.batch(let items)) = decode(max) else {
            Issue.record("128-item batch should decode")
            return
        }
        #expect(items.count == 128)
        #expect(isMalformed(over))
    }

    @Test func decode_batchNonObjectFails() {
        #expect(isMalformed("[5]"))
        #expect(isMalformed("[{\"a\":1},\"x\"]"))
        #expect(isMalformed("[[{\"a\":1}]]"))
        #expect(isMalformed("[null]"))
    }

    @Test func decode_scalarsFail() {
        #expect(isMalformed("5"))
        #expect(isMalformed("\"x\""))
        #expect(isMalformed("null"))
        #expect(isMalformed("true"))
    }

    @Test func decode_emptyFails() {
        let result = MCPJSONRPCCodec.decode(Data())
        #expect(result == .failure(.empty))
    }

    @Test func decode_oversizedFails() {
        let big = Data(repeating: 0x20, count: MCPJSONRPCLimits.maxBodyBytes + 1)
        #expect(MCPJSONRPCCodec.decode(big) == .failure(.oversized))
    }

    @Test func decode_unparseableFails() {
        #expect(isMalformed("not json"))
        #expect(isMalformed("{"))
        #expect(isMalformed("{\"jsonrpc\":"))
    }

    @Test func decode_trailingGarbageFails() {
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"} xxx"))
    }

    @Test func decode_bomPrefixFails() {
        // Strict parsers (Node, Go, Python) reject a BOM-prefixed document;
        // the codec refuses it rather than inheriting Foundation's tolerance.
        var data = Data([0xEF, 0xBB, 0xBF])
        data += body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"}")
        #expect(MCPJSONRPCCodec.decode(data) == .failure(.malformed))
        // A lone BOM is malformed, not empty; an oversized BOM body is still
        // oversized (rejection order: empty, oversized, BOM, depth).
        #expect(MCPJSONRPCCodec.decode(Data([0xEF, 0xBB, 0xBF])) == .failure(.malformed))
        var big = Data([0xEF, 0xBB, 0xBF])
        big += Data(repeating: 0x20, count: MCPJSONRPCLimits.maxBodyBytes)
        #expect(MCPJSONRPCCodec.decode(big) == .failure(.oversized))
        // U+FEFF inside a string is an ordinary character, not a BOM.
        guard case .success(.request(let request)) = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\u{FEFF}\"}"
        ) else {
            Issue.record("FEFF inside a string should decode")
            return
        }
        #expect(request.method == "m\u{FEFF}")
    }

    @Test func decode_whitespacePaddingOk() {
        let result = decode("  \n\t{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"} \r\n")
        guard case .success(.request(let request)) = result else {
            Issue.record("expected request, got \(result)")
            return
        }
        #expect(request.id == .number(1))
    }

    @Test func decode_deeplyNestedParams() {
        // 50 levels: deep enough to prove recursion, shallow enough for the
        // runner's small worker-thread stacks.
        let depth = 50
        let nested = String(repeating: "{\"a\":", count: depth) + "1"
            + String(repeating: "}", count: depth)
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":\(nested)}")
        guard case .success(.request(let request)) = result else {
            Issue.record("expected request, got \(result)")
            return
        }
        #expect(request.params?["a"] != nil)
    }

    @Test func decode_unequalInboundsDiffer() {
        let request = MCPJSONRPCInbound.request(MCPJSONRPCRequest(id: .number(1), method: "m"))
        let notification = MCPJSONRPCInbound.notification(MCPJSONRPCNotification(method: "m"))
        #expect(request != notification)
        #expect(request == MCPJSONRPCInbound.request(MCPJSONRPCRequest(id: .number(1), method: "m")))
    }

    // MARK: - Codec: encoding

    @Test func encode_requestOmitsNilParams() throws {
        let data = try JSONEncoder().encode(MCPJSONRPCRequest(id: .number(1), method: "m"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"params\"") == false)
        let back = try JSONDecoder().decode(MCPJSONRPCRequest.self, from: data)
        #expect(back == MCPJSONRPCRequest(id: .number(1), method: "m"))
    }

    @Test func encode_requestIncludesParams() throws {
        let request = MCPJSONRPCRequest(
            id: .string("s"), method: "m", params: ["k": .string("v")]
        )
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"params\""))
        #expect(try JSONDecoder().decode(MCPJSONRPCRequest.self, from: data) == request)
    }

    @Test func encode_notificationParams() throws {
        let bare = MCPJSONRPCNotification(method: "m")
        let bareText = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(bareText.contains("\"params\"") == false)
        let full = MCPJSONRPCNotification(method: "m", params: ["k": .null])
        let fullData = try JSONEncoder().encode(full)
        #expect(String(decoding: fullData, as: UTF8.self).contains("\"params\""))
        #expect(try JSONDecoder().decode(MCPJSONRPCNotification.self, from: fullData) == full)
        #expect(bare != full)
    }

    @Test func encode_responseRoundTrips() throws {
        let success = MCPJSONRPCResponse.success(id: .number(2), result: .number(42))
        let successData = try JSONEncoder().encode(success)
        #expect(try JSONDecoder().decode(MCPJSONRPCResponse.self, from: successData) == success)
        let failure = MCPJSONRPCResponse.failure(
            id: nil, error: MCPJSONRPCResponseError(code: -32603, message: "boom")
        )
        let failureData = try JSONEncoder().encode(failure)
        #expect(String(decoding: failureData, as: UTF8.self).contains("\"id\":null"))
        #expect(try JSONDecoder().decode(MCPJSONRPCResponse.self, from: failureData) == failure)
        let failureID = MCPJSONRPCResponse.failure(
            id: .string("x"), error: MCPJSONRPCResponseError(code: 1, message: "m")
        )
        let failureIDData = try JSONEncoder().encode(failureID)
        #expect(try JSONDecoder().decode(MCPJSONRPCResponse.self, from: failureIDData) == failureID)
        #expect(success != failure)
    }

    // MARK: - Renderer

    @Test func render_defaultShapeIsByteIdentical() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 405, code: -32001, message: "Method not allowed"
        )
        #expect(response.httpStatus == 405)
        #expect(response.body
            == "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Method not allowed\"},\"id\":null}")
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.headers["access-control-allow-origin"] == "*")
        #expect(response.headers["www-authenticate"] == nil)
        #expect(response.headers["retry-after"] == nil)
        #expect(errorParts(response.body)?.code == -32001)
    }

    @Test func render_innerOmitsCORS() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 200, code: -32601, message: "Method not found", cors: false, id: .number(3)
        )
        #expect(response.headers["access-control-allow-origin"] == nil)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.body.hasSuffix("\"id\":3}"))
    }

    @Test func render_challengeAddsHeaders() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 401, code: -32001, message: "Unauthorized",
            challenge: "Bearer realm=\"mcp\""
        )
        #expect(response.headers["www-authenticate"] == "Bearer realm=\"mcp\"")
        #expect(response.headers["access-control-expose-headers"] == "WWW-Authenticate")
        #expect(response.headers["access-control-allow-origin"] == "*")
    }

    @Test func render_retryAfterAddsHeader() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 503, code: -32001, message: "down", retryAfterSeconds: 2
        )
        #expect(response.headers["retry-after"] == "2")
    }

    @Test func render_idEcho() {
        let number = MCPJSONRPCErrorRenderer.render(
            status: 200, code: -32601, message: "Method not found", id: .number(7)
        )
        #expect(errorParts(number.body)?.id == .number(7))
        let string = MCPJSONRPCErrorRenderer.render(
            status: 200, code: -32601, message: "Method not found", id: .string("a\"b")
        )
        #expect(errorParts(string.body)?.id == .string("a\"b"))
        #expect(string.body.contains("\"id\":\"a\\\"b\"}"))
    }

    @Test func render_escapeMegaMessage() {
        let message = "\"\\/\n\r\t\u{08}\u{0C}\u{0001}\u{001F}héllo🔧"
        let response = MCPJSONRPCErrorRenderer.render(status: 500, code: -32603, message: message)
        #expect(response.body.contains("\\\""))
        #expect(response.body.contains("\\\\"))
        #expect(response.body.contains("\\n"))
        #expect(response.body.contains("\\r"))
        #expect(response.body.contains("\\t"))
        #expect(response.body.contains("\\b"))
        #expect(response.body.contains("\\f"))
        #expect(response.body.contains("\\u0001"))
        #expect(response.body.contains("\\u001f"))
        #expect(response.body.contains("héllo🔧"))
        #expect(errorParts(response.body)?.message == message)
    }

    @Test func render_emptyMessage() {
        let response = MCPJSONRPCErrorRenderer.render(status: 403, code: -32001, message: "")
        #expect(response.body.contains("\"message\":\"\""))
        #expect(errorParts(response.body)?.message == "")
    }

    @Test func render_delPassesThroughRaw() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 500, code: -32603, message: "a\u{7F}b"
        )
        #expect(response.body.contains("a\u{7F}b"))
        #expect(errorParts(response.body)?.message == "a\u{7F}b")
    }

    @Test func render_executorSites() {
        let methodNotAllowed = MCPJSONRPCErrorRenderer.methodNotAllowed()
        #expect(methodNotAllowed.httpStatus == 405)
        #expect(errorParts(methodNotAllowed.body)?.code == -32001)
        #expect(errorParts(methodNotAllowed.body)?.message == "Method not allowed")
        #expect(methodNotAllowed.headers["access-control-allow-origin"] == "*")

        let unauthorized = MCPJSONRPCErrorRenderer.unauthorized(challenge: "Bearer x")
        #expect(unauthorized.httpStatus == 401)
        #expect(errorParts(unauthorized.body)?.message == "Unauthorized")
        #expect(unauthorized.headers["www-authenticate"] == "Bearer x")

        let forbidden = MCPJSONRPCErrorRenderer.forbidden(message: "nope")
        #expect(forbidden.httpStatus == 403)
        #expect(errorParts(forbidden.body)?.code == -32001)
        #expect(errorParts(forbidden.body)?.message == "nope")
        #expect(errorParts(forbidden.body)?.id == .null)

        let unavailable = MCPJSONRPCErrorRenderer.unavailable(message: "blip")
        #expect(unavailable.httpStatus == 503)
        #expect(errorParts(unavailable.body)?.code == -32001)
        #expect(unavailable.headers["retry-after"] == "2")

        let ownership = MCPJSONRPCErrorRenderer.sessionOwnership()
        #expect(ownership.httpStatus == 403)
        #expect(errorParts(ownership.body)?.code == -32003)
        #expect(errorParts(ownership.body)?.message
            == "MCP session does not belong to the current bearer")

        let sse = MCPJSONRPCErrorRenderer.sessionIDRequiredForSSE()
        #expect(sse.httpStatus == 400)
        #expect(errorParts(sse.body)?.code == -32000)
        #expect(errorParts(sse.body)?.message == "mcp-session-id header required for SSE")

        let notFound = MCPJSONRPCErrorRenderer.methodNotFound(id: .string("k"))
        #expect(notFound.httpStatus == 200)
        #expect(errorParts(notFound.body)?.code == -32601)
        #expect(errorParts(notFound.body)?.message == "Method not found")
        #expect(errorParts(notFound.body)?.id == .string("k"))
        #expect(notFound.headers["access-control-allow-origin"] == nil)

        let internalError = MCPJSONRPCErrorRenderer.internalError()
        #expect(internalError.httpStatus == 500)
        #expect(errorParts(internalError.body)?.code == -32603)
        #expect(errorParts(internalError.body)?.message == "Internal server error")

        #expect(MCPJSONRPCErrorCode.sessionIDRequired.rawValue == -32000)
        #expect(MCPJSONRPCErrorCode.authSession.rawValue == -32001)
        #expect(MCPJSONRPCErrorCode.sessionOwnership.rawValue == -32003)
        #expect(MCPJSONRPCErrorCode.methodNotFound.rawValue == -32601)
        #expect(MCPJSONRPCErrorCode.internalError.rawValue == -32603)
        #expect(MCPJSONRPCLimits.unavailableRetryAfterSeconds == 2)
    }

    @Test func render_forbiddenCustomCode() {
        let response = MCPJSONRPCErrorRenderer.forbidden(message: "m", code: -32003)
        #expect(errorParts(response.body)?.code == -32003)
    }

    @Test func render_sessionNotFoundByMethod() {
        for method in ["POST", "DELETE"] {
            let response = MCPJSONRPCErrorRenderer.sessionNotFound(method: method)
            #expect(response.httpStatus == 404)
            #expect(errorParts(response.body)?.code == -32001)
            #expect(errorParts(response.body)?.message == "Session not found")
            #expect(response.headers["access-control-allow-origin"] == "*")
        }
        let get = MCPJSONRPCErrorRenderer.sessionNotFound(method: "GET")
        #expect(get.httpStatus == 405)
        #expect(errorParts(get.body)?.code == -32001)
        #expect(errorParts(get.body)?.message == "Session not found")
        #expect(get.headers["allow"] == "POST, DELETE")
        #expect(get.headers["access-control-allow-origin"] == nil)
    }

    @Test func render_defaultChallenge() {
        #expect(MCPJSONRPCErrorRenderer.defaultChallenge(
            resourceMetadataURL: "https://host.test/.well-known/oauth-protected-resource"
        ) == "Bearer realm=\"mcp\", resource_metadata=\"https://host.test/.well-known/oauth-protected-resource\"")
    }

    @Test func render_preflight() {
        let response = MCPJSONRPCErrorRenderer.corsPreflight()
        #expect(response.httpStatus == 204)
        #expect(response.body == "")
        #expect(response.headers["access-control-allow-origin"] == "*")
        #expect(response.headers["access-control-allow-methods"] == "GET, POST, DELETE, OPTIONS")
        #expect(response.headers["access-control-allow-headers"]
            == "content-type, authorization, mcp-session-id, accept, mcp-protocol-version")
        #expect(response.headers["access-control-expose-headers"] == "mcp-session-id, WWW-Authenticate")
    }

    @Test func render_sessionlessDelete() {
        let response = MCPJSONRPCErrorRenderer.sessionlessDelete()
        #expect(response.httpStatus == 204)
        #expect(response.body == "")
        #expect(response.headers == ["access-control-allow-origin": "*"])
    }

    @Test func render_responsesDiffer() {
        #expect(MCPJSONRPCErrorRenderer.internalError() != MCPJSONRPCErrorRenderer.methodNotAllowed())
    }

    // MARK: - Method gate

    @Test func gate_optionsPreflight() {
        let verdict = MCPHTTPMethodGate.evaluate(method: "OPTIONS")
        #expect(verdict == .preflight(MCPJSONRPCErrorRenderer.corsPreflight()))
    }

    @Test func gate_allowedMethods() {
        #expect(MCPHTTPMethodGate.evaluate(method: "GET") == .allowed)
        #expect(MCPHTTPMethodGate.evaluate(method: "POST") == .allowed)
        #expect(MCPHTTPMethodGate.evaluate(method: "DELETE") == .allowed)
        #expect(MCPHTTPMethodGate.allowedMethods == ["GET", "POST", "DELETE", "OPTIONS"])
    }

    @Test func gate_rejectsOthers() {
        for method in ["PUT", "PATCH", "HEAD", "get", "", "POST ", " TRACE"] {
            let verdict = MCPHTTPMethodGate.evaluate(method: method)
            guard case .rejected(let response) = verdict else {
                Issue.record("\(method) should reject")
                continue
            }
            #expect(response.httpStatus == 405)
            #expect(errorParts(response.body)?.code == -32001)
        }
    }

    @Test func gate_verdictsDiffer() {
        #expect(MCPHTTPMethodGate.Verdict.allowed != .preflight(MCPJSONRPCErrorRenderer.corsPreflight()))
        #expect(MCPHTTPMethodGate.Verdict.allowed
            != .rejected(MCPJSONRPCErrorRenderer.methodNotAllowed()))
    }

    // MARK: - Pipeline

    private final class CallLog: @unchecked Sendable {
        var calls: [String] = []
        func auth(_ outcome: MCPAuthOutcome) -> MCPAuthOutcome {
            calls.append("auth")
            return outcome
        }
        func dispatch(_ verdict: MCPDispatchVerdict) -> MCPDispatchVerdict {
            calls.append("dispatch")
            return verdict
        }
    }

    @Test func pipeline_methodRejectSkipsAuthAndDispatch() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "PUT", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: log.auth(.unauthorized(challenge: nil)), dispatch: log.dispatch(.handled)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.httpStatus == 405)
        #expect(log.calls == [])
    }

    @Test func pipeline_optionsSkipsAuthAndDispatch() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "OPTIONS", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: log.auth(.authenticated), dispatch: log.dispatch(.handled)
        )
        #expect(decision == .respond(MCPJSONRPCErrorRenderer.corsPreflight()))
        #expect(log.calls == [])
    }

    @Test func pipeline_unauthorizedDefaultChallenge() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: nil, resourceMetadataURL: "https://h/meta",
            auth: log.auth(.unauthorized(challenge: nil)), dispatch: log.dispatch(.handled)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.httpStatus == 401)
        #expect(response.headers["www-authenticate"]
            == "Bearer realm=\"mcp\", resource_metadata=\"https://h/meta\"")
        #expect(log.calls == ["auth"])
    }

    @Test func pipeline_unauthorizedExplicitChallenge() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "s", resourceMetadataURL: "https://h/meta",
            auth: log.auth(.unauthorized(challenge: "Bearer custom")),
            dispatch: log.dispatch(.handled)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.headers["www-authenticate"] == "Bearer custom")
        #expect(log.calls == ["auth"])
    }

    @Test func pipeline_forbiddenCodes() {
        let log = CallLog()
        let implicit = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "s", resourceMetadataURL: "https://h/m",
            auth: log.auth(.forbidden(code: nil, message: "nope")),
            dispatch: log.dispatch(.handled)
        )
        guard case .respond(let implicitResponse) = implicit else {
            Issue.record("expected respond")
            return
        }
        #expect(errorParts(implicitResponse.body)?.code == -32001)
        let explicit = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "s", resourceMetadataURL: "https://h/m",
            auth: log.auth(.forbidden(code: -32003, message: "mine")),
            dispatch: log.dispatch(.forbidden)
        )
        guard case .respond(let explicitResponse) = explicit else {
            Issue.record("expected respond")
            return
        }
        #expect(errorParts(explicitResponse.body)?.code == -32003)
        #expect(log.calls == ["auth", "auth"])
    }

    @Test func pipeline_unavailable() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "DELETE", sessionID: "s", resourceMetadataURL: "https://h/m",
            auth: log.auth(.unavailable(message: "idp blip")),
            dispatch: log.dispatch(.handled)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.httpStatus == 503)
        #expect(response.headers["retry-after"] == "2")
        #expect(log.calls == ["auth"])
    }

    @Test func pipeline_sessionlessShortCircuits() {
        let getLog = CallLog()
        let get = MCPEnvelopePipeline.decide(
            method: "GET", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: getLog.auth(.authenticated), dispatch: getLog.dispatch(.handled)
        )
        guard case .respond(let getResponse) = get else {
            Issue.record("expected respond")
            return
        }
        #expect(getResponse.httpStatus == 400)
        #expect(errorParts(getResponse.body)?.code == -32000)
        #expect(getLog.calls == ["auth"])

        let deleteLog = CallLog()
        let delete = MCPEnvelopePipeline.decide(
            method: "DELETE", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: deleteLog.auth(.authenticated), dispatch: deleteLog.dispatch(.handled)
        )
        #expect(delete == .respond(MCPJSONRPCErrorRenderer.sessionlessDelete()))
        #expect(deleteLog.calls == ["auth"])

        let postLog = CallLog()
        let post = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: postLog.auth(.authenticated), dispatch: postLog.dispatch(.handled)
        )
        #expect(post == .dispatch)
        #expect(postLog.calls == ["auth", "dispatch"])
    }

    @Test func pipeline_authRunsBeforeSessionCheck() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "GET", sessionID: nil, resourceMetadataURL: "https://h/m",
            auth: log.auth(.unauthorized(challenge: nil)), dispatch: log.dispatch(.handled)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.httpStatus == 401)
        #expect(log.calls == ["auth"])
    }

    @Test func pipeline_dispatchNotFoundByMethod() {
        for (method, status) in [("POST", 404), ("DELETE", 404), ("GET", 405)] {
            let log = CallLog()
            let decision = MCPEnvelopePipeline.decide(
                method: method, sessionID: "s", resourceMetadataURL: "https://h/m",
                auth: log.auth(.authenticated), dispatch: log.dispatch(.notFound)
            )
            guard case .respond(let response) = decision else {
                Issue.record("expected respond for \(method)")
                continue
            }
            #expect(response.httpStatus == status)
            #expect(log.calls == ["auth", "dispatch"])
        }
    }

    @Test func pipeline_dispatchForbidden() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "s", resourceMetadataURL: "https://h/m",
            auth: log.auth(.authenticated), dispatch: log.dispatch(.forbidden)
        )
        guard case .respond(let response) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(response.httpStatus == 403)
        #expect(errorParts(response.body)?.code == -32003)
        #expect(log.calls == ["auth", "dispatch"])
    }

    @Test func pipeline_authenticatedWithSessionDispatches() {
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "GET", sessionID: "s", resourceMetadataURL: "https://h/m",
            auth: log.auth(.authenticated), dispatch: log.dispatch(.handled)
        )
        #expect(decision == .dispatch)
        #expect(log.calls == ["auth", "dispatch"])
    }

    @Test func pipeline_decisionsDiffer() {
        #expect(MCPEnvelopeDecision.dispatch != .respond(MCPJSONRPCErrorRenderer.internalError()))
        #expect(MCPAuthOutcome.authenticated != .unavailable(message: "x"))
        #expect(MCPDispatchVerdict.handled != .notFound)
    }

    // MARK: - Pre-initialize guard

    private var guardAccept: String { "application/json, text/event-stream" }
    private var guardContentType: String { "application/json" }

    @Test func guard_firesOnUnknownMethod() {
        let response = MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"server/discover\",\"params\":{}}")
        )
        guard let response else {
            Issue.record("guard should fire")
            return
        }
        #expect(response.httpStatus == 200)
        #expect(errorParts(response.body)?.code == -32601)
        #expect(errorParts(response.body)?.message == "Method not found")
        #expect(errorParts(response.body)?.id == .number(7))
        #expect(response.headers["access-control-allow-origin"] == nil)
        #expect(response.headers["content-type"] == "application/json")
    }

    @Test func guard_firesOnAnyMethodWithStringID() {
        let response = MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"some/futureProbe\"}")
        )
        #expect(errorParts(response?.body ?? "")?.id == .string("abc"))
        #expect(response?.httpStatus == 200)
    }

    @Test func guard_letsInitializeThrough() {
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")
        ) == nil)
    }

    @Test func guard_letsNonRequestsThrough() {
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        ) == nil)
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}]")
        ) == nil)
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
        ) == nil)
    }

    @Test func guard_nonPOSTFallsThrough() {
        let probe = body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        for method in ["GET", "PUT", "DELETE", "OPTIONS"] {
            #expect(MCPPreInitializeGuard.evaluate(
                method: method, accept: guardAccept, contentType: guardContentType, body: probe
            ) == nil)
        }
    }

    @Test func guard_badBodiesFallThrough() {
        let bodies = [
            "not json",
            "",
            "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"server/discover\"}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":5}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"extra\":true}",
            "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"server/discover\"}",
            "[1,2]",
        ]
        for json in bodies {
            #expect(MCPPreInitializeGuard.evaluate(
                method: "POST", accept: guardAccept, contentType: guardContentType,
                body: body(json)
            ) == nil)
        }
        let big = Data(repeating: 0x7B, count: MCPJSONRPCLimits.maxBodyBytes + 1)
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType, body: big
        ) == nil)
    }

    @Test func guard_negotiationMatrix() {
        let probe = body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: guardAccept, contentType: "text/plain"
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: guardAccept, contentType: nil
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: "application/json", contentType: guardContentType
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: "text/event-stream", contentType: guardContentType
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: nil, contentType: guardContentType
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: nil, contentType: nil
        ) == false)
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: guardAccept, contentType: guardContentType
        ) == true)
        // Each negotiation miss falls through end to end.
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: "application/json", contentType: guardContentType, body: probe
        ) == nil)
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: "text/plain", body: probe
        ) == nil)
    }

    @Test func guard_headersWithParametersFire() {
        let response = MCPPreInitializeGuard.evaluate(
            method: "POST", accept: "application/json;q=0.9, text/event-stream;q=1.0",
            contentType: "application/json; charset=utf-8",
            body: body("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\"}")
        )
        #expect(response?.httpStatus == 200)
    }

    @Test func guard_matchingIsCaseSensitive() {
        let probe = body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: "Application/JSON, Text/Event-Stream",
            contentType: guardContentType, body: probe
        ) == nil)
    }

    @Test func guard_bodyIsNotConsumed() {
        let probe = body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        let before = probe
        _ = MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType, body: probe
        )
        #expect(probe == before)
    }

    // MARK: - ToolError codes

    @Test func codes_rawValuesExact() {
        let raw = Dictionary(uniqueKeysWithValues: MCPToolErrorCode.allCases.map { ($0, $0.rawValue) })
        #expect(raw.count == 10)
        #expect(raw[.toolNotFound] == "tool_not_found")
        #expect(raw[.toolBlocked] == "tool_blocked")
        #expect(raw[.invalidToolArguments] == "invalid_tool_arguments")
        #expect(raw[.bindingError] == "binding_error")
        #expect(raw[.connectionValueMissing] == "connection_value_missing")
        #expect(raw[.connectionRejected] == "connection_rejected")
        #expect(raw[.oauthConnectionMissing] == "oauth_connection_missing")
        #expect(raw[.oauthRefreshFailed] == "oauth_refresh_failed")
        #expect(raw[.oauthReauthRequired] == "oauth_reauth_required")
        #expect(raw[.oauthScopeInsufficient] == "oauth_scope_insufficient")
    }

    @Test func codes_retryableFalseAndAuthSplit() {
        let auth: Set<MCPToolErrorCode> = [
            .connectionValueMissing, .connectionRejected, .oauthConnectionMissing,
            .oauthRefreshFailed, .oauthReauthRequired, .oauthScopeInsufficient,
        ]
        #expect(auth.count == 6)
        for code in MCPToolErrorCode.allCases {
            #expect(code.retryable == false)
            #expect(code.isAuthentication == auth.contains(code))
        }
    }

    @Test func factory_toolNotFound() throws {
        let error = MCPToolError.toolNotFound(path: "missing.main.tool", suggestions: ["a", "b"])
        #expect(error.code == .toolNotFound)
        #expect(error.message == "Tool not found: missing.main.tool")
        #expect(error.retryable == false)
        #expect(error.status == nil)
        #expect(error.details == .toolNotFound(MCPToolNotFoundDetails(
            path: "missing.main.tool", suggestions: ["a", "b"]
        )))
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MCPToolError.self, from: data) == error)
    }

    @Test func factory_toolBlocked() throws {
        let error = MCPToolError.toolBlocked(path: "p.tool", pattern: "p.*")
        #expect(error.code == .toolBlocked)
        #expect(error.message == "Tool blocked by policy: p.tool")
        #expect(error.details == .toolBlocked(MCPToolBlockedDetails(path: "p.tool", pattern: "p.*")))
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MCPToolError.self, from: data) == error)
        #expect(MCPToolError.toolBlocked(path: "p.tool", pattern: "other") != error)
    }

    @Test func factory_invalidArguments() throws {
        let issues: [JSONValue] = [
            .object(["path": .array([.string("owner")]), "message": .string("Missing key")]),
        ]
        let error = MCPToolError.invalidArguments(issues: issues)
        #expect(error.code == .invalidToolArguments)
        #expect(error.message == "Tool arguments did not match the input schema.")
        #expect(error.details == .invalidArguments(MCPInvalidArgumentsDetails(issues: issues)))
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MCPToolError.self, from: data) == error)

        let preflight = MCPToolError.invalidArgumentsPreflight(message: "missing path param id")
        #expect(preflight.code == .invalidToolArguments)
        #expect(preflight.message == "missing path param id")
        #expect(preflight.details == nil)
        #expect(preflight != error)
    }

    @Test func factory_binding() {
        let full = MCPToolError.binding(
            message: "unknown connection \"personal\" for role \"github\" (github)",
            role: "github", integration: "github", requestedConnection: "personal"
        )
        #expect(full.code == .bindingError)
        #expect(full.message == "unknown connection \"personal\" for role \"github\" (github)")
        #expect(full.details == .binding(MCPBindingDetails(
            role: "github", integration: "github", requestedConnection: "personal"
        )))

        let fallback = MCPToolError.binding(message: nil, role: "r")
        #expect(fallback.message == "Tool binding failed.")

        #expect(MCPToolError.binding(message: "m").details == nil)
        #expect(MCPToolError.binding(message: "m", role: "r").details != nil)
        #expect(MCPToolError.binding(message: "m", integration: "i").details != nil)
        #expect(MCPToolError.binding(message: "m", requestedConnection: "c").details != nil)
        #expect(full != fallback)
    }

    @Test func factory_authenticationStandard() throws {
        let error = MCPToolError.authentication(
            code: .connectionRejected, message: "token dead", status: 401,
            integration: MCPAuthIntegration(id: "github", scope: "repo"),
            credential: MCPAuthCredential(kind: .oauth, label: "github.org.main"),
            upstream: MCPAuthUpstream(status: 401)
        )
        #expect(error.code == .connectionRejected)
        #expect(error.status == 401)
        guard case .authentication(let details) = error.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(details.category == "authentication")
        #expect(details.integration == MCPAuthIntegration(id: "github", scope: "repo"))
        #expect(details.credential == MCPAuthCredential(kind: .oauth, label: "github.org.main"))
        #expect(details.upstream == MCPAuthUpstream(status: 401))
        #expect(details.recovery.createConnectionTool
            == "executor.coreTools.connections.createHandoff")
        #expect(details.recovery.startOAuthTool == "executor.coreTools.oauth.start")
        #expect(details.recovery.listConnectionsTool == "executor.coreTools.connections.list")
        #expect(details.recovery.configureIntegrationTool == nil)
        #expect(details.recovery.connectionInstructions
            == MCPToolErrorRecovery.connectionInstructionsText)
        #expect(details.recovery.oauthInstructions == MCPToolErrorRecovery.oauthInstructionsText)
        #expect(details.recovery.scopeInstructions == nil)
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MCPToolError.self, from: data) == error)

        let configured = MCPToolError.authentication(
            code: .connectionValueMissing, message: "m", configureIntegrationTool: "cfg.tool"
        )
        guard case .authentication(let configuredDetails) = configured.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(configuredDetails.recovery.configureIntegrationTool == "cfg.tool")
        #expect(configured != error)
    }

    @Test func factory_authenticationScopeBranch() throws {
        let error = MCPToolError.authentication(
            code: .oauthScopeInsufficient, message: "denied", status: 403
        )
        guard case .authentication(let details) = error.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(details.recovery.createConnectionTool == nil)
        #expect(details.recovery.startOAuthTool == nil)
        #expect(details.recovery.listConnectionsTool == "executor.coreTools.connections.list")
        #expect(details.recovery.connectionInstructions == nil)
        #expect(details.recovery.oauthInstructions == nil)
        #expect(details.recovery.scopeInstructions == MCPToolErrorRecovery.scopeInstructionsText)
        let text = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(text.contains("startOAuthTool") == false)
        #expect(text.contains("createConnectionTool") == false)
        #expect(text.contains("scopeInstructions"))

        let configured = MCPToolError.authentication(
            code: .oauthScopeInsufficient, message: "denied", configureIntegrationTool: "cfg.tool"
        )
        guard case .authentication(let configuredDetails) = configured.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(configuredDetails.recovery.configureIntegrationTool == "cfg.tool")
    }

    @Test func factory_oauthBuilders() {
        let reauth = MCPToolError.oauthReauthRequired(
            label: "db.org.main", message: "Refresh token expired", oauthErrorCode: "invalid_grant"
        )
        #expect(reauth.code == .oauthReauthRequired)
        #expect(reauth.message
            == "OAuth connection \"db.org.main\" requires reauthorization: Refresh token expired")
        guard case .authentication(let reauthDetails) = reauth.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(reauthDetails.credential?.kind == .oauth)
        #expect(reauthDetails.credential?.label == "db.org.main")
        #expect(reauthDetails.upstream?.details?["oauthErrorCode"] == .string("invalid_grant"))

        let refresh = MCPToolError.oauthRefreshFailed(label: "db.org.main", message: "boom")
        #expect(refresh.code == .oauthRefreshFailed)
        #expect(refresh.message == "OAuth connection \"db.org.main\" could not be resolved: boom")
        guard case .authentication(let refreshDetails) = refresh.details else {
            Issue.record("expected authentication details")
            return
        }
        #expect(refreshDetails.upstream == nil)
        #expect(refresh != reauth)
    }

    @Test func refreshTrigger_exact() {
        #expect(MCPToolError.isUnauthorizedRefreshTrigger(
            MCPToolError(code: .connectionRejected, message: "m", status: 401)
        ) == true)
        #expect(MCPToolError.isUnauthorizedRefreshTrigger(
            MCPToolError(code: .connectionRejected, message: "m", status: 403)
        ) == false)
        #expect(MCPToolError.isUnauthorizedRefreshTrigger(
            MCPToolError(code: .connectionRejected, message: "m")
        ) == false)
        #expect(MCPToolError.isUnauthorizedRefreshTrigger(
            MCPToolError(code: .oauthScopeInsufficient, message: "m", status: 401)
        ) == false)
        #expect(MCPToolError.isUnauthorizedRefreshTrigger(
            MCPToolError(code: .toolNotFound, message: "m", status: 401)
        ) == false)
    }

    @Test func toolError_strictCoding() throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self,
                from: body("{\"code\":\"tool_blocked\",\"message\":\"m\",\"retryable\":false,\"extra\":1}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self,
                from: body("{\"code\":\"nope\",\"message\":\"m\",\"retryable\":false}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self, from: body("{\"code\":\"tool_blocked\",\"retryable\":false}")
            )
        }
        // Absent retryable reads as the code default; explicit true survives.
        let implicit = try JSONDecoder().decode(
            MCPToolError.self, from: body("{\"code\":\"tool_blocked\",\"message\":\"m\"}")
        )
        #expect(implicit.retryable == false)
        #expect(implicit.status == nil)
        #expect(implicit.details == nil)
        let explicit = try JSONDecoder().decode(
            MCPToolError.self,
            from: body("{\"code\":\"tool_blocked\",\"message\":\"m\",\"retryable\":true}")
        )
        #expect(explicit.retryable == true)
    }

    @Test func details_discrimination() throws {
        let shapes: [MCPToolErrorDetails] = [
            .toolNotFound(MCPToolNotFoundDetails(path: "p", suggestions: ["s"])),
            .toolBlocked(MCPToolBlockedDetails(path: "p", pattern: "pat")),
            .invalidArguments(MCPInvalidArgumentsDetails(issues: [.string("i")])),
            .binding(MCPBindingDetails(role: "r")),
            .authentication(MCPAuthFailureDetails(recovery: .standard())),
        ]
        for details in shapes {
            let data = try JSONEncoder().encode(details)
            #expect(try JSONDecoder().decode(MCPToolErrorDetails.self, from: data) == details)
        }
        // Absent suggestions read as empty.
        let bare = try JSONDecoder().decode(
            MCPToolErrorDetails.self, from: body("{\"path\":\"p\"}")
        )
        #expect(bare == .toolNotFound(MCPToolNotFoundDetails(path: "p", suggestions: [])))
        // A bare object reads as empty binding details, deterministically.
        let empty = try JSONDecoder().decode(MCPToolErrorDetails.self, from: body("{}"))
        #expect(empty == .binding(MCPBindingDetails()))
        // Unknown shapes fail every arm.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolErrorDetails.self, from: body("{\"nope\":1}"))
        }
        // Wrong category fails the authentication arm (and every other arm).
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolErrorDetails.self,
                from: body("{\"category\":\"auth\",\"recovery\":{}}")
            )
        }
    }

    @Test func details_structsRoundTrip() throws {
        let integration = MCPAuthIntegration(id: "i", scope: "s")
        #expect(try JSONDecoder().decode(
            MCPAuthIntegration.self, from: JSONEncoder().encode(integration)
        ) == integration)
        #expect(integration != MCPAuthIntegration(id: "i"))
        let credential = MCPAuthCredential(
            kind: .secret, label: "l", slotKey: "k", secretId: "s", connectionId: "c"
        )
        #expect(try JSONDecoder().decode(
            MCPAuthCredential.self, from: JSONEncoder().encode(credential)
        ) == credential)
        #expect(credential != MCPAuthCredential(kind: .oauth))
        #expect(MCPAuthCredentialKind.secret.rawValue == "secret")
        #expect(MCPAuthCredentialKind.oauth.rawValue == "oauth")
        #expect(MCPAuthCredentialKind.upstream.rawValue == "upstream")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPAuthCredential.self, from: body("{\"kind\":\"weird\"}")
            )
        }
        let upstream = MCPAuthUpstream(status: 500, details: .number(1))
        #expect(try JSONDecoder().decode(
            MCPAuthUpstream.self, from: JSONEncoder().encode(upstream)
        ) == upstream)
        #expect(upstream != MCPAuthUpstream())
        let recovery = MCPToolErrorRecovery.standard(configureIntegrationTool: "c")
        #expect(try JSONDecoder().decode(
            MCPToolErrorRecovery.self, from: JSONEncoder().encode(recovery)
        ) == recovery)
        #expect(recovery != MCPToolErrorRecovery.scopeInsufficient())
        #expect(MCPToolErrorRecovery.createConnectionToolName
            == "executor.coreTools.connections.createHandoff")
        #expect(MCPToolErrorRecovery.startOAuthToolName == "executor.coreTools.oauth.start")
        #expect(MCPToolErrorRecovery.listConnectionsToolName == "executor.coreTools.connections.list")
    }

    @Test func details_recoveryStrictKeys() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolErrorRecovery.self, from: body("{\"listConnectionsTool\":\"x\",\"extra\":0}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPAuthFailureDetails.self,
                from: body("{\"category\":\"authentication\",\"recovery\":{},\"extra\":0}")
            )
        }
    }

    @Test func toolError_labelsOnly() throws {
        // Builders interpolate labels into fixed formats; nothing else fits.
        let error = MCPToolError.toolNotFound(path: "a.b.c.d", suggestions: [])
        #expect(error.message == "Tool not found: a.b.c.d")
        let text = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(text.contains("a.b.c.d"))
        #expect(MCPToolError.authentication(
            code: .oauthConnectionMissing, message: "gone"
        ).message == "gone")
    }

    // MARK: - ToolResult

    @Test func result_okShapes() throws {
        let bare: MCPToolResult = .ok(data: .object(["count": .number(3)]), http: nil)
        let bareText = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(bareText.contains("\"http\"") == false)
        #expect(try JSONDecoder().decode(MCPToolResult.self, from: bareText.utf8Data) == bare)

        let meta = MCPToolHTTPMeta(status: 200, headers: ["link": "next"])
        let withMeta: MCPToolResult = .ok(data: .string("d"), http: meta)
        let metaText = String(decoding: try JSONEncoder().encode(withMeta), as: UTF8.self)
        #expect(metaText.contains("\"http\""))
        #expect(try JSONDecoder().decode(MCPToolResult.self, from: metaText.utf8Data) == withMeta)

        let nullData = try JSONDecoder().decode(
            MCPToolResult.self, from: body("{\"ok\":true,\"data\":null}")
        )
        #expect(nullData == .ok(data: .null, http: nil))
        #expect(bare != withMeta)
    }

    @Test func result_failShape() throws {
        let fail: MCPToolResult = .fail(error: MCPToolError.toolBlocked(path: "p", pattern: "p.*"))
        let data = try JSONEncoder().encode(fail)
        #expect(try JSONDecoder().decode(MCPToolResult.self, from: data) == fail)
    }

    @Test func result_rejectsMixedArms() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self,
                from: body("{\"ok\":true,\"data\":1,\"error\":{\"code\":\"x\",\"message\":\"m\"}}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self,
                from: body("{\"ok\":false,\"data\":1,\"error\":{\"code\":\"tool_blocked\",\"message\":\"m\"}}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self,
                from: body(
                    "{\"ok\":false,\"http\":{\"status\":200,\"headers\":{}},\"error\":{\"code\":\"tool_blocked\",\"message\":\"m\"}}"
                )
            )
        }
    }

    @Test func result_rejectsMissingKeys() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolResult.self, from: body("{\"ok\":true}"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolResult.self, from: body("{\"ok\":false}"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolResult.self, from: body("{\"data\":1}"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self, from: body("{\"ok\":true,\"data\":1,\"extra\":0}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolResult.self, from: body("{\"ok\":\"yes\",\"data\":1}")
            )
        }
    }

    // MARK: - HTTP metadata

    @Test func httpMeta_roundTrip() throws {
        let meta = MCPToolHTTPMeta(status: 206, headers: ["link": "n", "x-rate": "1"])
        let data = try JSONEncoder().encode(meta)
        #expect(try JSONDecoder().decode(MCPToolHTTPMeta.self, from: data) == meta)
        let empty = MCPToolHTTPMeta(status: 200, headers: [:])
        #expect(try JSONDecoder().decode(
            MCPToolHTTPMeta.self, from: JSONEncoder().encode(empty)
        ) == empty)
        #expect(meta != empty)
    }

    @Test func httpMeta_headerCap() throws {
        var atCap: [String: String] = [:]
        for index in 0..<64 { atCap["h\(index)"] = "v" }
        let okData = try JSONEncoder().encode(MCPToolHTTPMeta(status: 200, headers: atCap))
        #expect(try JSONDecoder().decode(MCPToolHTTPMeta.self, from: okData).headers.count == 64)
        var over = atCap
        over["one-more"] = "v"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolHTTPMeta.self,
                from: JSONEncoder().encode(MCPToolHTTPMeta(status: 200, headers: over))
            )
        }
    }

    @Test func httpMeta_strictKeys() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolHTTPMeta.self,
                from: body("{\"status\":200,\"headers\":{},\"extra\":0}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolHTTPMeta.self, from: body("{\"headers\":{}}"))
        }
    }

    // MARK: - Tool files

    private var tinyPNGBase64: String { "iVBORw0KGgo=" }

    @Test func file_roundTrips() throws {
        let named = MCPToolFile(
            name: "photo.png", mimeType: "image/png", data: tinyPNGBase64, byteLength: 8
        )
        let namedData = try JSONEncoder().encode(named)
        #expect(String(decoding: namedData, as: UTF8.self).contains("\"name\""))
        #expect(try JSONDecoder().decode(MCPToolFile.self, from: namedData) == named)

        let bare = MCPToolFile(
            name: nil, mimeType: "application/octet-stream", data: tinyPNGBase64, byteLength: 8
        )
        let bareData = try JSONEncoder().encode(bare)
        #expect(String(decoding: bareData, as: UTF8.self).contains("\"name\"") == false)
        #expect(try JSONDecoder().decode(MCPToolFile.self, from: bareData) == bare)
        #expect(named != bare)
    }

    @Test func file_rejectsBadShapes() {
        let good = "{\"name\":\"p\",\"mimeType\":\"image/png\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":8}"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self, from: body("{\"_tag\":\"File\",\(good.dropFirst())")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MCPToolFile.self, from: body("{\(good.dropFirst())"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body("{\"_tag\":\"ToolFile\",\"encoding\":\"utf8\",\(good.dropFirst())")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"!!!\",\"byteLength\":1}"
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":9}"
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":-1}"
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":8}"
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":8}"
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":8,\"extra\":0}"
                )
            )
        }
    }

    @Test func file_dataCap() throws {
        let atCap = String(repeating: "A", count: 262_144)
        let ok = try JSONDecoder().decode(
            MCPToolFile.self,
            from: body(
                "{\"_tag\":\"ToolFile\",\"mimeType\":\"application/octet-stream\",\"encoding\":\"base64\",\"data\":\"\(atCap)\",\"byteLength\":196608}"
            )
        )
        #expect(ok.byteLength == 196608)
        let over = String(repeating: "A", count: 262_145)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body(
                    "{\"_tag\":\"ToolFile\",\"mimeType\":\"application/octet-stream\",\"encoding\":\"base64\",\"data\":\"\(over)\",\"byteLength\":196610}"
                )
            )
        }
    }

    // MARK: - Review: depth cap

    private func nestedParams(levels: Int) -> String {
        String(repeating: "{\"a\":", count: levels) + "1" + String(repeating: "}", count: levels)
    }

    @Test func depth_objectNestingCap() {
        // Outer object + 99 params levels = depth 100: accepted.
        let ok = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":\(nestedParams(levels: 99))}"
        guard case .success(.request(let request)) = decode(ok) else {
            Issue.record("depth-100 body should decode")
            return
        }
        #expect(request.method == "m")
        // One level deeper: rejected before the recursive decode can run.
        let over = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":\(nestedParams(levels: 100))}"
        #expect(isMalformed(over))
        #expect(MCPJSONRPCLimits.maxJSONDepth == 100)
    }

    @Test func depth_batchNestingCounts() {
        // Batch envelope + 99 levels = depth 100: accepted as a batch.
        guard case .success(.batch(let items)) = decode("[\(nestedParams(levels: 99))]") else {
            Issue.record("depth-100 batch should decode")
            return
        }
        #expect(items.count == 1)
        // Batch envelope + 100 levels = depth 101: rejected.
        #expect(isMalformed("[\(nestedParams(levels: 100))]"))
    }

    @Test func depth_bracketsInStringsDoNotCount() {
        let brackets = String(repeating: "[{[", count: 200)
        let result = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":{\"s\":\"\(brackets)\"}}"
        )
        guard case .success(.request(let request)) = result else {
            Issue.record("brackets inside strings must not count toward depth")
            return
        }
        #expect(request.params?["s"] == .string(brackets))
    }

    @Test func depth_escapedQuotesDoNotConfuseTheScan() {
        let result = decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\\\"b\\\\c\"}")
        guard case .success(.request(let request)) = result else {
            Issue.record("escaped quotes must not end the scanned string")
            return
        }
        #expect(request.method == "a\"b\\c")
        // A backslash as the last byte ends the scan inside the string.
        #expect(isMalformed("\"abc\\"))
        // Unbalanced closers floor at zero, then fail as malformed.
        #expect(isMalformed("]"))
        #expect(isMalformed("}"))
    }

    // MARK: - Review: session and challenge edges

    @Test func pipeline_emptySessionIDCountsAsMissing() {
        for (method, status) in [("GET", 400), ("DELETE", 204)] {
            let log = CallLog()
            let decision = MCPEnvelopePipeline.decide(
                method: method, sessionID: "", resourceMetadataURL: "https://h/m",
                auth: log.auth(.authenticated), dispatch: log.dispatch(.handled)
            )
            guard case .respond(let response) = decision else {
                Issue.record("expected respond for \(method) with empty session id")
                continue
            }
            #expect(response.httpStatus == status)
            #expect(log.calls == ["auth"])
        }
        let postLog = CallLog()
        #expect(MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "", resourceMetadataURL: "https://h/m",
            auth: postLog.auth(.authenticated), dispatch: postLog.dispatch(.handled)
        ) == .dispatch)
        #expect(postLog.calls == ["auth", "dispatch"])
    }

    @Test func render_emptyChallengeOmitsHeader() {
        let response = MCPJSONRPCErrorRenderer.render(
            status: 401, code: -32001, message: "Unauthorized", challenge: ""
        )
        #expect(response.headers["www-authenticate"] == nil)
        #expect(response.headers["access-control-expose-headers"] == nil)
        #expect(response.headers["access-control-allow-origin"] == "*")
        // End to end: an explicitly empty outcome challenge is omitted, with
        // no fallback to the default challenge.
        let log = CallLog()
        let decision = MCPEnvelopePipeline.decide(
            method: "POST", sessionID: "s", resourceMetadataURL: "https://h/meta",
            auth: log.auth(.unauthorized(challenge: "")), dispatch: log.dispatch(.handled)
        )
        guard case .respond(let unauthorized) = decision else {
            Issue.record("expected respond")
            return
        }
        #expect(unauthorized.httpStatus == 401)
        #expect(unauthorized.headers["www-authenticate"] == nil)
    }

    @Test func render_compositionEdges() {
        // Challenge and retry-after compose; the renderer accepts both.
        let both = MCPJSONRPCErrorRenderer.render(
            status: 401, code: -32001, message: "Unauthorized",
            challenge: "Bearer [REDACTED]", retryAfterSeconds: 2
        )
        #expect(both.headers["www-authenticate"] == "Bearer [REDACTED]")
        #expect(both.headers["retry-after"] == "2")
        #expect(both.headers["access-control-expose-headers"] == "WWW-Authenticate")
        // The GET-only dispatch arm matches exactly, mirroring === "GET".
        #expect(MCPJSONRPCErrorRenderer.sessionNotFound(method: "get").httpStatus == 404)
        #expect(MCPJSONRPCErrorRenderer.sessionNotFound(method: "GET ").httpStatus == 404)
        // Zero retry-after still emits; only an absent value omits.
        let zero = MCPJSONRPCErrorRenderer.render(
            status: 503, code: -32001, message: "m", retryAfterSeconds: 0
        )
        #expect(zero.headers["retry-after"] == "0")
    }

    @Test func codes_handshakeAlias() {
        let code: MCPJSONRPCCodes = .authSession
        #expect(code == MCPJSONRPCErrorCode.authSession)
        #expect(MCPJSONRPCCodes(rawValue: -32601) == .methodNotFound)
    }

    // MARK: - Review: byte identity (node JSON.stringify oracle)

    @Test func render_byteIdenticalBodies() {
        let sites: [(MCPEnvelopeResponse, String)] = [
            (
                MCPJSONRPCErrorRenderer.methodNotAllowed(),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Method not allowed\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.unauthorized(challenge: "Bearer [REDACTED]"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.forbidden(message: "nope"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"nope\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.unavailable(message: "blip"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"blip\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.sessionOwnership(),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32003,\"message\":\"MCP session does not belong to the current bearer\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.sessionIDRequiredForSSE(),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"mcp-session-id header required for SSE\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.sessionNotFound(method: "POST"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Session not found\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.sessionNotFound(method: "GET"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Session not found\"},\"id\":null}"
            ),
            (
                MCPJSONRPCErrorRenderer.methodNotFound(id: .number(7)),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":7}"
            ),
            (
                MCPJSONRPCErrorRenderer.methodNotFound(id: .string("abc")),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"abc\"}"
            ),
            (
                MCPJSONRPCErrorRenderer.internalError(),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error\"},\"id\":null}"
            ),
        ]
        for (response, expected) in sites {
            #expect(response.body == expected)
        }
    }

    @Test func render_escapeCorpusByteIdentical() {
        // Oracle: node JSON.stringify over the same messages.
        let cases: [(String, String)] = [
            ("\u{0}", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"\\u0000\"},\"id\":null}"),
            ("\u{B}", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"\\u000b\"},\"id\":null}"),
            ("a/b", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"a/b\"},\"id\":null}"),
            ("a\u{7F}b", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"a\u{7F}b\"},\"id\":null}"),
            ("a\u{2028}b\u{2029}c", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"a\u{2028}b\u{2029}c\"},\"id\":null}"),
            ("🚀", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"🚀\"},\"id\":null}"),
            (
                "\"\\\n\r\t\u{8}\u{C}\u{1}\u{1F}héllo🔧",
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\\u001fhéllo🔧\"},\"id\":null}"
            ),
        ]
        for (message, expected) in cases {
            let response = MCPJSONRPCErrorRenderer.render(status: 500, code: -32603, message: message)
            #expect(response.body == expected)
        }
    }

    @Test func render_hostileIDByteIdentical() {
        let cases: [(MCPJSONRPCID, String)] = [
            (.number(-3), "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":-3}"),
            (
                .number(Int64.min),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":-9223372036854775808}"
            ),
            (
                .string(""),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"\"}"
            ),
            (
                .string("a\nb"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"a\\nb\"}"
            ),
            (
                .string("x\u{1}y\"z\\w"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"x\\u0001y\\\"z\\\\w\"}"
            ),
            (
                .string("日本語🔧"),
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"日本語🔧\"}"
            ),
        ]
        for (id, expected) in cases {
            #expect(MCPJSONRPCErrorRenderer.methodNotFound(id: id).body == expected)
        }
    }

    // MARK: - Review: pipeline matrix and id edges

    @Test func pipeline_fullMatrix() {
        let authCases: [(MCPAuthOutcome, Int)] = [
            (.unauthorized(challenge: nil), 401),
            (.forbidden(code: nil, message: "m"), 403),
            (.unavailable(message: "m"), 503),
        ]
        for method in ["GET", "POST", "DELETE"] {
            for sessionID: String? in [nil, "s"] {
                // Failing auth answers before the session check and dispatch.
                for (outcome, status) in authCases {
                    let log = CallLog()
                    let decision = MCPEnvelopePipeline.decide(
                        method: method, sessionID: sessionID,
                        resourceMetadataURL: "https://h/m",
                        auth: log.auth(outcome), dispatch: log.dispatch(.notFound)
                    )
                    guard case .respond(let response) = decision else {
                        Issue.record("expected respond for \(method) \(sessionID ?? "nil")")
                        continue
                    }
                    #expect(response.httpStatus == status)
                    #expect(log.calls == ["auth"])
                }
                // Authenticated: session short-circuit, then dispatch.
                let log = CallLog()
                let decision = MCPEnvelopePipeline.decide(
                    method: method, sessionID: sessionID,
                    resourceMetadataURL: "https://h/m",
                    auth: log.auth(.authenticated), dispatch: log.dispatch(.handled)
                )
                if sessionID == nil, method == "GET" {
                    guard case .respond(let response) = decision else {
                        Issue.record("expected respond")
                        continue
                    }
                    #expect(response.httpStatus == 400)
                    #expect(log.calls == ["auth"])
                } else if sessionID == nil, method == "DELETE" {
                    #expect(decision == .respond(MCPJSONRPCErrorRenderer.sessionlessDelete()))
                    #expect(log.calls == ["auth"])
                } else {
                    #expect(decision == .dispatch)
                    #expect(log.calls == ["auth", "dispatch"])
                }
            }
        }
        // Rejected methods never reach auth, whatever it would return.
        for method in ["PUT", "HEAD", "post", ""] {
            for outcome in [MCPAuthOutcome.authenticated, .unauthorized(challenge: nil)] {
                let log = CallLog()
                let decision = MCPEnvelopePipeline.decide(
                    method: method, sessionID: "s", resourceMetadataURL: "https://h/m",
                    auth: log.auth(outcome), dispatch: log.dispatch(.handled)
                )
                guard case .respond(let response) = decision else {
                    Issue.record("expected respond for \(method)")
                    continue
                }
                #expect(response.httpStatus == 405)
                #expect(log.calls == [])
            }
        }
        // OPTIONS preflights before auth on any outcome.
        for outcome in [MCPAuthOutcome.authenticated, .unavailable(message: "m")] {
            let log = CallLog()
            let decision = MCPEnvelopePipeline.decide(
                method: "OPTIONS", sessionID: "s", resourceMetadataURL: "https://h/m",
                auth: log.auth(outcome), dispatch: log.dispatch(.handled)
            )
            #expect(decision == .respond(MCPJSONRPCErrorRenderer.corsPreflight()))
            #expect(log.calls == [])
        }
    }

    @Test func decode_idEdges() {
        // Exponent-form integral doubles read as their integer.
        guard case .success(.request(let exp)) = decode("{\"jsonrpc\":\"2.0\",\"id\":1e3,\"method\":\"m\"}") else {
            Issue.record("1e3 id should decode")
            return
        }
        #expect(exp.id == .number(1000))
        // Empty-string ids are valid; the SDK accepts any string.
        guard case .success(.request(let empty)) = decode("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"method\":\"m\"}") else {
            Issue.record("empty-string id should decode")
            return
        }
        #expect(empty.id == .string(""))
        // A failure response without an id is malformed, like the success arm.
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":1,\"message\":\"m\"}}"))
        // Null results are legal on a non-null id.
        guard case .success(.response(let nullResult)) = decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}") else {
            Issue.record("null result should decode")
            return
        }
        #expect(nullResult == .success(id: .number(1), result: .null))
        // Request/response hybrids are neither.
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"result\":1}"))
        #expect(isMalformed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"error\":{\"code\":1,\"message\":\"m\"}}"))
        // Whitespace alone is not a body.
        #expect(isMalformed("   \n\t "))
    }

    // MARK: - Review: guard fixtures and negotiation

    @Test func guard_executorFixtures() {
        // Missing version, empty batch, id+method without version: not requests.
        for json in [
            "{\"id\":1,\"method\":\"tools/list\"}",
            "[]",
            "{\"id\":1,\"method\":\"server/discover\",\"params\":{}}",
        ] {
            #expect(MCPPreInitializeGuard.evaluate(
                method: "POST", accept: guardAccept, contentType: guardContentType, body: body(json)
            ) == nil)
        }
        // Reversed Accept order still negotiates: the tests are substrings.
        let reversed = MCPPreInitializeGuard.evaluate(
            method: "POST", accept: "text/event-stream, application/json",
            contentType: guardContentType,
            body: body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        )
        #expect(reversed?.httpStatus == 200)
    }

    @Test func guard_negotiationExtras() {
        let probe = body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}")
        // Whitespace and parameters ride along on the raw-value substrings.
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: "  application/json ,  text/event-stream  ",
            contentType: "application/json ; charset=utf-8"
        ) == true)
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: "  application/json ,  text/event-stream  ",
            contentType: "application/json ; charset=utf-8", body: probe
        )?.httpStatus == 200)
        // Substring impostors pass exactly as the SDK's includes() would, so
        // the guard still agrees with the transport either way.
        #expect(MCPPreInitializeGuard.passesContentNegotiation(
            accept: "application/json-patch, text/event-stream-x",
            contentType: "application/json-seq"
        ) == true)
        // Empty strings negotiate nothing.
        #expect(MCPPreInitializeGuard.passesContentNegotiation(accept: "", contentType: "") == false)
    }

    // MARK: - Review: strict-null and file edges

    @Test func toolError_explicitNullsFailClosed() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self,
                from: body("{\"code\":\"tool_blocked\",\"message\":\"m\",\"details\":null}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolError.self,
                from: body("{\"code\":\"tool_blocked\",\"message\":\"m\",\"retryable\":null}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolErrorDetails.self, from: body("{\"path\":\"p\",\"suggestions\":null}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body("{\"_tag\":\"ToolFile\",\"name\":null,\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\",\"byteLength\":8}")
            )
        }
    }

    @Test func factory_invalidArgumentsEmptyIssuesRoundTrip() throws {
        let error = MCPToolError.invalidArguments(issues: [])
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MCPToolError.self, from: data) == error)
        // Absent issues read as empty when the shape is decoded directly.
        let direct = try JSONDecoder().decode(MCPInvalidArgumentsDetails.self, from: body("{}"))
        #expect(direct == MCPInvalidArgumentsDetails(issues: []))
        // A bare {} still discriminates to empty binding details, while an
        // explicit empty issues list stays invalid-arguments.
        #expect(try JSONDecoder().decode(MCPToolErrorDetails.self, from: body("{}"))
            == .binding(MCPBindingDetails()))
        #expect(try JSONDecoder().decode(MCPToolErrorDetails.self, from: body("{\"issues\":[]}"))
            == .invalidArguments(MCPInvalidArgumentsDetails(issues: [])))
    }

    @Test func file_edges() throws {
        // Empty files are legal: empty base64 decodes to zero bytes.
        let empty = try JSONDecoder().decode(
            MCPToolFile.self,
            from: body("{\"_tag\":\"ToolFile\",\"mimeType\":\"application/octet-stream\",\"encoding\":\"base64\",\"data\":\"\",\"byteLength\":0}")
        )
        #expect(empty.byteLength == 0)
        // Base64 carrying whitespace is rejected (strict where Buffer.from
        // would skip it).
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body("{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64) \",\"byteLength\":8}")
            )
        }
        // Missing payload keys fail.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body("{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"byteLength\":8}")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MCPToolFile.self,
                from: body("{\"_tag\":\"ToolFile\",\"mimeType\":\"image/png\",\"encoding\":\"base64\",\"data\":\"\(tinyPNGBase64)\"}")
            )
        }
    }

    // MARK: - Final pass: depth bound on every entry point

    private func nestedArrays(levels: Int) -> String {
        String(repeating: "[", count: levels) + "1" + String(repeating: "]", count: levels)
    }

    private func nestedMixed(pairs: Int) -> String {
        String(repeating: "[{\"a\":", count: pairs) + "1"
            + String(repeating: "}]", count: pairs)
    }

    @Test func depth_notificationNestingCap() {
        // Outer object + 99 params levels = depth 100: accepted.
        let ok = "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":\(nestedParams(levels: 99))}"
        guard case .success(.notification(let notification)) = decode(ok) else {
            Issue.record("depth-100 notification should decode")
            return
        }
        #expect(notification.method == "m")
        // One level deeper: rejected before the recursive decode can run.
        let over = "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":\(nestedParams(levels: 100))}"
        #expect(isMalformed(over))
    }

    @Test func depth_responseResultNestingCap() {
        // Bracket nesting counts the same as braces: outer + 99 = 100.
        let ok = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedArrays(levels: 99))}"
        guard case .success(.response(.success(let id, _))) = decode(ok) else {
            Issue.record("depth-100 response should decode")
            return
        }
        #expect(id == .number(1))
        let over = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedArrays(levels: 100))}"
        #expect(isMalformed(over))
        // Object nesting in results is bounded identically.
        let objOver =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedParams(levels: 100))}"
        #expect(isMalformed(objOver))
        // Crash-depth results stay rejected: 400 levels, ~2.4KB.
        let crash = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedParams(levels: 400))}"
        #expect(isMalformed(crash))
    }

    @Test func depth_mixedNestingCap() {
        // Each pair adds two levels: outer + 2*49 = 99 decodes.
        let ok = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedMixed(pairs: 49))}"
        guard case .success(.response) = decode(ok) else {
            Issue.record("depth-99 mixed response should decode")
            return
        }
        // Outer + 2*50 = 101: rejected.
        let over = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(nestedMixed(pairs: 50))}"
        #expect(isMalformed(over))
    }

    @Test func depth_siblingSubtreesDoNotAccumulate() {
        // The scan tracks current depth, not total opens: two depth-99
        // siblings never exceed 100 together.
        let item = nestedParams(levels: 98)
        guard case .success(.batch(let items)) = decode("[\(item),\(item)]") else {
            Issue.record("sibling subtrees should decode")
            return
        }
        #expect(items.count == 2)
        // But a deep second item is still caught: the scan covers the whole
        // body, not just the first item.
        #expect(isMalformed("[{},\(nestedParams(levels: 100))]"))
        #expect(isMalformed("[\(nestedParams(levels: 99)),\(nestedParams(levels: 100))]"))
    }

    @Test func depth_requestCrashDepthRejected() {
        // The F1 crash class: ~2.4KB at depth 400 dies with SIGBUS on a
        // 512KB stack without the scan; the codec refuses it up front.
        let deep = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":\(nestedParams(levels: 400))}"
        #expect(body(deep).count < 3_072)
        #expect(isMalformed(deep))
        #expect(isMalformed(
            "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":\(nestedParams(levels: 400))}"
        ))
        #expect(isMalformed("[\(nestedParams(levels: 400))]"))
    }

    @Test func depth_bracketsInResponseStringsDoNotCount() {
        let brackets = String(repeating: "]}", count: 200)
        let result = decode(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"\(brackets)\"}}"
        )
        guard case .success(.response(let response)) = result else {
            Issue.record("brackets inside response strings must not count")
            return
        }
        #expect(response == .failure(
            id: .number(1), error: MCPJSONRPCResponseError(code: 1, message: brackets)
        ))
    }

    @Test func guard_deepBodyFallsThrough() {
        // An over-deep probe is not a request the guard answers: it falls
        // through (nil) instead of firing or crashing.
        #expect(MCPPreInitializeGuard.evaluate(
            method: "POST", accept: guardAccept, contentType: guardContentType,
            body: body(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":\(nestedParams(levels: 400))}"
            )
        ) == nil)
    }

    // MARK: - Final pass: wide bodies within the byte cap

    @Test func wide_arrayBombWithinCapDecodes() {
        // 50,000 flat elements (~100KB): shallow, bounded, decodes in full.
        let elements = Array(repeating: "1", count: 50_000).joined(separator: ",")
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\(elements)]}"
        #expect(body(json).count < MCPJSONRPCLimits.maxBodyBytes)
        guard case .success(.response(let response)) = decode(json) else {
            Issue.record("wide array should decode")
            return
        }
        guard case .success(_, let result) = response, case .array(let items) = result else {
            Issue.record("expected array result")
            return
        }
        #expect(items.count == 50_000)
    }

    @Test func wide_objectBombWithinCapDecodes() {
        // 10,000 flat keys (~90KB): shallow, bounded, decodes in full.
        var parts: [String] = []
        parts.reserveCapacity(10_000)
        for index in 0..<10_000 { parts.append("\"k\(index)\":1") }
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":{\(parts.joined(separator: ","))}}"
        #expect(body(json).count < MCPJSONRPCLimits.maxBodyBytes)
        guard case .success(.request(let request)) = decode(json) else {
            Issue.record("wide object should decode")
            return
        }
        #expect(request.params?.count == 10_000)
    }

    @Test func wide_fullBatchOfShallowItemsDecodes() {
        // 128 shallow items: the count cap, not the byte cap, is the bound.
        let items = Array(
            repeating: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"}", count: 128
        ).joined(separator: ",")
        guard case .success(.batch(let batch)) = decode("[\(items)]") else {
            Issue.record("128-item batch should decode")
            return
        }
        #expect(batch.count == 128)
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
