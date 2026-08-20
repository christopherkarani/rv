#if !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVCLI

@main
enum RVEntry {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if HelpDispatch.tryEmit(arguments: args) {
            return
        }
        await RV.main()
    }
}
