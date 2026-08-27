import { pathToFileURL } from "node:url";

// Official OpenCode 1.18.18 `readV1Plugin` + `applyPlugin` (packages/opencode/src/plugin/shared.ts
// and packages/opencode/src/plugin/index.ts). Copied so this test proves the live loader,
// not a guessed shape.

function isRecord(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function readV1Plugin(mod, spec, kind, mode = "strict") {
  const value = mod.default;
  if (!isRecord(value)) {
    if (mode === "detect") return;
    throw new TypeError(`Plugin ${spec} must default export an object with ${kind}()`);
  }
  if (mode === "detect" && !("id" in value) && !("server" in value) && !("tui" in value)) {
    return;
  }

  const server = "server" in value ? value.server : undefined;
  const tui = "tui" in value ? value.tui : undefined;
  if (server !== undefined && typeof server !== "function") {
    throw new TypeError(`Plugin ${spec} has invalid server export`);
  }
  if (tui !== undefined && typeof tui !== "function") {
    throw new TypeError(`Plugin ${spec} has invalid tui export`);
  }
  if (server !== undefined && tui !== undefined) {
    throw new TypeError(`Plugin ${spec} must default export either server() or tui(), not both`);
  }
  if (kind === "server" && server === undefined) {
    throw new TypeError(`Plugin ${spec} must default export an object with server()`);
  }
  if (kind === "tui" && tui === undefined) {
    throw new TypeError(`Plugin ${spec} must default export an object with tui()`);
  }

  return value;
}

function getServerPlugin(value) {
  if (typeof value === "function") return value;
  if (!value || typeof value !== "object" || !("server" in value)) return;
  if (typeof value.server !== "function") return;
  return value.server;
}

function getLegacyPlugins(mod) {
  const seen = new Set();
  const result = [];
  for (const entry of Object.values(mod)) {
    if (seen.has(entry)) continue;
    seen.add(entry);
    const plugin = getServerPlugin(entry);
    if (!plugin) throw new TypeError("Plugin export is not a function");
    result.push(plugin);
  }
  return result;
}

async function applyPlugin(mod, spec, input) {
  const plugin = readV1Plugin(mod, spec, "server", "detect");
  if (plugin) {
    return await plugin.server(input, undefined);
  }
  const hooks = [];
  for (const server of getLegacyPlugins(mod)) {
    hooks.push(await server(input, undefined));
  }
  return hooks[0];
}

const pluginPath = process.argv[2];
if (!pluginPath) {
  process.stdout.write(JSON.stringify({ error: "missing plugin path" }));
  process.exit(2);
}

const spec = "file://" + pluginPath;
const mod = await import(pathToFileURL(pluginPath).href);

let serverLoadError = null;
let serverLoaded = false;
let hooks = null;
try {
  hooks = await applyPlugin(mod, spec, {
    client: {},
    directory: "/tmp",
    serverUrl: new URL("http://127.0.0.1:4096/"),
  });
  serverLoaded = true;
} catch (error) {
  serverLoadError = error instanceof Error ? error.message : String(error);
}

let dialogTitle = null;
let dialogMessage = null;
let replied = null;
if (serverLoaded && mod.default && typeof mod.default.server === "function") {
  const handlers = new Map();
  const api = {
    event: {
      on(type, handler) {
        handlers.set(type, (...args) => handler(...args));
        return () => handlers.delete(type);
      },
    },
    ui: {
      dialog: {},
      DialogConfirm: {
        async show(_dialog, title, message) {
          dialogTitle = title;
          dialogMessage = message;
          return true;
        },
      },
    },
    client: {
      session: {
        permission: {
          async reply(input) {
            replied = input && input.reply;
          },
        },
      },
    },
  };
  await mod.default.server(api);
  const asked = handlers.get("permission.v2.asked");
  if (typeof asked === "function") {
    await asked({
      type: "permission.v2.asked",
      properties: {
        id: "per_live",
        sessionID: "ses_1",
        metadata: { rv: true, reason: "Blocked git reset --hard (core.git/reset-hard)." },
      },
    });
  }
}

process.stdout.write(
  JSON.stringify({
    serverLoaded,
    serverLoadError,
    hasServer: typeof (mod.default && mod.default.server) === "function",
    hasTui: typeof (mod.default && mod.default.tui) === "function",
    hooksIsObject: hooks != null && typeof hooks === "object",
    dialogTitle,
    dialogMessage,
    replied,
  }),
);
process.exit(0);
