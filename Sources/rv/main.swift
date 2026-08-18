#if !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import RVCLI

@main
enum RVEntry {
    static func main() async {
        await RV.main()
    }
}
