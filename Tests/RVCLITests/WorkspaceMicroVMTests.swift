import ArgumentParser
import RVIsolation
import Testing
@testable import RVCLI

@Test func workspaceRunParsesMicroVMOptionsSeparatelyFromCommand() throws {
    let parsed = try WorkspaceRun.parse([
        "--microvm", "alpine:3.20", "--cpus", "2", "--memory-mib", "1024",
        "--", "/bin/sh", "-c", "uname -a",
    ])
    #expect(parsed.microvm == "alpine:3.20")
    #expect(parsed.cpus == 2)
    #expect(parsed.memoryMib == 1024)
    #expect(parsed.command.drop(while: { $0 == "--" }) == ["/bin/sh", "-c", "uname -a"])
    let options = try WorkspaceMicroVM.options(image: parsed.microvm, cpus: parsed.cpus, memoryMiB: parsed.memoryMib)
    #expect(options == MicroVMLaunchOptions(image: "alpine:3.20", cpus: 2, memoryMiB: 1024))
}

@Test func microVMOptionsAreOptionalAndValidated() throws {
    #expect(try WorkspaceMicroVM.options(image: nil, cpus: nil, memoryMiB: nil) == nil)
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, cpus: 2, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, cpus: nil, memoryMiB: 512) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "alpine", cpus: 0, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "alpine", cpus: nil, memoryMiB: 64) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "--root=/x", cpus: nil, memoryMiB: nil) }
}

@Test func microVMHelperInvocationsNameTheImage() {
    #expect(WorkspaceMicroVM.statusArguments(image: "alpine") == ["status", "--image", "alpine"])
    #expect(WorkspaceMicroVM.prepareArguments(image: "alpine") == ["prepare", "--image", "alpine"])
}
