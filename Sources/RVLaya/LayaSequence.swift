import Foundation

/// One typed question, in upstream Laya shape.
public struct LayaQuestion: Sendable {
    public enum Kind: String, Sendable {
        case choice
        case score
        case noul

        public var qtype: Int32 {
            switch self {
            case .choice: return 0
            case .score: return 1
            case .noul: return 2
            }
        }
    }

    public var kind: Kind
    public var instructions: String
    /// Ordered (label, criterion) for choice; ordered levels for score
    /// (label is ignored); empty for noul.
    public var options: [(label: String, criterion: String)]

    public init(kind: Kind, instructions: String, options: [(label: String, criterion: String)]) {
        self.kind = kind
        self.instructions = instructions
        self.options = options
    }

    /// Option texts exactly as upstream `render_options` builds them.
    public var renderedOptions: [String] {
        switch kind {
        case .choice:
            return options.map { $0.criterion.isEmpty ? $0.label : "\($0.label): \($0.criterion)" }
        case .score:
            return options.enumerated().map { "level \($0.offset): \($0.element.criterion)" }
        case .noul:
            return ["false: no, the statement does not hold", "true: yes, the statement holds"]
        }
    }
}

/// Token sequence for one question: `[CLS] <type> question: ins [SEP]
/// [MASK] opt0 [MASK] opt1 ... [SEP] state [SEP]` (upstream `build_sequence`).
public struct LayaSequence: Sendable, Equatable {
    public var ids: [Int32]
    public var markers: [Int32]
    public var qtype: Int32

    public static func build(
        tokenizer: LayaTokenizer,
        state: String,
        question: LayaQuestion,
        maxLen: Int = 1024,
        headMaxLen: Int = 256
    ) -> LayaSequence {
        func unmasked(_ s: String) -> String {
            s.replacingOccurrences(of: tokenizer.maskToken, with: " ")
        }
        let headText = "\(question.kind.rawValue) question: \(unmasked(question.instructions))"
        var headIDs = tokenizer.encode(headText)
        var optIDs: [[Int32]] = question.renderedOptions.map { opt in
            [tokenizer.maskID] + Array(tokenizer.encode(" " + unmasked(opt)).prefix(48))
        }
        var optBudget = headMaxLen - optIDs.reduce(0) { $0 + $1.count }
        if optBudget < 16 {
            let per = max(4, (headMaxLen - 16) / max(1, optIDs.count))
            optIDs = optIDs.map { Array($0.prefix(per)) }
            optBudget = headMaxLen - optIDs.reduce(0) { $0 + $1.count }
        }
        headIDs = Array(headIDs.prefix(max(8, optBudget)))
        var ids: [Int32] = [tokenizer.clsID] + headIDs + [tokenizer.sepID]
        var markers: [Int32] = []
        for opt in optIDs {
            markers.append(Int32(ids.count))
            ids.append(contentsOf: opt)
        }
        ids.append(tokenizer.sepID)
        let room = max(0, maxLen - ids.count - 1)
        let stateIDs = tokenizer.encode(unmasked(state))
        ids.append(contentsOf: stateIDs.prefix(room))
        ids.append(tokenizer.sepID)
        ids = Array(ids.prefix(maxLen))
        markers = markers.filter { Int($0) < maxLen }
        return LayaSequence(ids: ids, markers: markers, qtype: question.kind.qtype)
    }
}
