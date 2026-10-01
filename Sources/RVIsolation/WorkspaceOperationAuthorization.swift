#if os(macOS)
/// Endpoint possession, component identity and operator permission are separate.
/// Until scoped operator permits arrive over an authenticated host/service channel,
/// mutation and terminal operations cannot be authorized by an owner token.
enum WorkspaceOperationAuthorization {
    static func permits(_ operation: WorkspaceControlOp, peer: PlatformPeerEvidence) -> Bool {
        switch operation {
        case .hello, .capabilities, .ping:
            return peer.componentRole != nil
        case .describeWorkspace, .listRuntimes:
            return peer.componentRole == .service || peer.componentRole == .workspaceHost
        case .launchRuntime, .launchAgentRuntime, .launchCustomRuntime, .ensureTerminalRuntime, .cancelRuntime, .closeWorkspace,
            .detach, .subscribeTerminal, .unsubscribeTerminal, .terminalInput,
            .acquireTerminalInput, .releaseTerminalInput, .resizeTerminal:
            return false
        case .workspaceClosed, .terminalReplayBegin, .terminalReplay, .terminalReplayEnd,
            .terminalOutput, .terminalInputOwner, .terminalWindow, .runtimeExited, .terminalOverflow:
            return false
        }
    }
}
#endif
