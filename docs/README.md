# rv docs

Design and audit material for contributors. User docs live at
[rykanv.com/docs](https://rykanv.com/docs/introduction). Start with
[`CONTEXT.md`](../CONTEXT.md) for the domain vocabulary.

Files under `plans/` and the phase folders in `security/` are point-in-time
records. They describe intent or evidence as of when they were written, not
necessarily current behavior. The code and tests are the source of truth.

## Security model (`security/`)

Current boundary and policy:

- [Runtime security boundary](security/runtime-boundary.md)
- [Runtime resource profiles](security/runtime-resource-policy.md)
- [Secret gateway policy](security/secrets-gateway-policy.md)
- [Python SDK service boundary](security/sdk-python-boundary.md)
- [Agent identity spec v1](security/rv-agent-identity-spec-v1.md)
- [Runtime adversarial test inventory](security/adversarial-inventory.md)
- [Linux kernel e2e](security/linux-kernel-e2e.md)

Decisions and designs:

- [Runtime mechanism decision](security/runtime-mechanism-decision.md)
- [Socket evaluate peek design](security/socket-evaluate-peek-design.md)
- [Secrets Tier 3 deferred design](security/secrets-tier3-design.md)

Audits and comparisons:

- [Runtime acceptance audit](security/runtime-acceptance.md) and its
  [initial matrix](security/runtime-acceptance-initial.md)
- [Runtime remediation plan](security/runtime-remediation-plan.md)
- [Isolation vs OpenShell findings](security/rv-isolation-openshell-findings.md)
  and [parity tracker](security/openshell-parity-features.md)
- [Secrets competitive study](security/secrets-competitive-study.md)

Agent identity phase records (plan, request, review, and result per phase):
[`phase2`](security/phase2), [`phase2a`](security/phase2a),
[`phase2a1`](security/phase2a1), [`phase2a2`](security/phase2a2),
[`phase2a3`](security/phase2a3), plus the
[owner authentication status](security/phase-2-owner-authentication-status.md),
[peer platform proof](security/phase-2-peer-platform-proof.md), and raw
proof output in [`evidence`](security/evidence).

## Plans (`plans/`)

- [Agent governance](plans/agent-governance/PLAN.md), with the
  [control plane spec](plans/agent-governance/control-plane-spec.md) and
  [transparent HTTPS](plans/agent-governance/transparent-https.md)
- [VM isolation](plans/vm-isolation/PLAN.md),
  [implementation checklist](plans/vm-isolation/IMPLEMENTATION.md), and
  [macOS guest VMs](plans/vm-isolation/MACVM.md)
- [Dotenv tier](plans/dotenv-tier/PLAN.md)
- Laya judge: [guard model plan](plans/laya-guard-model-plan.md),
  [decision record](plans/laya-judge-decision-record.md),
  [Hugging Face distribution](plans/laya-hf-distribution.md)
- [macOS 15 compatibility](superpowers/plans/2026-09-24-macos-15-compat.md)

## Reports (`reports/`)

Standalone HTML reports: [rv overview](reports/rv-overview.html),
[isolation audit](reports/rv-isolation-audit-report.html),
[rv vs OpenShell](reports/rv-vs-openshell.html).
