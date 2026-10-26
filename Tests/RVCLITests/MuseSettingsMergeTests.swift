import Foundation
import RVDomain
import Testing
@testable import RVCLI

private let museHooksPath = "/tmp/home/.config/muse/rv-hooks.json"
private let museSettingsPath = "/tmp/home/.config/muse/settings.json"

private func museSettings(_ body: String) -> Data {
    Data(body.utf8)
}

@Test func museMerge_inspectClassifiesKeyStates() {
    let ours = museSettings(
        #"{"schema_version":1,"managed_hooks_path":"\#(museHooksPath)"}"#
    )
    #expect(MuseSettingsMerge.inspect(ours, hooksPath: museHooksPath) == .ours)
    let foreign = museSettings(
        #"{"schema_version":1,"managed_hooks_path":"/other/hooks.json"}"#
    )
    #expect(MuseSettingsMerge.inspect(foreign, hooksPath: museHooksPath) == .foreignKey)
    let missing = museSettings(#"{"schema_version":1,"provider":"meta"}"#)
    #expect(MuseSettingsMerge.inspect(missing, hooksPath: museHooksPath) == .missingKey)
}

@Test func museMerge_inspectUnmergeableStates() {
    #expect(MuseSettingsMerge.inspect(nil, hooksPath: museHooksPath) == .unmergeable)
    #expect(
        MuseSettingsMerge.inspect(museSettings("not-json"), hooksPath: museHooksPath)
            == .unmergeable
    )
    #expect(
        MuseSettingsMerge.inspect(museSettings("[1,2]"), hooksPath: museHooksPath)
            == .unmergeable
    )
    #expect(
        MuseSettingsMerge.inspect(museSettings("{}"), hooksPath: museHooksPath)
            == .unmergeable
    )
    #expect(
        MuseSettingsMerge.inspect(
            museSettings(#"{"schema_version":2,"managed_hooks_path":"\#(museHooksPath)"}"#),
            hooksPath: museHooksPath
        ) == .unmergeable
    )
    #expect(
        MuseSettingsMerge.inspect(
            museSettings(#"{"schema_version":1,"managed_hooks_path":""}"#),
            hooksPath: museHooksPath
        ) == .unmergeable
    )
    #expect(
        MuseSettingsMerge.inspect(
            museSettings(#"{"schema_version":1,"managed_hooks_path":42}"#),
            hooksPath: museHooksPath
        ) == .unmergeable
    )
}

@Test func museMerge_missingKeySetsKeyAndPreservesOthers() throws {
    let merged = MuseSettingsMerge.merge(
        existingData: museSettings(#"{"schema_version":1,"provider":"meta"}"#),
        hooksPath: museHooksPath
    )
    #expect(merged.wrote)
    #expect(
        String(data: merged.data, encoding: .utf8)
            == """
            {
              "managed_hooks_path" : "\\/tmp\\/home\\/.config\\/muse\\/rv-hooks.json",
              "provider" : "meta",
              "schema_version" : 1
            }
            """
    )
    let roundTrip = try #require(
        JSONSerialization.jsonObject(with: merged.data) as? [String: Any]
    )
    #expect(roundTrip["managed_hooks_path"] as? String == museHooksPath)
    #expect(roundTrip["provider"] as? String == "meta")
    #expect(roundTrip["schema_version"] as? Int == 1)
}

@Test func museMerge_neverOverwritesOrSeeds() {
    let foreign = museSettings(
        #"{"schema_version":1,"managed_hooks_path":"/other/hooks.json"}"#
    )
    let kept = MuseSettingsMerge.merge(existingData: foreign, hooksPath: museHooksPath)
    #expect(kept.wrote == false)
    #expect(kept.data == foreign)

    let ours = museSettings(
        #"{"schema_version":1,"managed_hooks_path":"\#(museHooksPath)"}"#
    )
    let idempotent = MuseSettingsMerge.merge(existingData: ours, hooksPath: museHooksPath)
    #expect(idempotent.wrote == false)
    #expect(idempotent.data == ours)

    let malformed = museSettings("not-json")
    let untouched = MuseSettingsMerge.merge(existingData: malformed, hooksPath: museHooksPath)
    #expect(untouched.wrote == false)
    #expect(untouched.data == malformed)

    let missing = MuseSettingsMerge.merge(existingData: nil, hooksPath: museHooksPath)
    #expect(missing.wrote == false)
}

@Test func museMerge_stripRemovesOnlyOwnedKey() throws {
    let ours = museSettings(
        #"{"schema_version":1,"provider":"meta","managed_hooks_path":"\#(museHooksPath)"}"#
    )
    let stripped = MuseSettingsMerge.strip(existingData: ours, hooksPath: museHooksPath)
    #expect(stripped.changed)
    let roundTrip = try #require(
        JSONSerialization.jsonObject(with: stripped.data) as? [String: Any]
    )
    #expect(roundTrip["managed_hooks_path"] == nil)
    #expect(roundTrip["provider"] as? String == "meta")
    #expect(roundTrip["schema_version"] as? Int == 1)

    let foreign = museSettings(
        #"{"schema_version":1,"managed_hooks_path":"/other/hooks.json"}"#
    )
    let kept = MuseSettingsMerge.strip(existingData: foreign, hooksPath: museHooksPath)
    #expect(kept.changed == false)
    #expect(kept.data == foreign)

    let noKey = museSettings(#"{"schema_version":1}"#)
    let noOp = MuseSettingsMerge.strip(existingData: noKey, hooksPath: museHooksPath)
    #expect(noOp.changed == false)
    #expect(noOp.data == noKey)

    let malformed = museSettings("not-json")
    let untouched = MuseSettingsMerge.strip(existingData: malformed, hooksPath: museHooksPath)
    #expect(untouched.changed == false)
    #expect(untouched.data == malformed)
}

@Test func museMerge_settingsPathIsSibling() {
    #expect(
        MuseSettingsMerge.settingsPath(hooksPath: museHooksPath) == museSettingsPath
    )
}
