import RVDomain
import RVPresentation

enum RobotWriter {
    static func line(result: EvaluationResult) -> String {
        switch result.decision {
        case .allow:
            return compact(["schema": "rv.test.v1", "decision": "allow"])
        case .deny(let deny):
            return compact([
                "schema": "rv.test.v1",
                "decision": "deny",
                "pack_id": deny.ruleID.pack.rawValue,
                "rule_id": deny.ruleID.rawValue,
                "reason": factSentence(from: deny.reason),
            ])
        case .indeterminate:
            return compact([
                "schema": "rv.test.v1",
                "decision": "indeterminate",
                "reason": incompleteEvalSentence,
            ])
        }
    }

    private static func compact(_ pairs: KeyValuePairs<String, String>) -> String {
        let body = pairs.map { key, value in
            "\"\(key)\":\"\(escape(value))\""
        }.joined(separator: ",")
        return "{\(body)}\n"
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
