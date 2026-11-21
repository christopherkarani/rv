#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
            // Bare `rv` opens the workspace shell, which needs a terminal.
            // Piped, in CI, or from an agent, print the command list instead
            // of failing with "requires an interactive terminal".
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                _ = HelpDispatch.tryEmit(arguments: [])
                return
            }
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
        await RV.main(args)
    }
}
