import RVDomain
import RVEngine

enum CoreWarmup {
    static func prepare(
        snapshots: [PackSnapshot],
        enabledPacks: [PackID],
        engine: ICUPatternEngine
    ) -> (compiled: CompiledPacks<ICUCompiledPattern>, ready: Bool) {
        let enabled = Set(enabledPacks)
        let toCompile = snapshots.filter { enabled.contains($0.id) }
        let compiled: CompiledPacks<ICUCompiledPattern>
        do {
            compiled = try CompiledPacks.compile(packs: toCompile, using: engine)
        } catch {
            compiled = CompiledPacks(packs: [])
        }
        return (compiled, corePacksAreReady(snapshots: snapshots, compiled: compiled))
    }
}
