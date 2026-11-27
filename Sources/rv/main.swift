#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVCLI

@main
enum RVEntry {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            await RV.main(["workspace", "tui"])
            return
        }
        if HelpDispatch.tryEmit(arguments: args) {
            return
        }
        if let unknown = UnknownCommand.message(arguments: args) {
            FileHandle.standardError.write(Data(unknown.utf8))
            exit(64)
        }
        if HookDispatch.matches(args) {
            await HookDispatch.run(arguments: Array(args.dropFirst()))
            return
        }
        await RV.main()
    }
}
