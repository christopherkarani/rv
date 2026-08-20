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
    let ids = try PackSet.effectiveOrdered(enabled: ["kubernetes"], disabled: [], index: index)
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
        enabled: ["database"],
        disabled: ["database.redis"],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("database.sqlite"))
    #expect(!raw.contains("database.redis"))
    #expect(raw.filter { $0.hasPrefix("database.") }.count == 7)
}

@Test func enablement_presetMembership() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(
        enabled: ["careful_company_running_windows"],
        disabled: ["remote.rsync"],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("careful_company_running_windows.chat"))
    #expect(raw.contains("database.sqlite"))
    #expect(raw.contains("windows.system"))
    #expect(!raw.contains("remote.rsync"))
    // 2 core + 6 leaves + 30 members - 1 disabled = 37
    #expect(ids.count == 37)
}

@Test func enablement_strictGitAndPackageManagers() throws {
    let index = try PackRegistry.loadIndex()
    let ids = try PackSet.effectiveOrdered(
        enabled: ["strict_git", "package_managers"],
        disabled: [],
        index: index
    )
    let raw = Set(ids.map(\.rawValue))
    #expect(raw.contains("strict_git"))
    #expect(raw.contains("package_managers"))
}

@Test func enablement_unknownRejectedWhenAsked() throws {
    let index = try PackRegistry.loadIndex()
    #expect(throws: PackSetError.unknownID("paranoid")) {
        _ = try PackSet.expand(["paranoid"], index: index, rejectUnknown: true)
    }
}
