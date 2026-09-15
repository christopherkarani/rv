import RVDomain
@testable import RVHooks

func wd(_ raw: String) -> WorkingDirectory {
    WorkingDirectory(validating: raw)!
}

func hookShellCommand(_ request: HookRequest) -> ShellCommand? {
    switch request.invocation {
    case .shell(let command, _):
        return command
    case .file:
        return nil
    }
}

func hookFileAction(_ request: HookRequest) -> FileToolAction? {
    switch request.invocation {
    case .file(let file):
        return file
    case .shell:
        return nil
    }
}

func hookAsk(_ request: HookRequest) -> HostAskHookIntent? {
    switch request.invocation {
    case .shell(_, let ask):
        return ask
    case .file:
        return nil
    }
}
