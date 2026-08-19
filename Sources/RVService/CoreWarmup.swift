import RVDomain
import RVEngine

enum CoreWarmup {
    static func prepare(
        snapshots: [PackSnapshot],
        engine: ICUPatternEngine
    ) -> (compiled: CompiledPacks<ICUCompiledPattern>, ready: Bool) {
        let compiled: CompiledPacks<ICUCompiledPattern>
        do {
            compiled = try CompiledPacks.compile(packs: snapshots, using: engine)
        } catch {
            compiled = CompiledPacks(packs: [])
        }
        return (compiled, corePacksAreReady(snapshots: snapshots, compiled: compiled))
    }
}
