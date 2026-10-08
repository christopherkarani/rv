import Testing
import RVDomain

// Pure byte-vector tests for the domain hasher. File-I/O coverage
// lives with the shell-side reader in
// Tests/RVIsolationTests/ExecutableDigestTests.swift.

struct RVDigestFileTests {
    @Test func emptyDigestKnownAnswer() {
        #expect(
            RVDigest.sha256Hex([])
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test func abcDigestKnownAnswer() {
        #expect(
            RVDigest.sha256Hex(Array("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func distinctInputsDistinctDigests() {
        let one = RVDigest.sha256Hex(Array("hello executable".utf8))
        #expect(one.count == 64)
        #expect(one == one.lowercased())
        #expect(one == RVDigest.sha256Hex(Array("hello executable".utf8)))
        #expect(one != RVDigest.sha256Hex(Array("hello executablf".utf8)))
    }
}
