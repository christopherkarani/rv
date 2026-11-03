import Foundation
import Testing
@testable import RVIsolation

/// S3: an entry is either a substitution entry (surfaces, no signing) or an
/// AWS signing entry (a binding, no surfaces). The two cannot be mixed.
@Suite("SecretGatewayEntryMode")
struct SecretGatewayEntryModeTests {
    private let upstream = URL(string: "https://s3.us-east-1.amazonaws.com")!
    private static let credentials =
        #"{"Version":1,"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"secret-example","SessionToken":"token-example"}"#

    private func binding(service: String = "s3") -> AWSSigningBinding {
        AWSSigningBinding(upstream: upstream, region: "us-east-1", service: service, endpointEnv: "AWS_ENDPOINT_URL")
    }

    private func substitution(surfaces: Set<GatewaySurface>? = nil) throws -> SecretGateway.Entry {
        let value = try #require(SecretValue("sk-live"))
        return surfaces.map {
            SecretGateway.Entry(
                secret: "A", prefix: "sk-", value: value, upstream: upstream, fingerprint: nil, runtime: nil,
                surfaces: $0)
        } ?? SecretGateway.Entry(
            secret: "A", prefix: "sk-", value: value, upstream: upstream, fingerprint: nil, runtime: nil)
    }

    private func signing(_ binding: AWSSigningBinding) throws -> SecretGateway.Entry {
        SecretGateway.Entry(
            secret: "A", value: try #require(SecretValue(Self.credentials)), upstream: upstream, fingerprint: nil,
            runtime: nil, signing: binding)
    }

    @Test func substitutionEntryHasSurfacesAndNoSigning() throws {
        let entry = try substitution(surfaces: [.header, .query])
        #expect(entry.surfaces == [.header, .query])
        #expect(entry.isSigning == false)
        #expect(entry.mode == .substitute(surfaces: [.header, .query]))
    }

    @Test func substitutionEntryDefaultsToTheDefaultSurfaces() throws {
        #expect(try substitution().surfaces == GatewaySurface.defaults)
    }

    @Test func signingEntryExposesNoSurfaces() throws {
        let entry = try signing(binding())
        #expect(entry.surfaces.isEmpty)
        #expect(entry.prefix.isEmpty)
        #expect(entry.isSigning)
        #expect(entry.mode == .sign(binding()))
        #expect(SecretGateway.live(entry, token: "t").surfaces.isEmpty)
    }

    @Test func signingEntryKeepsItsBindingForTheS3Tripwire() throws {
        #expect(try signing(binding(service: "s3")).signingBinding?.isS3 == true)
        #expect(try signing(binding(service: "bedrock")).signingBinding?.isS3 == false)
        #expect(try substitution().signingBinding == nil)
    }

    @Test func scrubbedValuesOnlyExpandCredentialSetsForSigningEntries() throws {
        #expect(try substitution().scrubbed.map { $0.revealed() } == [Array("sk-live".utf8)])
        #expect(
            try signing(binding()).scrubbed.map { String(decoding: $0.revealed(), as: UTF8.self) }
                == ["AKIAEXAMPLE", "secret-example", "token-example"])
    }
}
