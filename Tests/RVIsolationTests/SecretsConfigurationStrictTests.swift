import Foundation
import Testing
@testable import RVIsolation

@Suite("SecretsConfiguration strict parsing")
struct SecretsConfigurationStrictTests {
    private func reason(_ json: String) -> String? {
        guard case .failure(.invalid(let reason)) = SecretsConfiguration.decode(Data(json.utf8)) else { return nil }
        return reason
    }

    private static let secret =
        #"{"name":"X","source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}"#

    @Test func duplicateTopLevelKeyIsRefusedAndNamed() {
        let json = #"{"version":1,"secrets":[\#(Self.secret)],"secrets":[]}"#
        #expect(reason(json) == "duplicate key secrets")
    }

    @Test func duplicateKeyInsideASecretIsRefusedAndNamed() {
        let json = #"{"version":1,"secrets":[{"name":"X","name":"Y","source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(json) == "duplicate key name")
    }

    @Test func duplicateKeyDeepInASourceIsRefusedAndNamed() {
        let json = #"{"version":1,"secrets":[{"name":"X","source":{"hostEnvironment":{"variable":"A","variable":"B"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(json) == "duplicate key variable")
    }

    @Test func duplicateKeySpelledWithAUnicodeEscapeIsRefusedAndNamed() {
        let json = #"{"version":1,"secrets":[{"name":"X","\u006eame":"Y","source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(json) == "duplicate key name")
    }

    @Test func duplicateKeyWithAControlCharacterIsNamedEscaped() {
        #expect(reason(#"{"version":1,"a\u0007":1,"a\u0007":2}"#) == #"duplicate key a\u0007"#)
    }

    @Test func keyTextInsideAStringValueIsNotADuplicate() {
        let json = #"{"version":1,"secrets":[{"name":"X","description":"\"name\":\"Y\"","source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(json) == nil)
    }

    @Test func sameKeyInSiblingObjectsIsNotADuplicate() {
        let json = #"{"version":1,"secrets":[\#(Self.secret),{"name":"Y","source":{"hostEnvironment":{"variable":"Y"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(json) == nil)
    }

    @Test(arguments: ["true", "1.0", #""1""#, "2", "null", "1e0", "01"])
    func versionMustBeTheNumberOne(_ version: String) {
        #expect(reason(#"{"version":\#(version),"secrets":[]}"#) != nil)
    }

    @Test func versionOneIsAccepted() {
        #expect(reason(#"{"version":1,"secrets":[]}"#) == nil)
    }

    @Test func versionTrueSaysVersionMustBeOne() {
        #expect(reason(#"{"version":true,"secrets":[]}"#) == "version must be 1")
    }

    @Test func nonUTF8IsRefused() {
        let data = Data([0x7B, 0xFF, 0x7D])
        guard case .failure(.invalid(let why)) = SecretsConfiguration.decode(data) else {
            Issue.record("expected failure")
            return
        }
        #expect(why == "not valid UTF-8")
    }

    @Test func mixedAgentArrayAndNumericFieldsStayRefused() {
        let mixed = #"{"version":1,"secrets":[{"name":"X","agents":["codex",1],"source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(mixed) == "X.agents must be up to 8 distinct agent tags")
        let number = #"{"version":1,"secrets":[{"name":"X","description":5,"source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(number) == "X.description must be short text")
        let null = #"{"version":1,"secrets":[{"name":"X","type":null,"source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#
        #expect(reason(null) == "X.type must be short text")
    }

    @Test func gatewayMethodsKeepTheirShapes() {
        func gateway(_ methods: String) -> String {
            #"{"version":1,"secrets":[{"name":"K","source":{"hostEnvironment":{"variable":"K"}},"delivery":{"gateway":{"upstream":"https://a.example.com","baseURLEnv":"K_BASE","allow":[{"methods":\#(methods),"path":"/v1/**"}]}}}]}"#
        }
        #expect(reason(gateway(#""*""#)) == nil)
        #expect(reason(gateway(#"["GET","POST"]"#)) == nil)
        #expect(reason(gateway(#"["GET","GET"]"#)) != nil)
        #expect(reason(gateway(#"["GET",1]"#)) != nil)
        #expect(reason(gateway("5")) != nil)
    }
}
