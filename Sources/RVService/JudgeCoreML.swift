import Foundation
import RVLaya
import RVPolicy

extension JudgeRuntime {
    /// `~/.config/rv/cache/laya`: the verified compiled models and rvd's
    /// Core ML crash marker. Under rv's config dir, which
    /// `core.secrets:home-rv-config` keeps agents from reading or writing,
    /// so no agent can plant a model or forge the crash history. nil when
    /// HOME is unusable (judge loads then refuse, to review).
    public static func coreMLStateRoot() -> URL? {
        HomeDirectory.processConfigDirectory().map(CoreMLGuard.stateRoot(configDirectory:))
    }

    /// The guard judges load through: rvd's bound daemon guard, else an
    /// untracked one (disk precheck plus the verified model cache, no crash
    /// marker) bound on first use.
    static var coreMLGuard: CoreMLGuard {
        CoreMLGuard.current(orBind: .untracked(stateRoot: coreMLStateRoot()))
    }
}
