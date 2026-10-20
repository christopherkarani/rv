import Foundation

/// SentencePiece-style BPE over `tokenizer.json` (Metaspace pre-tokenizer,
/// byte fallback), byte-matched to HF `tokenizers` for the Laya bundles.
/// Golden ID sequences are asserted in RVLayaTests.
///
/// All table lookups key on UTF-8 bytes, never on `String`: Swift's `==`
/// folds some distinct Unicode scalars (measured on this toolchain:
/// U+003B `;` == U+037E Greek question mark), which silently collapses
/// distinct vocab entries (256000 JSON keys became 255933 `String` keys)
/// and resolves inputs nondeterministically per process. Byte keys are
/// exact, so the Swift encoding matches the Rust tokenizer byte for byte.
public struct LayaTokenizer: Sendable {
    var byteVocab: [[UInt8]: Int32]
    var mergeRanks: [PairKey: Int]
    var addedTokens: [(bytes: [UInt8], id: Int32)]

    public var padID: Int32 { byteVocab[Array("<pad>".utf8)] ?? 0 }
    public var clsID: Int32 { byteVocab[Array("<bos>".utf8)] ?? 2 }
    public var sepID: Int32 { byteVocab[Array("<eos>".utf8)] ?? 1 }
    public var maskID: Int32 { byteVocab[Array("<mask>".utf8)] ?? 4 }
    public var unkID: Int32 { byteVocab[Array("<unk>".utf8)] ?? 3 }
    public var maskToken: String { "<mask>" }

    struct PairKey: Hashable {
        var a: [UInt8]
        var b: [UInt8]
    }

    public init(bundleDir: URL) throws {
        let file = bundleDir.appendingPathComponent("tokenizer/tokenizer.json")
        try self.init(tokenizerJSON: file)
    }

    public init(tokenizerJSON file: URL) throws {
        var data = try Data(contentsOf: file)
        // U+FEFF inside keys collapses one layer earlier: NSString compares
        // BOM-insensitively, so parsing already drops entries and reassigns
        // common ids ("#" kept "\u{FEFF}#"s id). Swap FEFF for a private-use
        // stand-in at the byte level pre-parse, then map back per key below.
        // The stand-in must be absent; refuse to guess.
        let feff: [UInt8] = [0xEF, 0xBB, 0xBF]
        let standIn: [UInt8] = [0xF3, 0xB0, 0x80, 0x80] // U+F0000
        var raw = Array(data)
        if Self.containsSequence(raw, standIn) {
            throw LayaError.badBundle("tokenizer.json already contains U+F0000")
        }
        raw = Self.replacingSequence(raw, feff, standIn)
        data = Data(raw)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let merges = model["merges"] as? [[String]]
        else {
            throw LayaError.badBundle("tokenizer.json missing model.vocab/merges")
        }
        // Never materialize a [String: NSNumber] vocab: the bridge collapses
        // keys Swift considers equal (see header note). Iterate the raw
        // NSDictionary pairs and key on bytes instead.
        guard let rawVocab = model["vocab"] as? NSDictionary else {
            throw LayaError.badBundle("tokenizer.json missing model.vocab/merges")
        }
        var vocab: [[UInt8]: Int32] = [:]
        vocab.reserveCapacity(rawVocab.count + 8)
        for (key, value) in rawVocab {
            guard let text = key as? String,
                  let id = (value as? NSNumber)?.int32Value
            else {
                throw LayaError.badBundle("tokenizer.json has non-string vocab entry")
            }
            vocab[Self.unstand(Array(text.utf8))] = id
        }
        byteVocab = vocab
        var ranks: [PairKey: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, pair) in merges.enumerated() where pair.count == 2 {
            ranks[PairKey(a: Self.unstand(Array(pair[0].utf8)), b: Self.unstand(Array(pair[1].utf8)))] = rank
        }
        mergeRanks = ranks
        let added = root["added_tokens"] as? [[String: Any]] ?? []
        addedTokens = added.compactMap { entry in
            guard let text = entry["content"] as? String,
                  let id = (entry["id"] as? NSNumber)?.int32Value else { return nil }
            return (Self.unstand(Array(text.utf8)), id)
        }.sorted { $0.bytes.count > $1.bytes.count }
    }

