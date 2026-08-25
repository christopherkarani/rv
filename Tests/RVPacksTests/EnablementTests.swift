import Testing
import RVDomain
@testable import RVPacks

@Test func enablement_defaultsAreCoreOnly() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(enabled: [], disabled: [], index: index)
    #expect(Set(ids.map(\.rawValue)) == Set(["core.filesystem", "core.git"]))
    #expect(!ids.map(\.rawValue).contains("system.disk"))
    #expect(!ids.map(\.rawValue).contains("database.postgresql"))
    #expect(!ids.map(\.rawValue).contains("containers.docker"))
}

@Test func enablement_k8sCategoryAddsThreePlusCore() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(enabled: [.category("kubernetes")], disabled: [], index: index)
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("core.git"))
    #expect(raw.contains("kubernetes.kubectl"))
    #expect(raw.contains("kubernetes.helm"))
    #expect(raw.contains("kubernetes.kustomize"))
    #expect(raw.count == 5)
}

@Test func enablement_databaseMinusRedis() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(
        enabled: [.category("database")],
        disabled: [.id(PackID(rawValue: "database.redis"))],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("database.sqlite"))
    #expect(!raw.contains("database.redis"))
    #expect(raw.filter { $0.hasPrefix("database.") }.count == 7)
}

@Test func enablement_presetMembershipDropsWindowsOSPacks() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(
        enabled: SelectionToken.parse("careful_company_running_windows", index: index),
        disabled: [.id(PackID(rawValue: "remote.rsync"))],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("careful_company_running_windows.chat"))
    #expect(raw.contains("database.sqlite"))
    #expect(!raw.contains("windows.system"))
    #expect(!raw.contains("windows.filesystem"))
    #expect(!raw.contains("remote.rsync"))
    // 2 core + 6 leaves + 26 members - 1 disabled = 33
    #expect(ids.count == 33)
}

@Test func enablement_windowsOSPackIsRejected() throws {
    let index = try PackRegistry.loadIndex()
    #expect(throws: PackSetError.unknownID(.id(PackID(rawValue: "windows.filesystem")))) {
        _ = try PackSet.expand(
            [.id(PackID(rawValue: "windows.filesystem"))],
            index: index,
            rejectUnknown: true
        )
    }
}

@Test func enablement_strictGitAndPackageManagers() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(
        enabled: [
            .id(PackID(rawValue: "strict_git")),
            .category("package_managers"),
        ],
        disabled: [],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("strict_git"))
    #expect(raw.contains("package_managers"))
}

@Test func enablement_unknownRejectedWhenAsked() throws {
    let index = try PackRegistry.loadIndex()
    #expect(throws: PackSetError.unknownID(.id(PackID(rawValue: "paranoid")))) {
        _ = try PackSet.expand([.id(PackID(rawValue: "paranoid"))], index: index, rejectUnknown: true)
    }
}

@Test func enablement_unknownSkippedByDefault() throws {
    let index = try PackRegistry.loadIndex()
    let expanded = try PackSet.expand(
        [
            .id(PackID(rawValue: "paranoid")),
            .category("nosuchcategory"),
            .preset("nosuchpreset"),
            .id(PackID(rawValue: "strict_git")),
        ],
        index: index,
        rejectUnknown: false
    )
    #expect(expanded == [PackID(rawValue: "strict_git")])
}

@Test func enablement_orderIsTierThenName() throws {
    let index = try PackRegistry.loadIndex()
    let ordered = PackSet.order(
        [
            PackID(rawValue: "system.disk"),
            PackID(rawValue: "core.git"),
            PackID(rawValue: "database.sqlite"),
        ],
        index: index
    )
    #expect(ordered.map(\.rawValue) == ["core.git", "system.disk", "database.sqlite"])
}

@Test func enablement_orderDropsUnknownIDs() {
    let index = PackIndex(
        pinVersion: "0",
        pinTag: "tag",
        pinCommit: "commit",
        packCount: 1,
        defaultEnabled: [],
        categories: ["core": ["core.git"]],
        presets: [:],
        tiers: ["core": 1]
    )
    let ordered = PackSet.order(
        Set([PackID(rawValue: "core.git"), PackID(rawValue: "not.declared")]),
        index: index
    )
    #expect(ordered.map(\.rawValue) == ["core.git"])
}
