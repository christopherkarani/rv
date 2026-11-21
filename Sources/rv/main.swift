#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVCLI

@main
enum RVEntry {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        // `-V` is the other common spelling of `--version`.
        if args == ["-V"] {
            args = ["--version"]
        }
        if args.isEmpty {
            await RV.main(["workspace", "tui"])
            return
        }
        if HelpDispatch.tryEmit(arguments: args) {
            return
        }
        if HookDispatch.matches(args) {
            await HookDispatch.run(arguments: Array(args.dropFirst()))
            return
        }
        await RV.main(args)
    }
}
