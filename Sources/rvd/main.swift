#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVService

@main
enum RVD {
    static func main() {
        do {
            let configuration = try RVDLaunch.parse(arguments: ProcessInfo.processInfo.arguments)
            if configuration.printVersion {
                FileHandle.standardOutput.write(Data((RVDLaunch.versionLine + "\n").utf8))
                return
            }
            try RVDProcess.run(configuration: configuration)
        } catch RVDLaunchError.socketUnsupported {
            FileHandle.standardError.write(
                Data("rvd: production transport is XPC; --socket is not supported\n".utf8)
            )
            Foundation.exit(2)
        } catch {
            FileHandle.standardError.write(Data("rvd: launch failed\n".utf8))
            Foundation.exit(1)
        }
    }
}