    /// Exact byte-subsequence search.
    static func containsSequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            haystack[$0..<($0 + needle.count)].elementsEqual(needle)

        }
    }

    /// Exact byte-subsequence replace (lengths may differ).
    static func replacingSequence(_ haystack: [UInt8], _ needle: [UInt8], _ replacement: [UInt8]) -> [UInt8] {
        guard !needle.isEmpty else { return haystack }
        var out: [UInt8] = []
        out.reserveCapacity(haystack.count)
        var i = 0
        while i <= haystack.count - needle.count {
            if haystack[i ..< (i + needle.count)].elementsEqual(needle) {
                out.append(contentsOf: replacement)
                i += needle.count
            } else {
                out.append(haystack[i])
                i += 1
            }
        }
        out.append(contentsOf: haystack[i...])
        return out
    }

    /// Map the U+F0000 stand-in bytes back to U+FEFF bytes (exact).
    static func unstand(_ bytes: [UInt8]) -> [UInt8] {
        Self.replacingSequence(bytes, [0xF3, 0xB0, 0x80, 0x80], [0xEF, 0xBB, 0xBF])
    }

    /// Encode without special tokens, matching HF with `add_special_tokens=False`.
    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for chunk in splitAddedTokens(text) {
            switch chunk {
            case .added(let id):
                ids.append(id)
            case .plain(let plain):
                for piece in metaspacePieces(plain) {
                    ids.append(contentsOf: encodePiece(piece))
                }
            }
        }
        return ids
    }

    enum Chunk {
        case added(Int32)
        case plain(String)
    }

    /// Exact byte-level added-token split: earliest match wins, longest
    /// pattern breaks ties. Byte matching is boundary-safe (a lead byte
    /// never equals a continuation byte), so matches always land on
    /// character boundaries.
    func splitAddedTokens(_ text: String) -> [Chunk] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var cursor = 0
        var plainStart = 0
        func flushPlain(upTo end: Int) {
            guard plainStart < end else { return }
            chunks.append(.plain(String(bytes: bytes[plainStart..<end], encoding: .utf8)!))
        }
        while cursor < bytes.count {
            var best: (index: Int, length: Int, id: Int32)?
            for token in addedTokens {
                if token.bytes.count > bytes.count - cursor { continue }
                if bytes[cursor..<(cursor + token.bytes.count)].elementsEqual(token.bytes) {
                    if best == nil || token.bytes.count > best!.length {
                        best = (cursor, token.bytes.count, token.id)
                    }
                }
            }
            // Earliest match wins: only a match AT the cursor splits here;
            // anything later is found as the cursor advances.
            if let match = best, match.index == cursor {
                flushPlain(upTo: cursor)
                chunks.append(.added(match.id))
                cursor += match.length
                plainStart = cursor
            } else {
                // Advance one scalar (not one byte) so the cursor stays on
                // character boundaries for the plain-text slices. The cursor
                // is always boundary-aligned (matches are boundary-safe),
                // so every plain slice below is valid UTF-8.
                let lead = bytes[cursor]
                cursor += lead < 0x80 ? 1 : utf8ScalarLength(lead)
            }
        }
        flushPlain(upTo: bytes.count)
        return chunks
    }

    /// UTF-8 scalar length from its lead byte.
    func utf8ScalarLength(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead < 0xE0 { return 2 }
        if lead < 0xF0 { return 3 }
        return 4
    }

    /// Normalizer (space -> U+2581) + Metaspace prepend + split.
    func metaspacePieces(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: " ", with: "▁")
        let replaced = normalized.hasPrefix("▁") ? normalized : "▁" + normalized
        var pieces: [String] = []
        var current = ""
        for scalar in replaced.unicodeScalars {
            if scalar == "▁", !current.isEmpty {
                pieces.append(current)
                current = "▁"
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let loneBar: [UInt8] = Array("▁".utf8)
        return pieces.filter { $0 != "▁" || byteVocab[loneBar] != nil }
    }

    func encodePiece(_ piece: String) -> [Int32] {
        var symbols: [[UInt8]] = []
        for scalar in piece.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if byteVocab[bytes] != nil {
                symbols.append(bytes)
            } else {
                // Byte fallback: each UTF-8 byte becomes a <0xXX> token.
                symbols.append(contentsOf: bytes.map { Array(String(format: "<0x%02X>", $0).utf8) })
            }
        }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex: Int?
            for i in 0..<(symbols.count - 1) {
                if let rank = mergeRanks[PairKey(a: symbols[i], b: symbols[i + 1])],
                   rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard let index = bestIndex else { break }
            symbols[index] += symbols[index + 1]
            symbols.remove(at: index + 1)
        }
        return symbols.flatMap { symbol -> [Int32] in
            if let id = byteVocab[symbol] { return [id] }
            let bytes = symbol.flatMap { byte -> [Int32] in
                byteVocab[Array(String(format: "<0x%02X>", byte).utf8)].map { [$0] } ?? [unkID]
            }
            return bytes.isEmpty ? [unkID] : bytes
        }
    }
}

public enum LayaError: Error, Sendable, Equatable {
    case badBundle(String)
    case modelUnavailable(String)
    case predictionFailed(String)
}
