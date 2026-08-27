import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
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
    throw new TypeError(`Plugin ${spec} must default export an object with ${kind}()`);
  }
  if (kind === "tui" && tui === undefined) {
    throw new TypeError(`Plugin ${spec} must default export an object with ${kind}()`);
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

function installFakeSolid(root) {
  const dir = join(root, "node_modules", "solid-js");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "package.json"),
    JSON.stringify({ name: "solid-js", type: "module", exports: { ".": "./index.js" } }),
  );
  // Live TUI hole: plugin createComponent from a second Solid drops function props.
  // Invented onConfirm / onCancel never fire. Official keys must still reply.
  writeFileSync(
    join(dir, "index.js"),
    `export function createComponent(component, props) {
  globalThis.__rvCreateComponentCount = (globalThis.__rvCreateComponentCount ?? 0) + 1;
  const safe = {};
  for (const key of Object.keys(props ?? {})) {
    if (typeof props[key] !== "function") safe[key] = props[key];
  }
  return typeof component === "function" ? component(safe) : component;
}
`,
  );
}

function officialKeymap() {
  const layers = [];
  return {
    registerLayer(layer) {
      layers.push(layer);
      return () => {
        const index = layers.indexOf(layer);
        if (index >= 0) {
          layers.splice(index, 1);
        }
      };
    },
    handle(key) {
      const ordered = [...layers].sort((left, right) => (right.priority ?? 0) - (left.priority ?? 0));
      for (const layer of ordered) {
        for (const binding of layer.bindings ?? []) {
          if (binding.key !== key) {
            continue;
          }
          if (typeof binding.cmd === "function") {
            binding.cmd();
          } else {
            const command = (layer.commands ?? []).find((entry) => entry.name === binding.cmd);
            if (command && typeof command.run === "function") {
              command.run();
            }
          }
          return true;
        }
      }
      return false;
    },
  };
}

function officialDialogConfirm(props, keymap) {
  // Official 1.18.18 DialogConfirm: one store paints focus and decides return.
  // left/right never update a plugin keymap `active`. That second store is leftover-ask.
  const store = { active: "confirm" };
  const toggle = () => {
    store.active = store.active === "confirm" ? "cancel" : "confirm";
  };
  const submit = () => {
    if (store.active === "confirm") {
      props && typeof props.onConfirm === "function" && props.onConfirm();
    }
    if (store.active === "cancel") {
      props && typeof props.onCancel === "function" && props.onCancel();
    }
  };
  const painted = {
    title: props && props.title,
    message: props && props.message,
    get focus() {
      return store.active;
    },
    key(name) {
      if (name === "left" || name === "right") {
        toggle();
        return;
      }
      if (name === "return") {
        const stolen = keymap && typeof keymap.handle === "function" && keymap.handle("return");
        if (!stolen) {
          submit();
        }
      }
    },
    click(which) {
      if (which === "confirm") {
        painted.key("return");
        return;
      }
      if (which === "cancel") {
        toggle();
        painted.key("return");
      }
    },
  };
  officialDialogConfirm.last = painted;
  return painted;
}

function officialDialogStack() {
  const stack = [];
  return {
    size: null,
    setSize(size) {
      this.size = size;
    },
    replace(input, onClose) {
      while (stack.length > 0) {
        const previous = stack.pop();
        if (typeof previous.onClose === "function") {
          previous.onClose();
        }
      }
      const element = typeof input === "function" ? input() : input;
      stack.push({ element, onClose });
      this.replaced = element;
      this.onClose = onClose;
    },
    clear() {
      while (stack.length > 0) {
        const previous = stack.pop();
        if (typeof previous.onClose === "function") {
          previous.onClose();
        }
      }
    },
  };
}

const pluginPath = process.argv[2];
const mode = process.argv[3] ?? "official-confirm";
if (!pluginPath) {
  process.stdout.write(JSON.stringify({ error: "missing plugin path" }));
  process.exit(2);
}

installFakeSolid(dirname(pluginPath));

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
let dialogSize = null;
let replied = null;
let replySessionID = null;
let replyRequestID = null;
let usedShow = false;
let usedCreateComponent = false;
let usedOfficialKeys = false;
let usedInventedCallback = false;
let dialogFocus = null;

