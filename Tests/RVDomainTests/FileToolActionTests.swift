import Testing
@testable import RVDomain

@Test func fileToolKind_isClosedReadEditWrite() {
    #expect(FileToolKind.read.rawValue == "read")
    #expect(FileToolKind.edit.rawValue == "edit")
    #expect(FileToolKind.write.rawValue == "write")
}

@Test func fileToolKind_mapsHostAliases() {
    #expect(FileToolKind(toolName: "Read") == .read)
    #expect(FileToolKind(toolName: "read_file") == .read)
    #expect(FileToolKind(toolName: "Edit") == .edit)
    #expect(FileToolKind(toolName: "edit_file") == .edit)
    #expect(FileToolKind(toolName: "Write") == .write)
    #expect(FileToolKind(toolName: "write_file") == .write)
    #expect(FileToolKind(toolName: "Grep") == nil)
    #expect(FileToolKind(toolName: "MCP") == nil)
    #expect(FileToolKind(toolName: "Bash") == nil)
}

@Test func fileToolAction_holdsKindAndPath() {
    let action = FileToolAction(
        kind: .read,
        path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
    )
    #expect(action.kind == .read)
    #expect(action.path.rawValue == "/tmp/rv-oracle/.env")
    #expect(action.path.isEmpty == false)
}

@Test func fileToolPath_firstPresentPrefersFilePathThenPathThenTargetFileThenTarget() {
    #expect(
        FileToolPath.firstPresent("file", "path", "target_file", "target")?.rawValue == "file"
    )
    #expect(
        FileToolPath.firstPresent("", "path", "target_file", "target")?.rawValue == "path"
    )
    #expect(
        FileToolPath.firstPresent(nil, "  ", "target_file", "target")?.rawValue == "target_file"
    )
    #expect(FileToolPath.firstPresent(nil, "", nil, "target")?.rawValue == "target")
    #expect(FileToolPath.firstPresent(nil, "  ", nil, "") == nil)
}

@Test func fileToolPath_emptyIsRepresentable() {
    #expect(FileToolPath(rawValue: "").isEmpty)
    #expect(FileToolPath(rawValue: "   ").isEmpty)
}
