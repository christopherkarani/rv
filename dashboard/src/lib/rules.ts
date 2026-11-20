import "server-only"
import rules from "./rules.generated.json"

// Rule descriptions from rv's shipped packs (scripts/sync-packs.mjs). Server only:
// about 150 KB that client bundles do not need.

export type RuleInfo = { severity: string; description: string }
const RULES = rules as Record<string, RuleInfo>

export function ruleInfo(id: string): RuleInfo | null {
  return RULES[id] ?? null
}
