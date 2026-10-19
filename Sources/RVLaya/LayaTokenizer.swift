import Foundation

/// SentencePiece-style BPE over `tokenizer.json` (Metaspace pre-tokenizer,
/// byte fallback), byte-matched to HF `tokenizers` for the Laya bundles.
/// Golden ID sequences are asserted in RVLayaTests.
public struct LayaTokenizer: Sendable {
    public var vocab: [String: Int32]
    var mergeRanks: [PairKey: Int]
    var addedTokens: [(text: String, id: Int32)]

    public var padID: Int32 { vocab["<pad>"] ?? 0 }
    public var clsID: Int32 { vocab["<bos>"] ?? 2 }
    public var sepID: Int32 { vocab["<eos>"] ?? 1 }
    public var maskID: Int32 { vocab["<mask>"] ?? 4 }
    public var unkID: Int32 { vocab["<unk>"] ?? 3 }
    public var maskToken: String { "<mask>" }

    struct PairKey: Hashable {
        var a: String
        var b: String
    }

    public init(bundleDir: URL) throws {
        let file = bundleDir.appendingPathComponent("tokenizer/tokenizer.json")
        try self.init(tokenizerJSON: file)
    }

    public init(tokenizerJSON file: URL) throws {
        let data = try Data(contentsOf: file)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let rawVocab = model["vocab"] as? [String: NSNumber],
            let merges = model["merges"] as? [[String]]
        else {
            throw LayaError.badBundle("tokenizer.json missing model.vocab/merges")
        }
        vocab = rawVocab.mapValues { $0.int32Value }
        mergeRanks = [:]
        mergeRanks.reserveCapacity(merges.count)
        for (rank, pair) in merges.enumerated() where pair.count == 2 {
            mergeRanks[PairKey(a: pair[0], b: pair[1])] = rank
        }
        let added = root["added_tokens"] as? [[String: Any]] ?? []
        addedTokens = added.compactMap { entry in
            guard let text = entry["content"] as? String,
                  let id = (entry["id"] as? NSNumber)?.int32Value else { return nil }
            return (text, id)
        }.sorted { $0.text.count > $1.text.count }
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

    func splitAddedTokens(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        // Only the specials upstream masks out matter in practice; scanning
        // for every added token keeps parity for literal "<mask>" etc.
        var chunks: [Chunk] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var earliest: (range: Range<Substring.Index>, id: Int32)?
            for token in addedTokens {
                if let range = rest.range(of: token.text),
                   earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                    earliest = (range, token.id)
                }
            }
            guard let hit = earliest else {
                chunks.append(.plain(String(rest)))
                break
            }
            if hit.range.lowerBound > rest.startIndex {
                chunks.append(.plain(String(rest[..<hit.range.lowerBound])))
            }
            chunks.append(.added(hit.id))
            rest = rest[hit.range.upperBound...]
        }
        return chunks
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
        return pieces.filter { $0 != "▁" || vocab["▁"] != nil }
    }

    func encodePiece(_ piece: String) -> [Int32] {
        var symbols: [String] = []
        for scalar in piece.unicodeScalars {
            let ch = String(scalar)
            if vocab[ch] != nil {
                symbols.append(ch)
            } else {
                // Byte fallback: each UTF-8 byte becomes a <0xXX> token.
                symbols.append(contentsOf: ch.utf8.map { String(format: "<0x%02X>", $0) })
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
            if let id = vocab[symbol] { return [id] }
            let bytes = symbol.utf8.map { vocab[String(format: "<0x%02X>", $0)] ?? unkID }
            return bytes.isEmpty ? [unkID] : bytes
        }
    }
}

public enum LayaError: Error, Sendable, Equatable {
    case badBundle(String)
    case modelUnavailable(String)
    case predictionFailed(String)
}
