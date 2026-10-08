# Phase 2A plan

Starting branch: phase-2Identity. HEAD: 2df5484972fa2ad1afe9394941e023e7ad01bef0.
Phase 1 baseline: a85151b68ec15809679c40afc0ec26ef322468b3.
Existing draft is committed, not uncommitted. Recovery bundle: /private/tmp/rv-phase2-draft-2df54849.bundle.
Pre-existing untracked content: Vendor/. No Phase 1 registry/lifecycle changes planned.

- [x] Preserve draft and record baseline.
- [x] Establish source topology before design.
- [x] Implement non-authoritative principal reference and ephemeral host-generation model.
- [x] Implement candidate authenticated bidirectional host/service bridge and live validation (installed proof blocked).
- [ ] Provision exact protected development identities and prove installed cross-process roles.
- [ ] Prove canonical evaluation, revocation, restart and descriptor/endpoint forwarding behavior.
- [x] Run required regression gates and fresh adversarial review; results are not green.
- [x] Report BLOCKED because installed product/forwarding proofs and full green regressions are absent.

Design constraint: Unix connector credentials alone do not authenticate writers after FD transfer.
Use per-message XPC code authentication; never assign component roles from caller-supplied fields.
The normal host runtime evaluation currently runs locally, and control launch carries no Agent Definition.
These are explicit integration gaps, not already solved authentication paths.

Review: candidate focused suites pass; grant-consumption finding reproduced and fixed. Production launch, protected provisioning, cross-process/forwarding and full green regression gates remain blocked. No approval resolver or Phase 3 work.
