"""Curated SDK types: frozen, validated, free of wire quirks.

Each type converts from raw wire dicts (``from_wire``) with the strictness of
``sdk/WIRE.md`` §5 (fail closed, ``DecodeError``) and builds request params
(``to_wire_*``) validated eagerly (``ValueError`` on programmer error).
``client`` converts; ``raw`` bypasses this layer entirely.
"""

from __future__ import annotations

import enum
import os
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from typing import Any, TypeVar

from .errors import DecodeError
from .versions import SDK_IPC_SEMVER

DAY_ONE_PACKS = ("core.filesystem", "core.git", "system.disk")

_PACK_RE = re.compile(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?\Z")


def _need(obj: Any, key: str, what: str) -> Any:
    if not isinstance(obj, dict) or key not in obj:
        raise DecodeError(f"{what}.{key} is missing")
    return obj[key]


def _need_str(obj: Any, key: str, what: str) -> str:
    value = _need(obj, key, what)
    if not isinstance(value, str):
        raise DecodeError(f"{what}.{key} is not a string")
    return value


def _opt_str(obj: Any, key: str, what: str) -> str | None:
    if not isinstance(obj, dict) or obj.get(key) is None:
        return None
    value = obj[key]
    if not isinstance(value, str):
        raise DecodeError(f"{what}.{key} is not a string")
    return value


def _need_bool(obj: Any, key: str, what: str) -> bool:
    value = _need(obj, key, what)
    if not isinstance(value, bool):
        raise DecodeError(f"{what}.{key} is not a bool")
    return value


def _need_int(obj: Any, key: str, what: str) -> int:
    value = _need(obj, key, what)
    if not isinstance(value, int) or isinstance(value, bool):
        raise DecodeError(f"{what}.{key} is not an int")
    return value


def _need_uint64(obj: Any, key: str, what: str) -> int:
    value = _need_int(obj, key, what)
    if value < 0 or value >= 2**64:
        raise DecodeError(f"{what}.{key} is out of uint64 range")
    return value


def _need_number(obj: Any, key: str, what: str) -> float:
    value = _need(obj, key, what)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DecodeError(f"{what}.{key} is not a number")
    return float(value)


def _need_list(obj: Any, key: str, what: str) -> list:
    value = _need(obj, key, what)
    if not isinstance(value, list):
        raise DecodeError(f"{what}.{key} is not a list")
    return value


def _opt_list(obj: Any, key: str, what: str) -> list:
    if not isinstance(obj, dict) or obj.get(key) is None:
        return []
    value = obj[key]
    if not isinstance(value, list):
        raise DecodeError(f"{what}.{key} is not a list")
    return value


_E = TypeVar("_E", bound=enum.Enum)


def _enum_from(value: Any, enum_cls: type[_E], what: str) -> _E:
    try:
        return enum_cls(value)
    except ValueError as exc:
        raise DecodeError(f"{what} has unknown value {value!r}") from exc


# ---------------------------------------------------------------------------
# Identifiers and closed enums.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PackID:
    """Validated pack id (``PackID.isValid`` grammar)."""

    raw: str

    def __post_init__(self) -> None:
        if not isinstance(self.raw, str) or _PACK_RE.match(self.raw) is None:
            raise ValueError(f"invalid PackID: {self.raw!r}")

    def __str__(self) -> str:
        return self.raw

    @classmethod
    def from_wire(cls, value: Any) -> PackID:
        if not isinstance(value, str):
            raise DecodeError("PackID is not a string")
        try:
            return cls(value)
        except ValueError as exc:
            raise DecodeError(f"invalid PackID: {value!r}") from exc


@dataclass(frozen=True)
class RuleID:
    """``pack:pattern`` rule id, split on the FIRST colon."""

    pack: PackID
    pattern: str

    @property
    def raw(self) -> str:
        return f"{self.pack.raw}:{self.pattern}"

    def __str__(self) -> str:
        return self.raw

    @classmethod
    def parse(cls, raw: str) -> RuleID:
        head, sep, pattern = raw.partition(":")
        if not sep or not head or not pattern:
            raise ValueError(f"invalid RuleID: {raw!r}")
        return cls(PackID(head), pattern)

    @classmethod
    def from_wire(cls, value: Any) -> RuleID:
        if not isinstance(value, str):
            raise DecodeError("RuleID is not a string")
        try:
            return cls.parse(value)
        except ValueError as exc:
            raise DecodeError(f"invalid RuleID: {value!r}") from exc


class HookHost(str, enum.Enum):
    GROK = "grok"
    PI = "pi"
    OPENCODE = "opencode"
    CLAUDE = "claude"
    OPENCLAW = "openclaw"
    HERMES = "hermes"
    CODEX = "codex"
    CURSOR = "cursor"
    ANTIGRAVITY = "antigravity"


class Severity(str, enum.Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class IndeterminateReason(str, enum.Enum):
    BUDGET_EXHAUSTED = "budgetExhausted"
    COMMAND_TOO_LARGE = "commandTooLarge"
    CORE_PACKS_UNAVAILABLE = "corePacksUnavailable"


class DecisionKind(str, enum.Enum):
    ALLOW = "allow"
    DENY = "deny"
    INDETERMINATE = "indeterminate"


class OutcomeKind(str, enum.Enum):
    QUICK_REJECTED = "quickRejected"
    PLAIN = "plain"
    SAFE_ONLY = "safeOnly"
    HIT = "hit"
    DENY = "deny"
    INDETERMINATE = "indeterminate"


class ServiceState(str, enum.Enum):
    RUNNING = "running"
    IDLE_EXIT_ARMED = "idleExitArmed"
    DOWN = "down"
    SKEW = "skew"


class DoctorCheckStatus(str, enum.Enum):
    OK = "ok"
    WARNING = "warning"
    ERROR = "error"
    SKIPPED = "skipped"


KNOWN_DOCTOR_CHECKS = frozenset(
    {"xpc", "protocol", "packs", "launchd", "lastError", "grok", "pi", "opencode"}
)


class ExplainStageName(str, enum.Enum):
    NORMALIZE = "normalize"
    QUICK_REJECT = "quick-reject"
    SAFE = "safe"
    DESTRUCTIVE = "destructive"
    DEFAULT = "default"


class RulePolarity(str, enum.Enum):
    ALLOW = "allow"
    BLOCK = "block"


# ---------------------------------------------------------------------------
# Decision and evaluation.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DenyInfo:
    rule_id: RuleID
    reason: str


@dataclass(frozen=True)
class Decision:
    """Pack-door verdict. Never Ask: leftover ``ask`` decodes to deny."""

    kind: DecisionKind
    deny: DenyInfo | None = None
    reason: IndeterminateReason | None = None

    def __post_init__(self) -> None:
        if self.kind is DecisionKind.DENY and self.deny is None:
            raise ValueError("deny requires DenyInfo")
        if self.kind is DecisionKind.INDETERMINATE and self.reason is None:
            raise ValueError("indeterminate requires a reason")

    @property
    def is_allow(self) -> bool:
        return self.kind is DecisionKind.ALLOW

    @property
    def is_deny(self) -> bool:
        return self.kind is DecisionKind.DENY

    @property
    def is_indeterminate(self) -> bool:
        return self.kind is DecisionKind.INDETERMINATE

    def __str__(self) -> str:
        if self.kind is DecisionKind.DENY and self.deny is not None:
            return f"deny({self.deny.rule_id})"
        if self.kind is DecisionKind.INDETERMINATE and self.reason is not None:
            return f"indeterminate({self.reason.value})"
        return "allow"

    @classmethod
    def from_wire(cls, value: Any) -> Decision:
        if not isinstance(value, dict):
            raise DecodeError("Decision is not an object")
        kind = _need_str(value, "decision", "Decision")
        if kind == "allow":
            return cls(DecisionKind.ALLOW)
        if kind == "deny":
            return cls(
                DecisionKind.DENY,
                deny=DenyInfo(
                    rule_id=RuleID.from_wire(value.get("ruleID")),
                    reason=_need_str(value, "reason", "Decision.deny"),
                ),
            )
        if kind == "indeterminate":
            reason = _enum_from(
                value.get("indeterminateReason"), IndeterminateReason, "Decision.reason"
            )
            return cls(DecisionKind.INDETERMINATE, reason=reason)
        if kind == "ask":
            # Leftover unused ask is not a permit (Coding.swift).
            return cls(
                DecisionKind.DENY,
                deny=DenyInfo(
                    rule_id=RuleID(PackID("builtin.action"), "leftover-ask"),
                    reason="Ask is not a permit.",
                ),
            )
        raise DecodeError(f"unknown Decision kind: {kind!r}")


@dataclass(frozen=True)
class RuleMatch:
    rule_id: RuleID
    severity: Severity
    reason: str
    explanation: str | None = None
    regex: str | None = None
    span: tuple[int, int] | None = None
    matched_text: str | None = None
    search_text: str | None = None

    @property
    def pack_id(self) -> PackID:
        return self.rule_id.pack

    @property
    def pattern_name(self) -> str:
        return self.rule_id.pattern

    @classmethod
    def from_wire(cls, value: Any) -> RuleMatch:
        if not isinstance(value, dict):
            raise DecodeError("RuleMatch is not an object")
        rule_id = RuleID.from_wire(value.get("ruleID"))
        echo_pack = value.get("packID")
        if echo_pack is not None and (
            not isinstance(echo_pack, str) or echo_pack != rule_id.pack.raw
        ):
            raise DecodeError("RuleMatch packID must equal ruleID.pack")
        echo_pattern = value.get("patternName")
        if echo_pattern is not None and echo_pattern != rule_id.pattern:
            raise DecodeError("RuleMatch patternName must equal ruleID.pattern")
        severity = _enum_from(value.get("severity"), Severity, "RuleMatch.severity")
        span_raw = value.get("span")
        span: tuple[int, int] | None = None
        if span_raw is not None:
            if not isinstance(span_raw, dict):
                raise DecodeError("RuleMatch.span is not an object")
            start = span_raw.get("start")
            end = span_raw.get("end")
            if (
                not isinstance(start, int)
                or isinstance(start, bool)
                or not isinstance(end, int)
                or isinstance(end, bool)
            ):
                raise DecodeError("RuleMatch.span bounds are not ints")
            span = (start, end)
        return cls(
            rule_id=rule_id,
            severity=severity,
            reason=_need_str(value, "reason", "RuleMatch"),
            explanation=_opt_str(value, "explanation", "RuleMatch"),
            regex=_opt_str(value, "regex", "RuleMatch"),
            span=span,
            matched_text=_opt_str(value, "matchedText", "RuleMatch"),
            search_text=_opt_str(value, "searchText", "RuleMatch"),
        )


@dataclass(frozen=True)
class SafeMatch:
    pack_id: PackID
    pattern_name: str

    @property
    def rule_id(self) -> RuleID:
        return RuleID(self.pack_id, self.pattern_name)

    @classmethod
    def from_wire(cls, value: Any) -> SafeMatch:
        if not isinstance(value, dict):
            raise DecodeError("SafeMatch is not an object")
        pattern = _need_str(value, "patternName", "SafeMatch")
        return cls(pack_id=PackID.from_wire(value.get("packID")), pattern_name=pattern)


@dataclass(frozen=True)
class Analysis:
    """Semantic analysis: case kind + opaquely preserved raw value.

    ``kind`` is the wire case key (``git``, ``filesystem``, ``wrapper``,
    ``unwrapLimited``, ``unknown``, or a future additive case). ``wrappers``
    lists outer-to-inner wrapper layers and ``innermost_kind`` names the leaf;
    both derive best-effort from verified shapes and degrade to empty/``kind``
    on anything unrecognized. Never depend on ``raw`` inner shapes.
    """

    kind: str
    raw: Any = None
    wrappers: tuple[str, ...] = ()
    innermost_kind: str = "unknown"

    @classmethod
    def unknown(cls) -> Analysis:
        return cls(kind="unknown", raw=None, wrappers=(), innermost_kind="unknown")

    @classmethod
    def from_wire(cls, value: Any) -> Analysis:
        if not isinstance(value, dict) or len(value) != 1:
            raise DecodeError("analysis is not a single-case object")
        (kind,) = value.keys()
        if not isinstance(kind, str):
            raise DecodeError("analysis case key is not a string")
        if kind in ("unknown", "unwrapLimited"):
            return cls(kind=kind, raw=value[kind], wrappers=(), innermost_kind=kind)
        if kind in ("git", "filesystem"):
            return cls(kind=kind, raw=value[kind], wrappers=(), innermost_kind=kind)
        if kind == "wrapper":
            wrappers: list[str] = []
            node: Any = value
            while isinstance(node, dict) and len(node) == 1 and "wrapper" in node:
                inner = node["wrapper"]
                if not isinstance(inner, dict):
                    break
                layer = inner.get("_0")
                if not isinstance(layer, str):
                    break
                wrappers.append(layer)
                node = inner.get("inner", {})
            leaf = node if isinstance(node, dict) and len(node) == 1 else {}
            (leaf_kind,) = leaf.keys() if len(leaf) == 1 else ("unknown",)
            if not isinstance(leaf_kind, str):
                leaf_kind = "unknown"
            nested = cls.from_wire(node) if leaf_kind != "unknown" else None
            innermost = nested.innermost_kind if nested else "unknown"
            all_wrappers = tuple(wrappers) + (nested.wrappers if nested else ())
            return cls(
                kind="wrapper",
                raw=value["wrapper"],
                wrappers=all_wrappers,
                innermost_kind=innermost,
            )
        return cls(kind=kind, raw=value[kind], wrappers=(), innermost_kind=kind)


@dataclass(frozen=True)
class Evaluation:
    """Curated evaluate result: verdict, outcome algebra, matches, view."""

    decision: Decision
    outcome: OutcomeKind
    matched: RuleMatch | None = None
    matched_safe: SafeMatch | None = None
    quick_rejected: bool = False
    matching_view: str = ""
    analysis: Analysis = field(default_factory=Analysis.unknown)

    @classmethod
    def from_wire(cls, value: Any) -> Evaluation:
        """Decode with the ``composing`` algebra; impossible combos fail closed."""
        if not isinstance(value, dict):
            raise DecodeError("EvaluationResult is not an object")
        decision = Decision.from_wire(value.get("decision"))
        matched_raw = value.get("matched")
        safe_raw = value.get("matchedSafe")
        matched = RuleMatch.from_wire(matched_raw) if matched_raw is not None else None
        matched_safe = SafeMatch.from_wire(safe_raw) if safe_raw is not None else None
        quick_raw = value.get("quickRejected", False)
        if not isinstance(quick_raw, bool):
            raise DecodeError("EvaluationResult.quickRejected is not a bool")
        view_raw = value.get("matchingView", "")
        if not isinstance(view_raw, str):
            raise DecodeError("EvaluationResult.matchingView is not a string")
        analysis_raw = value.get("analysis")
        analysis = (
            Analysis.from_wire(analysis_raw) if analysis_raw is not None else (Analysis.unknown())
        )
        if decision.kind is DecisionKind.ALLOW:
            if quick_raw:
                if matched is None and matched_safe is None:
                    outcome = OutcomeKind.QUICK_REJECTED
                else:
                    raise DecodeError("impossible EvaluationResult: quickRejected with matches")
            elif matched is not None:
                outcome = OutcomeKind.HIT
            elif matched_safe is not None:
                outcome = OutcomeKind.SAFE_ONLY
            else:
                outcome = OutcomeKind.PLAIN
        elif decision.kind is DecisionKind.DENY:
            if not quick_raw and matched_safe is None:
                outcome = OutcomeKind.DENY
            else:
                raise DecodeError("impossible EvaluationResult: deny with safe/quickRejected")
        else:
            if matched is None and matched_safe is None and not quick_raw:
                outcome = OutcomeKind.INDETERMINATE
            else:
                raise DecodeError("impossible EvaluationResult: indeterminate with matches")
        return cls(
            decision=decision,
            outcome=outcome,
            matched=matched,
            matched_safe=matched_safe,
            quick_rejected=quick_raw,
            matching_view=view_raw,
            analysis=analysis,
        )


# ---------------------------------------------------------------------------
# Explain / classify.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ExplainStage:
    name: ExplainStageName
    elapsed_ms: float

    @classmethod
    def from_wire(cls, value: Any) -> ExplainStage:
        if not isinstance(value, dict):
            raise DecodeError("ExplainStage is not an object")
        name = _enum_from(value.get("name"), ExplainStageName, "ExplainStage.name")
        return cls(name=name, elapsed_ms=_need_number(value, "elapsedMs", "ExplainStage"))


@dataclass(frozen=True)
class Explanation:
    evaluation: Evaluation
    normalized: str
    stages: tuple[ExplainStage, ...]
    suggestion: str | None = None

    @property
    def decision(self) -> Decision:
        return self.evaluation.decision

    @property
    def rule_id(self) -> RuleID | None:
        return _explain_rule_id(self.evaluation)

    @property
    def pack_id(self) -> PackID | None:
        rule_id = self.rule_id
        if rule_id is not None:
            return rule_id.pack
        if self.evaluation.outcome is OutcomeKind.SAFE_ONLY and self.evaluation.matched_safe:
            return self.evaluation.matched_safe.pack_id
        return None

    @classmethod
    def from_wire(cls, value: Any) -> Explanation:
        if not isinstance(value, dict):
            raise DecodeError("ExplainReply is not an object")
        stages = tuple(
            ExplainStage.from_wire(item) for item in _need_list(value, "stages", "ExplainReply")
        )
        return cls(
            evaluation=Evaluation.from_wire(value.get("result")),
            normalized=_need_str(value, "normalized", "ExplainReply"),
            stages=stages,
            suggestion=_opt_str(value, "suggestion", "ExplainReply"),
        )


def _explain_rule_id(evaluation: Evaluation) -> RuleID | None:
    if evaluation.outcome is OutcomeKind.HIT and evaluation.matched is not None:
        return evaluation.matched.rule_id
    if evaluation.decision.kind is DecisionKind.DENY and evaluation.decision.deny is not None:
        return evaluation.decision.deny.rule_id
    return None


@dataclass(frozen=True)
class Risk:
    safe: bool
    severity: Severity | None = None

    @classmethod
    def from_wire(cls, value: Any) -> Risk:
        if value == "safe":
            return cls(safe=True)
        severity = _enum_from(value, Severity, "ClassifyRisk")
        return cls(safe=False, severity=severity)


@dataclass(frozen=True)
class ClassifyReason:
    rule_id: RuleID
    explanation: str

    @classmethod
    def from_wire(cls, value: Any) -> ClassifyReason:
        if not isinstance(value, dict):
            raise DecodeError("ClassifyReason is not an object")
        return cls(
            rule_id=RuleID.from_wire(value.get("ruleID")),
            explanation=_need_str(value, "explanation", "ClassifyReason"),
        )


@dataclass(frozen=True)
class Classification:
    decision: Decision
    risk: Risk
    reasons: tuple[ClassifyReason, ...] = ()
    suggestions: tuple[str, ...] = ()
    rule_id: RuleID | None = None
    pack_id: PackID | None = None

    @classmethod
    def from_wire(cls, value: Any) -> Classification:
        if not isinstance(value, dict):
            raise DecodeError("ClassifyReply is not an object")
        decision = Decision.from_wire(value.get("decision"))
        risk = Risk.from_wire(value.get("risk"))
        reasons = tuple(
            ClassifyReason.from_wire(item) for item in _opt_list(value, "reasons", "ClassifyReply")
        )
        suggestions_raw = _opt_list(value, "suggestions", "ClassifyReply")
        if any(not isinstance(item, str) for item in suggestions_raw):
            raise DecodeError("ClassifyReply.suggestions entries are not strings")
        suggestions = tuple(suggestions_raw)
        sibling_rule = value.get("ruleID")
        sibling_pack = value.get("packID")
        if decision.kind is DecisionKind.ALLOW:
            if sibling_rule is not None:
                rule_id: RuleID | None = RuleID.from_wire(sibling_rule)
                if sibling_pack is not None:
                    pack = PackID.from_wire(sibling_pack)
                    if pack != rule_id.pack:
                        raise DecodeError("ClassifyReply packID must equal ruleID.pack")
                pack_id: PackID | None = rule_id.pack
            else:
                rule_id = None
                pack_id = PackID.from_wire(sibling_pack) if sibling_pack is not None else None
        elif decision.kind is DecisionKind.DENY and decision.deny is not None:
            rule_id = decision.deny.rule_id
            pack_id = decision.deny.rule_id.pack
        else:
            rule_id = None
            pack_id = None
        return cls(
            decision=decision,
            risk=risk,
            reasons=reasons,
            suggestions=suggestions,
            rule_id=rule_id,
            pack_id=pack_id,
        )


# ---------------------------------------------------------------------------
# Packs / doctor.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Pack:
    id: PackID
    enabled: bool
    bundled: bool

    @classmethod
    def from_wire(cls, value: Any) -> Pack:
        if not isinstance(value, dict):
            raise DecodeError("PackRecord is not an object")
        return cls(
            id=PackID.from_wire(value.get("id")),
            enabled=_need_bool(value, "enabled", "PackRecord"),
            bundled=_need_bool(value, "bundled", "PackRecord"),
        )


@dataclass(frozen=True)
class PackList:
    packs: tuple[Pack, ...]
    enabled_count: int
    total_count: int

    @classmethod
    def from_wire(cls, value: Any) -> PackList:
        if not isinstance(value, dict):
            raise DecodeError("ListPacksReply is not an object")
        packs = tuple(Pack.from_wire(item) for item in _need_list(value, "packs", "ListPacksReply"))
        return cls(
            packs=packs,
            enabled_count=_need_int(value, "enabledCount", "ListPacksReply"),
            total_count=_need_int(value, "totalCount", "ListPacksReply"),
        )


@dataclass(frozen=True)
class DoctorCheck:
    """One doctor check. ``id`` preserves the raw string: unknown check ids
    are additive and must not break older SDKs (``sdk/WIRE.md`` §4.3)."""

    id: str
    status: DoctorCheckStatus
    message: str

    @classmethod
    def from_wire(cls, value: Any) -> DoctorCheck:
        if not isinstance(value, dict):
            raise DecodeError("DoctorCheck is not an object")
        status = _enum_from(value.get("status"), DoctorCheckStatus, "DoctorCheck.status")
        return cls(
            id=_need_str(value, "id", "DoctorCheck"),
            status=status,
            message=_need_str(value, "message", "DoctorCheck"),
        )


@dataclass(frozen=True)
class DoctorSnapshot:
    protocol: str
    service_semver: str
    label: str
    state: ServiceState
    keep_alive: bool
    idle_exit_seconds: int
    packs_enabled: tuple[PackID, ...]
    checks: tuple[DoctorCheck, ...]
    last_error: str | None = None

    @classmethod
    def from_wire(cls, value: Any) -> DoctorSnapshot:
        if not isinstance(value, dict):
            raise DecodeError("DoctorSnapshotReply is not an object")
        state = _enum_from(value.get("state"), ServiceState, "DoctorSnapshot.state")
        packs = tuple(
            PackID.from_wire(item)
            for item in _need_list(value, "packsEnabled", "DoctorSnapshotReply")
        )
        checks = tuple(
            DoctorCheck.from_wire(item)
            for item in _need_list(value, "checks", "DoctorSnapshotReply")
        )
        return cls(
            protocol=_need_str(value, "protocol", "DoctorSnapshotReply"),
            service_semver=_need_str(value, "serviceSemver", "DoctorSnapshotReply"),
            label=_need_str(value, "label", "DoctorSnapshotReply"),
            state=state,
            keep_alive=_need_bool(value, "keepAlive", "DoctorSnapshotReply"),
            idle_exit_seconds=_need_int(value, "idleExitSeconds", "DoctorSnapshotReply"),
            packs_enabled=packs,
            checks=checks,
            last_error=_opt_str(value, "lastError", "DoctorSnapshotReply"),
        )


# ---------------------------------------------------------------------------
# Pending approvals and rules.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ApprovalIdentity:
    session: str
    agent: HookHost

    def __post_init__(self) -> None:
        if not self.session:
            raise ValueError("session must be nonempty")

    @classmethod
    def from_wire(cls, value: Any) -> ApprovalIdentity:
        if not isinstance(value, dict):
            raise DecodeError("ApprovalIdentity is not an object")
        session = _need_str(value, "session", "ApprovalIdentity")
        if not session:
            raise DecodeError("ApprovalIdentity.session must be nonempty")
        agent = _enum_from(value.get("agent"), HookHost, "ApprovalIdentity.agent")
        return cls(session=session, agent=agent)

    def to_wire(self) -> dict[str, Any]:
        return {"session": self.session, "agent": self.agent.value}


@dataclass(frozen=True)
class PendingItem:
    """One approval awaiting a human. ``id``, ``fingerprint``, and ``identity``
    echo back verbatim on resolve; the service re-verifies all three."""

    id: str
    host: HookHost
    folder: str
    action_kind: str
    fingerprint: str
    identity: ApprovalIdentity
    session_suffix: str | None = None

    @classmethod
    def from_wire(cls, value: Any) -> PendingItem:
        if not isinstance(value, dict):
            raise DecodeError("PendingListItem is not an object")
        host = _enum_from(value.get("host"), HookHost, "PendingListItem.host")
        return cls(
            id=_need_str(value, "id", "PendingListItem"),
            host=host,
            folder=_need_str(value, "folder", "PendingListItem"),
            action_kind=_need_str(value, "actionKind", "PendingListItem"),
            fingerprint=_need_str(value, "fingerprint", "PendingListItem"),
            identity=ApprovalIdentity.from_wire(value.get("identity")),
            session_suffix=_opt_str(value, "sessionSuffix", "PendingListItem"),
        )


@dataclass(frozen=True)
class PendingBatch:
    generation: int
    items: tuple[PendingItem, ...] = ()

    @classmethod
    def from_wire(cls, value: Any) -> PendingBatch:
        if not isinstance(value, dict):
            raise DecodeError("PendingListReply is not an object")
        items = tuple(
            PendingItem.from_wire(item) for item in _need_list(value, "items", "PendingListReply")
        )
        return cls(generation=_need_uint64(value, "generation", "PendingListReply"), items=items)


@dataclass(frozen=True)
class ResolveResult:
    id: str
    terminal: bool

    @classmethod
    def from_wire(cls, value: Any) -> ResolveResult:
        if not isinstance(value, dict):
            raise DecodeError("PendingResolveReply is not an object")
        return cls(
            id=_need_str(value, "id", "PendingResolveReply"),
            terminal=_need_bool(value, "terminal", "PendingResolveReply"),
        )


@dataclass(frozen=True)
class RuleDraft:
    sentence: str
    draft: str
    allowed_to_save: bool

    @classmethod
    def from_wire(cls, value: Any) -> RuleDraft:
        if not isinstance(value, dict):
            raise DecodeError("RulePreviewReply is not an object")
        return cls(
            sentence=_need_str(value, "sentence", "RulePreviewReply"),
            draft=_need_str(value, "draft", "RulePreviewReply"),
            allowed_to_save=_need_bool(value, "allowedToSave", "RulePreviewReply"),
        )


@dataclass(frozen=True)
class RuleSaveResult:
    rule_id: RuleID
    wait_resolved: bool

    @classmethod
    def from_wire(cls, value: Any) -> RuleSaveResult:
        if not isinstance(value, dict):
            raise DecodeError("RuleSaveReply is not an object")
        return cls(
            rule_id=RuleID.from_wire(value.get("ruleID")),
            wait_resolved=_need_bool(value, "waitResolved", "RuleSaveReply"),
        )


# ---------------------------------------------------------------------------
# Request param builders (validated eagerly; ValueError on programmer error).
# ---------------------------------------------------------------------------


def coerce_packs(packs: Iterable[str | PackID] | None) -> list[str]:
    """Day-one defaults for ``None``; validated id strings otherwise."""
    if packs is None:
        return list(DAY_ONE_PACKS)
    if isinstance(packs, (str, bytes)):
        raise ValueError("packs must be a list of pack ids, not a single string")
    try:
        items = list(packs)
    except TypeError as exc:
        raise ValueError("packs must be a list of pack ids") from exc
    out: list[str] = []
    for item in items:
        if isinstance(item, PackID):
            out.append(item.raw)
        elif isinstance(item, str):
            out.append(PackID(item).raw)
        else:
            raise ValueError(f"invalid pack id: {item!r}")
    return out


def coerce_cwd(cwd: str | os.PathLike[str] | None) -> str | None:
    """``None`` stays absent; empty string is a programmer error (fail fast
    locally instead of silently changing allow-once honor keys)."""
    if cwd is None:
        return None
    text = cwd if isinstance(cwd, str) else os.fspath(cwd)
    if not isinstance(text, str) or not text:
        raise ValueError("cwd must be a nonempty path or None")
    return text


def evaluation_request_wire(
    command: str,
    packs: Iterable[str | PackID] | None = None,
    budget: int | None = None,
) -> dict[str, Any]:
    if not isinstance(command, str):
        raise ValueError("command must be a string")
    request: dict[str, Any] = {"command": command, "enabledPacks": coerce_packs(packs)}
    if budget is not None:
        if not isinstance(budget, int) or isinstance(budget, bool):
            raise ValueError("budget must be an int of max pattern attempts")
        request["budget"] = {"maxPatternAttempts": budget}
    return request


def evaluate_params_wire(
    command: str,
    cwd: str | os.PathLike[str] | None = None,
    packs: Iterable[str | PackID] | None = None,
    budget: int | None = None,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "request": evaluation_request_wire(command, packs, budget),
        "clientSemver": SDK_IPC_SEMVER,
    }
    resolved = coerce_cwd(cwd)
    if resolved is not None:
        params["cwd"] = resolved
    return params


def explain_params_wire(
    command: str,
    cwd: str | os.PathLike[str] | None = None,
    packs: Iterable[str | PackID] | None = None,
    budget: int | None = None,
) -> dict[str, Any]:
    params: dict[str, Any] = {"request": evaluation_request_wire(command, packs, budget)}
    resolved = coerce_cwd(cwd)
    if resolved is not None:
        params["cwd"] = resolved
    return params


# Identical params by wire design (ClassifyParams == ExplainParams shape).
classify_params_wire = explain_params_wire


def set_pack_enabled_wire(pack_id: str | PackID, enabled: bool) -> dict[str, Any]:
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be a bool")
    raw = pack_id.raw if isinstance(pack_id, PackID) else PackID(pack_id).raw
    return {"id": raw, "enabled": enabled}


def pending_watch_wire(after_generation: int) -> dict[str, Any]:
    if not isinstance(after_generation, int) or isinstance(after_generation, bool):
        raise ValueError("after_generation must be a uint64 int")
    if after_generation < 0 or after_generation >= 2**64:
        raise ValueError("after_generation is out of uint64 range")
    return {"afterGeneration": after_generation}


def pending_resolve_wire(item: PendingItem, allow: bool) -> dict[str, Any]:
    if not isinstance(item, PendingItem):
        raise ValueError("resolve requires a PendingItem from pending_list/watch_approvals")
    if not isinstance(allow, bool):
        raise ValueError("allow must be a bool")
    return {
        "id": item.id,
        "decision": "allowOnce" if allow else "deny",
        "fingerprint": item.fingerprint,
        "identity": item.identity.to_wire(),
    }


def rule_preview_wire(approval_id: str, polarity: RulePolarity) -> dict[str, Any]:
    if not isinstance(approval_id, str) or not approval_id:
        raise ValueError("approval_id must be a nonempty string")
    if not isinstance(polarity, RulePolarity):
        raise ValueError("polarity must be a RulePolarity")
    return {"id": approval_id, "polarity": polarity.value}


def rule_save_wire(approval_id: str, polarity: RulePolarity, draft: str) -> dict[str, Any]:
    params = rule_preview_wire(approval_id, polarity)
    if not isinstance(draft, str) or not draft:
        raise ValueError("draft must echo the preview draft")
    params["draft"] = draft
    return params
