import RVDomain
import RVEngine

enum CoreWarmup {
    static func prepare(
        snapshots: [PackSnapshot],
        engine: ICUPatternEngine
    ) -> (compiled: CompiledPacks<ICUCompiledPattern>, ready: Bool) {
        do {
            let compiled = try CompiledPacks.compile(packs: snapshots, using: engine)
            let ready = jsonCorePresent(snapshots) && compiledHasRequired(compiled)
            return (compiled, ready)
        } catch {
            return (CompiledPacks(packs: []), false)
        }
    }

    private static func jsonCorePresent(_ packs: [PackSnapshot]) -> Bool {
        func usable(_ id: PackID) -> Bool {
            guard let pack = packs.first(where: { $0.id == id }) else { return false }
            return !pack.safe.isEmpty || !pack.destructive.isEmpty
        }
        return usable(.coreGit) && usable(.coreFilesystem)
    }

    private static func compiledHasRequired(_ compiled: CompiledPacks<ICUCompiledPattern>) -> Bool {
        func hasRule(_ id: PackID, name: String) -> Bool {
            guard let pack = compiled.packs.first(where: { $0.snapshot.id == id }) else {
                return false
            }
            return pack.destructive.contains { $0.rule.name == name }
        }
        return hasRule(.coreGit, name: "reset-hard") && hasRule(.coreFilesystem, name: "fork-bomb")
    }
}
