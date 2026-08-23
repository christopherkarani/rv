import Foundation
import RVPresentation

enum RobotDocument {
    case test(TestRobotPayload)
    case explain(ExplainRobotPayload)
    case doctor(DoctorRobotPayload)
    case packsList(PacksRobotPayload)
    case packsInfo(PacksRobotRow)
    case allowlistList([AllowlistRobotRow])
    case allowOnceList([AllowOnceRobotRow])

    func render() -> String {
        switch self {
        case .test(let payload):
            jsonString(payload)
        case .explain(let payload):
            jsonString(payload)
        case .doctor(let payload):
            jsonString(payload)
        case .packsList(let payload):
            jsonString(payload)
        case .packsInfo(let payload):
            jsonString(payload)
        case .allowlistList(let rows):
            jsonString(rows)
        case .allowOnceList(let rows):
            jsonString(rows)
        }
    }
}

private func jsonString(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
        preconditionFailure("RobotDocument payloads are plain values; encoding cannot fail")
    }
    return String(decoding: data, as: UTF8.self)
}
