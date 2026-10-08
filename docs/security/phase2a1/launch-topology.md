# Production launch topology

Baseline: branch `phase-2Identity`, HEAD `2df5484972fa2ad1afe9394941e023e7ad01bef0`. See baseline.json for the exact dirty candidate and recovery archive.

## Before this pass

`rv workspace run` / OpenCode / TUI -> `WorkspaceCommandRun.runInteractive` / host client -> `WorkspaceHosts.ensure` -> `WorkspaceHostLauncher.spawn` -> `rv-workspace-host` -> `WorkspaceHostProcess.run` -> `WorkspaceHostServer.operation(.launchRuntime)` -> `launch` -> `WorkspaceSessionSupervisor.launch` (omitted optional `agentDefinition`, therefore nil) -> `spawn` -> runtime admission channel with no AgentInstance binding.

Executable, arguments, integration hook/tag and explicit profile ID were caller-controlled. No trusted definition name was present. An executable basename, HookHost or tag did not constitute a definition selector. The optional raw supervisor API remains internal for existing Phase 1 fixtures; production control now uses explicit adapters.

## After this pass

`rv workspace agent <definition-id> -- <args>` -> `WorkspaceCommandRun.runAgent` -> common interactive terminal path -> `WorkspaceClient.launchAgentRuntime` (requires identityAgentLaunchV1 feature) -> bounded wire `.launchAgentRuntime` -> `WorkspaceHostServer.operation` -> existing scoped authorization gate -> `launchIdentity` -> `RVPolicy.AgentLaunchSelection.resolveNamed` against the immutable set loaded in `WorkspaceHostProcess.run` via Phase 1 `AgentDefinitionStore.load` -> `WorkspaceSessionSupervisor.launchAgent(selection:)` -> existing prepare/spawn/announce/bind-before-resume/establish/activate -> real `AgentInstanceRegistry` active record -> `RuntimeChannelBinding` references that instance -> `RuntimeAdmissionSubject.agent` resolves fresh context -> HostAdmission service evaluation -> persistent authenticated WorkspaceHostBridgeClient -> rvd XPCWorkspaceHostBridge -> LiveWorkspaceHostRegistry validates live host reference -> ServiceValidatedAgentContext -> ServiceRuntime.evaluateAgent -> GatedEvaluate.evaluateAgent.

The host obtains `.config/rv` from kernel account home via getpwuid(getuid()); caller HOME does not choose the definition store. Definitions and resource policy load before workspace opening. Missing definitions produce an empty set; unsafe/invalid definitions fail host startup. Named selection uses exact ID/project and exactly one already-supported operator executable link whose name equals the ID. The request cannot override its executable/profile/hook/tag. Revision, target, profile and definition are retained together by value from one snapshot.

Custom: `rv workspace custom --expected-content-digest-sha256 <digest> -- /absolute/executable <args>` -> `.launchCustomRuntime` -> existing `AdHocAgentSnapshot` -> required immutable selection -> launchAgent. Expected digest is definition intent, never observed image evidence. Custom carries no named authority, credential bindings or integration identity; profile is nil.

Legacy: existing run/OpenCode/TUI operations retain `.launchRuntime` and `launchLegacy`, explicitly passing nil definition. Labels do not mint a principal. Authorization behavior is preserved.

## Current reachability gate

`WorkspaceOperationAuthorization.permits` refuses launchAgentRuntime, launchCustomRuntime and legacy launch/terminal operations unconditionally pending scoped operator permission. Component trust alone cannot grant that permission. Thus dispatch integration is implemented but the installed CLI cannot reach selection today. Approval/operator authorization is outside this pass. The protected installed peer-trust manifest is also absent. No successful three-process oracle is claimed.
