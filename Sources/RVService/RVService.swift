#if !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

public enum RVService {
    public static let machServiceName = "dev.rv.evaluate"
}