function askedEvent() {
  return {
    type: "permission.v2.asked",
    properties: {
      id: "per_live",
      sessionID: "ses_1",
      metadata: { rv: true, reason: "Blocked git reset --hard (core.git/reset-hard)." },
    },
  };
}

async function waitForPaint() {
  for (let i = 0; i < 40; i++) {
    if (officialDialogConfirm.last) {
      return officialDialogConfirm.last;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return officialDialogConfirm.last;
}

async function runAsked(api, click) {
  const handlers = api.handlers;
  const asked = handlers.get("permission.v2.asked");
  if (typeof asked !== "function") {
    return;
  }
  officialDialogConfirm.last = undefined;
  const pending = asked(askedEvent());
  const painted = await waitForPaint();
  dialogSize = api.ui && api.ui.dialog ? api.ui.dialog.size : null;
  if (painted) {
    dialogTitle = painted.title;
    dialogMessage = painted.message;
    if (click === "confirm") {
      usedOfficialKeys = true;
      painted.key("return");
    } else if (click === "cancel") {
      usedOfficialKeys = true;
      painted.key("left");
      dialogFocus = painted.focus;
      painted.key("return");
    }
    dialogFocus = painted.focus;
  }
  if (click === "none") {
    await Promise.race([pending, new Promise((resolve) => setTimeout(resolve, 40))]);
    return;
  }
  if (click === "host-replace") {
    api.ui.dialog.replace(() => ({ host: true }), () => {});
    await Promise.race([pending, new Promise((resolve) => setTimeout(resolve, 40))]);
    return;
  }
  await pending;
}

if (serverLoaded && mod.default && typeof mod.default.server === "function") {
  const handlers = new Map();
  const dialog = officialDialogStack();
  const keymap = officialKeymap();
  const DialogConfirm = (props) => officialDialogConfirm(props, keymap);
  if (mode === "show-lie") {
    DialogConfirm.show = async (_dialog, title, message) => {
      usedShow = true;
      dialogTitle = title;
      dialogMessage = message;
      return true;
    };
  }
  const recordReply = (input) => {
    replied = input && input.reply;
    replySessionID = input && (input.sessionID || (input.path && input.path.sessionID));
    replyRequestID = input && (input.requestID || (input.path && input.path.requestID));
  };
  const api = {
    handlers,
    keymap,
    event: {
      on(type, handler) {
        handlers.set(type, (...args) => handler(...args));
        return () => handlers.delete(type);
      },
    },
    ui:
      mode === "no-ui"
        ? undefined
        : {
            dialog,
            DialogConfirm,
          },
    client: {
      permission: {
        async reply(input) {
          recordReply(input);
        },
      },
      session: {
        permission: {
          async reply(input) {
            recordReply(input);
          },
        },
      },
    },
  };
  await mod.default.server(api);
  if (mode === "no-ui") {
    const asked = handlers.get("permission.v2.asked");
    if (typeof asked === "function") {
      await asked(askedEvent());
    }
  } else if (mode === "official-cancel") {
    await runAsked(api, "cancel");
  } else if (mode === "official-none") {
    await runAsked(api, "none");
  } else if (mode === "host-replace") {
    await runAsked(api, "host-replace");
  } else if (mode === "show-lie") {
    await runAsked(api, "none");
  } else {
    await runAsked(api, "confirm");
  }
}

usedCreateComponent = (globalThis.__rvCreateComponentCount ?? 0) > 0;

process.stdout.write(
  JSON.stringify({
    serverLoaded,
    serverLoadError,
    hasServer: typeof (mod.default && mod.default.server) === "function",
    hasTui: typeof (mod.default && mod.default.tui) === "function",
    hooksIsObject: hooks != null && typeof hooks === "object",
    dialogTitle,
    dialogMessage,
    dialogSize,
    replied,
    replySessionID,
    replyRequestID,
    usedShow,
    usedCreateComponent,
    usedOfficialKeys,
    usedInventedCallback,
    dialogFocus,
  }),
);
process.exit(0);
