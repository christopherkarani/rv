#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVService

// rv-hook-local: the hook-local evaluator the C hook runs before it asks
// rvd (docs/architecture/hook-local-decide.md, LocalHookCommand). Any exit
// but 0 with a final answer sends the call to rvd.

// Every write ends by a deadline counted from here (LocalHookDecider).
let started = ContinuousClock.now
signal(SIGPIPE, SIG_IGN)

guard let arguments = LocalHookCommand.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: rv-hook-local --host <host> --request-id <uuid>\n".utf8))
    exit(2)
}

// The passwd home, whatever the environment says; every path below derives
// from it, and the process holds no other working directory.
let home = LocalHookCommand.passwdHome()
if let home {
    setenv("HOME", home.path, 1)
}
_ = chdir("/")

var input = Data()
while input.count <= LocalHookCommand.inputLimit {
    guard let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty else {
        break
    }
    input.append(chunk)
}

let answer = await LocalHookCommand.respond(to: arguments, input: input, home: home, started: started)
do {
    try FileHandle.standardOutput.write(contentsOf: answer)
} catch {
    exit(1)
}
exit(0)
