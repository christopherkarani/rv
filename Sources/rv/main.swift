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
        let args = VersionSpelling.normalized(Array(CommandLine.arguments.dropFirst()))
        if args.isEmpty {
            // Piped, in CI, or from an agent, bare `rv` prints the command
            // list: pipes and scripts always get help (Q3). On a terminal
            // it answers "am I safe?" in four lines (C4).
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                _ = HelpDispatch.tryEmit(arguments: [])
                return
            }
            await BareStatus.run()
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
