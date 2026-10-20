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
    var addedTokens: [(bytes: [UInt8], id: Int32, lstrip: Bool, rstrip: Bool)]
    /// Added tokens by first byte: the per-cursor scan must stay
    /// near-linear on long untrusted input.
    var addedByFirstByte: [UInt8: [(bytes: [UInt8], id: Int32, lstrip: Bool, rstrip: Bool)]] = [:]

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
        var data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw LayaError.badBundle("tokenizer.json unreadable at \(file.path)")
        }
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
        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LayaError.badBundle("tokenizer.json missing model.vocab/merges")
            }
            root = parsed
        } catch let error as LayaError {
            throw error
        } catch {
            throw LayaError.badBundle("tokenizer.json is not valid JSON")
        }
        guard
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
        for (rank, pair) in merges.enumerated() {
            guard pair.count == 2 else {
                throw LayaError.badBundle("tokenizer.json merge \(rank) is not a pair")
            }
            ranks[PairKey(a: Self.unstand(Array(pair[0].utf8)), b: Self.unstand(Array(pair[1].utf8)))] = rank
        }
        mergeRanks = ranks
        let added = root["added_tokens"] as? [[String: Any]] ?? []
        addedTokens = try added.map { entry in
            guard let text = entry["content"] as? String, !text.isEmpty,
                  let id = (entry["id"] as? NSNumber)?.int32Value else {
                // An empty or malformed added token can never match
                // safely (empty would loop the splitter forever).
                throw LayaError.badBundle("tokenizer.json has malformed added_tokens entry")
            }
            return (
                Self.unstand(Array(text.utf8)), id,
                (entry["lstrip"] as? NSNumber)?.boolValue ?? false,
                (entry["rstrip"] as? NSNumber)?.boolValue ?? false
            )
        }.sorted { $0.bytes.count > $1.bytes.count }
        for token in addedTokens {
            if let first = token.bytes.first {
                addedByFirstByte[first, default: []].append(token)
            }
        }
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
        encodeBounded(text, maxTokens: .max).ids
    }

    /// Bounded encode for untrusted input. Stops once the token budget
    /// is exceeded and symbol-caps each spaceless piece relative to the
    /// budget, so a 64 KB base64 blob cannot turn the O(n²) merge loop
    /// into a minute-long hang. `truncated` is honest: it is set when
    /// tokens were dropped for the budget OR when a piece hit the
    /// symbol cap (merges can hide a capped piece under the budget, so
    /// token count alone cannot detect it).
    public func encodeBounded(
        _ text: String, maxTokens: Int
    ) -> (ids: [Int32], truncated: Bool) {
        var ids: [Int32] = []
        var truncated = false
        let cap = maxTokens == .max ? Int.max : max(256, maxTokens * 2)
        for chunk in splitAddedTokens(text) {
            switch chunk {
            case .added(let id):
                ids.append(id)
            case .plain(let plain):
                for piece in metaspacePieces(plain) {
                    let encoded = encodePieceCapped(piece, symbolCap: cap)
                    if encoded.capped { truncated = true }
                    ids.append(contentsOf: encoded.ids)
                    if ids.count > maxTokens {
                        return (Array(ids.prefix(maxTokens)), true)
                    }
                }
            }
            if ids.count > maxTokens {
                return (Array(ids.prefix(maxTokens)), true)
            }
        }
        return (ids, truncated)
    }

    enum Chunk {
        case added(Int32)
        case plain(String)
    }

    /// Exact byte-level added-token split: earliest match wins, longest
    /// pattern breaks ties. Byte matching is boundary-safe (a lead byte
    /// never equals a continuation byte), so matches always land on
    /// character boundaries. HF `lstrip`/`rstrip` flags are honored:
    /// lstrip consumes whitespace immediately before the token, rstrip
    /// whitespace immediately after (`<mask>` ships lstrip in the Laya
    /// bundles, so dropping the flags mistokenizes real input).
    func splitAddedTokens(_ text: String) -> [Chunk] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var plain: [UInt8] = []
        var cursor = 0
        func flushPlain() {
            guard !plain.isEmpty else { return }
            chunks.append(.plain(String(decoding: plain, as: UTF8.self)))
            plain = []
        }
        func isWhitespaceByte(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        while cursor < bytes.count {
            var best: (length: Int, id: Int32, lstrip: Bool, rstrip: Bool)?
            for token in addedByFirstByte[bytes[cursor]] ?? [] {
                if token.bytes.isEmpty || token.bytes.count > bytes.count - cursor { continue }
                if bytes[cursor..<(cursor + token.bytes.count)].elementsEqual(token.bytes) {
                    if best == nil || token.bytes.count > (best?.length ?? 0) {
                        best = (token.bytes.count, token.id, token.lstrip, token.rstrip)
                    }
                }
            }
            // Earliest match wins: only a match AT the cursor splits here;
            // anything later is found as the cursor advances.
            if let match = best {
                if match.lstrip {
                    while let last = plain.last, isWhitespaceByte(last) { plain.removeLast() }
                }
                flushPlain()
                chunks.append(.added(match.id))
                cursor += match.length
                if match.rstrip {
                    while cursor < bytes.count, isWhitespaceByte(bytes[cursor]) { cursor += 1 }
                }
            } else {
                // Advance one scalar (not one byte) so plain slices stay
                // on character boundaries. The cursor is always
                // boundary-aligned (matches are boundary-safe), so every
                // plain chunk is valid UTF-8.
                let lead = bytes[cursor]
                let step = lead < 0x80 ? 1 : utf8ScalarLength(lead)
                let end = min(cursor + step, bytes.count)
                plain.append(contentsOf: bytes[cursor..<end])
                cursor = end
            }
        }
        flushPlain()
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
        encodePieceCapped(piece, symbolCap: .max).ids
    }

    func encodePieceCapped(
        _ piece: String, symbolCap: Int
    ) -> (ids: [Int32], capped: Bool) {
        var symbols: [[UInt8]] = []
        var capped = false
        for scalar in piece.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if byteVocab[bytes] != nil {
                symbols.append(bytes)
            } else {
                // Byte fallback: each UTF-8 byte becomes a <0xXX> token.
                symbols.append(contentsOf: bytes.map { Array(String(format: "<0x%02X>", $0).utf8) })
            }
            // The merge loop below is O(n²) in symbol count; a caller
            // with a token budget caps the piece before merging.
            if symbols.count >= symbolCap {
                symbols = Array(symbols.prefix(symbolCap))
                capped = true
                break
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
        let ids = symbols.flatMap { symbol -> [Int32] in
            if let id = byteVocab[symbol] { return [id] }
            let bytes = symbol.flatMap { byte -> [Int32] in
                byteVocab[Array(String(format: "<0x%02X>", byte).utf8)].map { [$0] } ?? [unkID]
            }
            return bytes.isEmpty ? [unkID] : bytes
        }
        return (ids, capped)
    }
}

public enum LayaError: Error, Sendable, Equatable {
    case badBundle(String)
    case modelUnavailable(String)
    case predictionFailed(String)
}
