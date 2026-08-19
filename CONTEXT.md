# rv

Mac-native destructive-command guard for coding-agent shell hooks. Day-one hosts: Pi, Grok, OpenCode.

## Language

**Evaluate session**:
The compiled day-one packs from which a Decision is produced. Hook fallback and TTY test/explain share one.
_Avoid_: in-process fallback, composer, warm evaluate

**Explain pipeline**:
The stages an EvaluationResult already took, in evaluation order: normalize, quick-reject, safe, destructive, default. TTY explain and XPC explain show the same stages. XPC `ExplainStage.name` is that kebab-case id (`quick-reject`, not camelCase `quickReject`); `elapsedMs` is currently always 0.
_Avoid_: explain projection, briefing, ExplainStage (the IPC timing row)

**Explain step**:
One stage in the Explain pipeline, including that stage's outcome (scanned or skipped, rule hit or none, allow or incomplete).
_Avoid_: ExplainStage
