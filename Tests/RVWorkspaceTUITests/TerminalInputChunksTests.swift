import Foundation
import RVIsolation
import Testing
@testable import RVWorkspaceTUI

@Test func terminalInputChunksPreserveLongByteStreams() {
    let payload = Data((0..<10_001).map { UInt8($0 % 251) })
    let chunks = TerminalInputChunks.make(payload)
    #expect(chunks != nil)
    #expect(chunks?.count == 3)
    #expect(chunks?.allSatisfy { $0.count <= TerminalStreamLimits.maximumInputBytes } == true)
    let rebuilt = (chunks ?? []).reduce(into: Data()) { $0.append($1) }
    #expect(rebuilt == payload)
}

@Test func terminalInputChunksRejectEmptyAndOversizedPayloads() {
    #expect(TerminalInputChunks.make(Data()) == nil)
    #expect(TerminalInputChunks.make(Data(repeating: 1, count: TerminalInputChunks.maximumTotalBytes + 1)) == nil)
}
