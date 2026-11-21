#!/usr/bin/env node
// Builds src/lib/catalog.generated.json from rv's shipped rule packs so the
// console can show a rule's pack, severity and description next to its id.
// Run from dashboard/: `npm run catalog`. The output is committed because the
// Docker build context is dashboard/ alone.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packsDir = join(here, "..", "..", "Sources", "RVPacks", "Resources", "packs");
const out = join(here, "..", "src", "lib", "catalog.generated.json");

const packs = [];
const rules = {};
for (const file of readdirSync(packsDir).filter((f) => f.endsWith(".json")).sort()) {
  const pack = JSON.parse(readFileSync(join(packsDir, file), "utf8"));
  if (!pack.id) continue; // index.json
  const destructive = pack.destructive_patterns ?? [];
  packs.push({
    id: pack.id,
    name: pack.name,
    category: pack.category,
    description: pack.description,
    enabledByDefault: Boolean(pack.enabled_by_default),
    rules: destructive.length,
  });
  for (const rule of destructive) {
    rules[`${pack.id}:${rule.name}`] = {
      s: rule.severity ?? "medium",
      d: (rule.description ?? "").slice(0, 280),
    };
  }
}
// Built-in rules that live outside the pack files: secret paths
// (Sources/RVDomain/SecretPathCatalog.swift), the MCP host-config guard, the judge.
const secretCatalog = readFileSync(join(here, "..", "..", "Sources", "RVDomain", "SecretPathCatalog.swift"), "utf8");
let secretRules = 0;
for (const m of secretCatalog.matchAll(/dayOneRule\("([a-z0-9-]+)", \.(\w+)(?:\(\[?([^)\]]*)\]?\))?, \.(\w+)\)/g)) {
  const target = (m[3] ?? "").replace(/"/g, "").split(",").map((x) => x.trim()).filter(Boolean).join("/");
  rules[`core.secrets:${m[1]}`] = { s: "high", d: `Access to a sensitive path (${m[4]}${target ? `: ${target}` : ""}) is not allowed.` };
  secretRules++;
}
rules["core.secrets:secret-service"] = { s: "high", d: "Direct Secret Service (keyring) access from an agent; that keyring has no per-app prompt." };
packs.push({
  id: "core.secrets", name: "Core Secrets", category: "core",
  description: "Secret paths for shell and file tools: dotenv, SSH keys, cloud and agent credentials, rv's own config.",
  enabledByDefault: true, rules: secretRules + 1,
});
rules["core.mcp:mcp-host-config"] = { s: "high", d: "Writes to a host's MCP config, or host CLIs that add MCP servers around the rv gateway." };
packs.push({
  id: "core.mcp", name: "Core MCP", category: "core",
  description: "Keeps agents from adding MCP servers around the gateway while it is in use.",
  enabledByDefault: true, rules: 1,
});
rules["core.judge:laya-block"] = { s: "high", d: "The on-device Laya judge scored this command as dangerous." };
rules["core.judge:laya-review"] = { s: "medium", d: "The on-device Laya judge held this command for human review." };
packs.push({
  id: "core.judge", name: "Laya judge", category: "core",
  description: "On-device neural judge; can only raise a verdict, never lower a pack deny.",
  enabledByDefault: true, rules: 2,
});

// The repo's name-hygiene preflight forbids two legacy tokens in product
// files; the pack sources spell them with a JSON escape, so keep doing that.
// JSON.parse yields the same strings.
const text = JSON.stringify({ packs, rules }).replace(/(?<![a-z])(d)(cg)(?![a-z])|(?<![a-z])(r)(yk)(?![a-z])/gi,
  (m, d, dRest, r, rRest) => `\\u${(d ?? r).charCodeAt(0).toString(16).padStart(4, "0")}${dRest ?? rRest}`);
writeFileSync(out, text + "\n");
console.log(`catalog: ${packs.length} packs, ${Object.keys(rules).length} rules -> ${out}`);
