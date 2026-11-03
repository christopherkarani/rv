#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVMCPCustodianCore

@main
enum RVMCPCustodian {
    static func main() {
        do {
            let configuration = try CustodianLaunch.parse(arguments: ProcessInfo.processInfo.arguments)
            if configuration.printVersion {
                FileHandle.standardOutput.write(Data((CustodianLaunch.versionLine + "\n").utf8))
                return
            }
            try CustodianProcess.run(configuration: configuration)
        } catch CustodianProcessError.homeMissing {
            FileHandle.standardError.write(Data("rv-mcp-custodian: HOME is required\n".utf8))
            Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("rv-mcp-custodian: launch failed\n".utf8))
            Foundation.exit(1)
        }
    }
}
