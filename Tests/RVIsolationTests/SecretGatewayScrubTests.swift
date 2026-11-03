import Foundation
import Testing
@testable import RVIsolation

/// Upstream echoes of a brokered value in the encodings an API is likely to
/// apply on the way back: percent, JSON string escapes, and base64.
@Suite("SecretGatewayScrub")
struct SecretGatewayScrubTests {
    private let placeholder = Array("sk-rvph_0123456789abcdef0123456789abcdef".utf8)

    private func scrub(_ value: String, _ body: String) -> String {
        SecretScrubber.scrub(body, [(Array(value.utf8), placeholder)])
    }

    private func base64(_ text: String, url: Bool = false) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        guard url else { return encoded }
        return encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Every run of `minimum` characters from `encoded` that `body` still holds.
    private func survivingRuns(of encoded: String, in body: String, minimum: Int = 8) -> [String] {
        let characters = Array(encoded)
        guard characters.count >= minimum else { return [] }
        return (0...(characters.count - minimum)).map { String(characters[$0..<($0 + minimum)]) }
            .filter { body.contains($0) }
    }

    @Test func percentEncodedEchoesBecomeThePlaceholder() {
        let value = "sk-live/REAL+0123=xyz ok"
        let text = String(decoding: placeholder, as: UTF8.self)
        #expect(scrub(value, "q=sk-live%2FREAL%2B0123%3Dxyz%20ok&x=1") == "q=\(text)&x=1")
        #expect(scrub(value, "q=sk-live%2fREAL%2b0123%3dxyz+ok") == "q=\(text)")
        // A mix of raw and encoded bytes, as some encoders leave `/` alone.
        #expect(scrub(value, "sk-live/REAL%2B0123=xyz%20ok") == text)
    }

    @Test func jsonEscapedEchoesBecomeThePlaceholder() {
        let text = String(decoding: placeholder, as: UTF8.self)
        #expect(scrub("sk-live/REAL-0123456789", #"{"k":"sk-live\/REAL-0123456789"}"#) == #"{"k":"\#(text)"}"#)
        #expect(scrub(#"a"b\c-0123456789"#, #"{"k":"a\"b\\c-0123456789"}"#) == #"{"k":"\#(text)"}"#)
        #expect(scrub("sk-<live>&0123456789", #"{"k":"sk-<live>&0123456789"}"#) == #"{"k":"\#(text)"}"#)
        #expect(scrub("pässwörd-0123456789", #"{"k":"pässwörd-0123456789"}"#) == #"{"k":"\#(text)"}"#)
        #expect(scrub("key-😀-0123456789", #"{"k":"key-😀-0123456789"}"#) == #"{"k":"\#(text)"}"#)
        #expect(scrub("line\nbreak-0123456789", #"{"k":"line\nbreak-0123456789"}"#) == #"{"k":"\#(text)"}"#)
    }

    @Test func base64EchoesAtEveryAlignmentAreRedacted() {
        let value = "sk-live-REAL-0123456789?>~"
        for prefix in ["", "u:", "user:", "x"] {
            for url in [false, true] {
                let encoded = base64(prefix + value, url: url)
                let body = "{\"auth\":\"Basic \(encoded)\"}"
                let output = scrub(value, body)
                #expect(output.contains("[rv:redacted]"), "prefix \(prefix) url \(url)")
                // Only the few characters that also carry prefix or padding bits remain.
                #expect(survivingRuns(of: encoded, in: output).isEmpty, "prefix \(prefix) url \(url): \(output)")
            }
        }
    }

    @Test func wholeValueBase64IsRedactedIncludingItsTail() {
        let value = "sk-live-REAL-0123456789"
        let output = scrub(value, "token=\(base64(value))&next=1")
        #expect(output == "token=[rv:redacted]&next=1")
    }

    @Test func encodedEchoesSplitAtEveryBoundaryAreCaught() {
        let value = "sk-live/REAL+0123\"456789"
        let text = Array(String(decoding: placeholder, as: UTF8.self).utf8)
        let forms = [
            "sk-live%2FREAL%2B0123%22456789",
            #"sk-live\/REAL+0123\"456789"#,
            "sk-live/REAL+0123\"456789",
        ]
        for form in forms {
            let body = Array("a=\(form);b=\(form).".utf8)
            let expected = Array("a=".utf8) + text + Array(";b=".utf8) + text + Array(".".utf8)
            for split in 0...body.count {
                var scrubber = SecretScrubber([(Array(value.utf8), placeholder)])
                let output = scrubber.process(Array(body[..<split])) + scrubber.process(Array(body[split...]))
                    + scrubber.finish()
                #expect(output == expected, "\(form) split at \(split)")
            }
        }
        let encoded = Array("x=\(base64(value))".utf8)
        for split in 0...encoded.count {
            var scrubber = SecretScrubber([(Array(value.utf8), placeholder)])
            let output = scrubber.process(Array(encoded[..<split])) + scrubber.process(Array(encoded[split...]))
                + scrubber.finish()
            #expect(output == Array("x=[rv:redacted]".utf8), "base64 split at \(split)")
        }
    }

    @Test func holdsBackOnlyATrailingPartialMatch() {
        var scrubber = SecretScrubber([(Array("sk-live-REAL-0123456789".utf8), placeholder)])
        // Nothing here can start the value or one of its encodings.
        #expect(scrubber.process(Array("data: {\"delta\":\"hi\"}\n\n".utf8)) == Array("data: {\"delta\":\"hi\"}\n\n".utf8))
        #expect(scrubber.process(Array("then sk-li".utf8)) == Array("then ".utf8))
        #expect(scrubber.process(Array("ght".utf8)) == Array("sk-light".utf8))
        #expect(scrubber.finish().isEmpty)
    }

    @Test func innocentEscapesPassThroughUnchanged() {
        let body = #"{"path":"a\/b","pct":"100%","b64":"aGVsbG8=","u":"é"}"#
        #expect(scrub("sk-live-REAL-0123456789", body) == body)
    }
}
