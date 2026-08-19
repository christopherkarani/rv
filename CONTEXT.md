# rv

Mac-native destructive-command guard for coding-agent shell hooks. Day-one hosts: Pi, Grok, OpenCode.

## Language

**Evaluate session**:
The compiled day-one packs from which a Decision is produced. TTY test/explain and a hook miss share one; TTY never asks rvd.
_Avoid_: in-process fallback, composer, warm evaluate

**Enabled packs**:
The pack IDs on an evaluate request. Empty means none — not the catalog, not an implied day-one refill.
_Avoid_: refill, default packs

**Day-one packs**:
core.git and core.filesystem. v1 evaluate always uses these two; the catalog does not change a Decision.
_Avoid_: live catalog, enabled catalog
