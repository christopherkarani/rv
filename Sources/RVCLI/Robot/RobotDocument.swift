import Foundation
import RVPresentation

/// Closed machine-output document for CLI robot JSON.
enum RobotDocument {
    case test(TestRobotPayload)
    case explain(ExplainRobotPayload)
    case doctor(DoctorRobotPayload)
    case packsList(PacksRobotPayload)
    case packsInfo(PacksRobotRow)

    /// Returns this document as JSON with sorted keys and unescaped slashes.
    func render() -> String {
        switch self {
        case .test(let payload):
            Self.jsonString(payload)
        case .explain(let payload):
            Self.jsonString(payload)
        case .doctor(let payload):
            Self.jsonString(payload)
        case .packsList(let payload):
            Self.jsonString(payload)
        case .packsInfo(let payload):
            Self.jsonString(payload)
        }
    }

    private static func jsonString(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            preconditionFailure(
                "RobotDocument payloads are plain values; encoding cannot fail (\(error))"
            )
        }
    }
}
