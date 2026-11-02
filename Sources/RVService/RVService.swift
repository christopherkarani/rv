#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import RVXPC

public enum RVService {
    public static let machServiceName = RVMachService.name
}
