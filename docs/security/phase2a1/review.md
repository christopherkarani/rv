# Fresh review evidence

Fresh code-reviewer received Phase 1 spec, full current tracked/untracked source diff, production call chain, selection code and oracle status, without implementation rationale.

1. Installed production dispatch unreachable: independently reproduced by source branch: WorkspaceHostServer.operation rejects unless WorkspaceOperationAuthorization.permits; both new operations return false for every peer. Dependency retained, not fixed through an authority bypass.
2. Ambient legacy credential grants: reviewer traced new launchAgent through prepareSeatbelt, AgentBin.resolve and PTY stageAgentHomes. Independently reproduced in verification/ambient-red.log: the compiled policy included the dummy credential literal, but the actual custom child read was DENIED. No credential readability was proven. Identity preparation now suppresses AgentBin integration and carries that decision into spawn, environment and PTY staging; legacy remains unchanged. Both final isolated-helper probes pass. Fresh reviewer approved production suppression and isolated test harness by inspection with no actionable defects.
3. Reviewer retracted preliminary requiredAssurance issue after inspecting actual enum: only unattested and launchObserved are representable. No fix needed; pinned image requirements already fail selection.
