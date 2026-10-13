import Foundation
import Testing
import RVDomain

@Suite("RVDigest HMAC")
struct RVDigestHMACTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    @Test func matchesRFC4231() {
        #expect(hex(RVDigest.hmacSHA256(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8)))
            == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        #expect(hex(RVDigest.hmacSHA256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        #expect(hex(RVDigest.hmacSHA256(
            key: [UInt8](repeating: 0xaa, count: 131),
            message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)))
            == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }
}
