# Runtime topology (source-grounded)

`rv-workspace-host` is a distinct executable spawned by `WorkspaceHostLauncher.spawn`
through CLI `WorkspaceHosts.ensure`. A held workspace owner flock excludes another
host for the canonical workspace. The host opens `WorkspaceSessionSupervisor`, which
constructs its empty `AgentInstanceRegistry`; each child has host-owned admission
state (`RuntimeAdmissionSession`, `RuntimeChannelBinding`, `RuntimeCapability`).
Contained children receive admission descriptors, never the supervisor or registry.

`WorkspaceHostServer.start` creates the Unix control socket and mints WorkspaceHostID.
Endpoint records persist workspace/host IDs, owner-token correlation, lock and socket
device/inode, path and UID. Lifecycle/runtime journals persist descriptions. None
restores live principal state. The new `WorkspacePrincipalAuthority` mints an independent
fresh WorkspaceHostGeneration and closes irreversibly on server stop/retirement.

`rvd` separately constructs ServiceRuntime and XPCEvaluateListener. Launchd provides
the named Mach service. Named XPC is Hello-only discovery of an anonymous action
endpoint. The new persistent host client authenticates both Hello replies, registers
on that exact action connection, and services reverse principal-validity requests.
The listener owns the ephemeral LiveWorkspaceHostRegistry. No disk discovery can
populate it. Every registration/action/reverse reply passes the message-derived
SecCode authenticator and exact component/connection checks.

Canonical admission originally normalizes shell/http locally. The new composition
forwards instance-bound shell evaluation through the host bridge before local
normalization; bridge failure refuses it. Legacy non-instance launches still follow
existing admission. The workspace control launch wire currently has no Agent Definition
field, so installed production creation of a bound instance is still an integration gap.
HTTP and other deferred Phase 2 paths are not wired to the bridge.

Evidence symbols: WorkspaceHostProcess.run/WorkspaceHosts.ensure/WorkspaceHostLauncher.spawn;
WorkspaceSessionSupervisor.open/announceAgentInstance; SessionSupervisor.configureSessionDescriptors;
RuntimeAdmissionSession.submit; WorkspaceHostServer.start/retire; WorkspaceEndpointStore.validate;
RVDProcess.run; XPCEvaluateListener.start; XPCPeerSession.handle; MacOSPeerAuthenticator.capture;
HostRuntimeAdmission.configuration.

Forwarding: Unix peer tokens authenticate a connector, not later writers. Runtime spawn
uses POSIX_SPAWN_CLOEXEC_DEFAULT and selective descriptor inheritance; containment denies
Mach lookup/register. These facts alone do not prove deliberate endpoint/send-right
forwarding safe. The required hostile-process forwarding test remains unexecuted.
