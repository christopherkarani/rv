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
    let options = try WorkspaceMicroVM.options(image: parsed.microvm, macOSImage: parsed.macvm, cpus: parsed.cpus, memoryMiB: parsed.memoryMib)
    #expect(options == MicroVMLaunchOptions(image: "alpine:3.20", cpus: 2, memoryMiB: 1024))
}

@Test func microVMOptionsAreOptionalAndValidated() throws {
    #expect(try WorkspaceMicroVM.options(image: nil, macOSImage: nil, cpus: nil, memoryMiB: nil) == nil)
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, macOSImage: nil, cpus: 2, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, macOSImage: nil, cpus: nil, memoryMiB: 512) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "alpine", macOSImage: nil, cpus: 0, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "alpine", macOSImage: nil, cpus: nil, memoryMiB: 64) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "--root=/x", macOSImage: nil, cpus: nil, memoryMiB: nil) }
}

@Test func microVMHelperInvocationsNameTheImage() {
    #expect(WorkspaceMicroVM.statusArguments(image: "alpine") == ["status", "--image", "alpine"])
    #expect(WorkspaceMicroVM.prepareArguments(image: "alpine") == ["prepare", "--image", "alpine"])
}

@Test func workspaceRunParsesMacOSGuestOptions() throws {
    let parsed = try WorkspaceRun.parse(["--macvm", "dev", "--memory-mib", "8192", "--", "/usr/bin/swift", "build"])
    #expect(parsed.macvm == "dev")
    let options = try WorkspaceMicroVM.options(image: parsed.microvm, macOSImage: parsed.macvm, cpus: parsed.cpus, memoryMiB: parsed.memoryMib)
    #expect(options == MicroVMLaunchOptions(image: "dev", guest: .macOS, memoryMiB: 8192))
}

@Test func macOSGuestOptionsAreValidatedAndExclusive() {
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: "alpine", macOSImage: "dev", cpus: nil, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, macOSImage: "Dev", cpus: nil, memoryMiB: nil) }
    #expect(throws: ValidationError.self) { try WorkspaceMicroVM.options(image: nil, macOSImage: "dev", cpus: nil, memoryMiB: 2048) }
}

@Test func macOSGuestsAreNeverPreparedImplicitly() {
    let options = MicroVMLaunchOptions(image: "dev", guest: .macOS)!
    #expect(WorkspaceMicroVM.prepareInstruction(options) == "rv-macvm prepare --image dev")
    #expect(WorkspaceMicroVM.preparesImplicitly(options) == false)
    #expect(WorkspaceMicroVM.preparesImplicitly(MicroVMLaunchOptions(image: "alpine")!))
}
