import Testing
@testable import RVIPC

struct EvaluationRouteTests {
    @Test func transportAbsentIsInProcess() {
        #expect(EvaluationRoute.path(for: .transportAbsent) == .inProcess)
    }

    @Test func missingAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: nil
                )
            ) == .inProcess
        )
    }

    @Test func emptyAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: ""
                )
            ) == .inProcess
        )
    }

    @Test func unparseableAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: "not-a-version"
                )
            ) == .inProcess
        )
    }

    @Test func emptyClientSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "", advertisedServiceSemver: "1.0.0")
            ) == .inProcess
        )
    }

    @Test func unparseableClientSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: "not-a-version",
                    advertisedServiceSemver: "1.0.0"
                )
            ) == .inProcess
        )
    }

    @Test func equalMajorVersionsUseXPC() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "1.0.0", advertisedServiceSemver: "1.9.9")
            ) == .xpc
        )
    }

    @Test func differentMajorVersionsUseInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "1.0.0", advertisedServiceSemver: "2.0.0")
            ) == .inProcess
        )
    }
}
