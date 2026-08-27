import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { officialDialogConfirm, resetOfficialDialogConfirm } from "./opencode-11818-dialog-confirm.mjs";
import {
  officialPermissionPrompt,
  resetOfficialPermissionPrompt,
} from "./opencode-11818-permission-prompt.mjs";

const host = process.argv[2];
const adapterPath = process.argv[3];
const event = JSON.parse(process.argv[4] ?? "{}");

const mod = await import(pathToFileURL(adapterPath).href);

if (host === "pi") {
  const factory = mod.default;
  const registered = [];
  const messages = [];
  let rendererType = null;
  let renderer = null;
  const pi = {
    on(name, fn) {
      registered.push({ name, fn });
    },
    registerMessageRenderer(customType, fn) {
      rendererType = customType;
      renderer = fn;
    },
    sendMessage(message, options) {
      messages.push({ message, options });
      if (process.env.RV_SEND_MESSAGE_THROWS === "1") {
        throw new Error("sendMessage");
      }
    },
  };
  factory(pi);
  if (registered.length !== 1 || registered[0].name !== "tool_call") {
    process.stdout.write(
      JSON.stringify({
        error: "unexpected events",
        events: registered.map((row) => row.name),
      })
    );
    process.exit(2);
  }
  const ctx = {
    ui: {
      hasUI: process.env.RV_HAS_UI !== "0",
      async confirm() {
        if (process.env.RV_HAS_UI === "0") {
          return false;
        }
        return process.env.RV_CONFIRM_YES === "1";
      },
    },
  };
  const result = await registered[0].fn(event, ctx);
  let rendererProbe = "missing";
  let lines = null;
  let narrowLines = null;
  if (typeof renderer === "function" && messages.length > 0) {
    const theme = {
      fg(_name, text) {
        return text;
      },
      bold(text) {
        return text;
      },
    };
    const rendered = renderer(messages[0].message, {}, theme);
    if (typeof rendered === "string") {
      rendererProbe = "string";
    } else if (
      rendered != null &&
      typeof rendered === "object" &&
      typeof rendered.render === "function"
    ) {
      rendererProbe = "component";
      lines = rendered.render(80);
      narrowLines = rendered.render(24);
    }
  }
  process.stdout.write(
    JSON.stringify({
      result: result ?? null,
      rendererType,
      messages,
      rendererProbe,
      lines,
      narrowLines,
    })
  );
  process.exit(0);
}

if (host === "opencode") {
  const toasts = [];
  const confirmYes = process.env.RV_CONFIRM_YES === "1";
  const resolutionAllow = process.env.RV_RESOLUTION_ALLOW === "1";
  const hasUI = process.env.RV_HAS_UI !== "0";
  const ctx = {
    client: {
      tui: {
        async showToast(input) {
          if (process.env.RV_TOAST_THROWS === "1") {
            throw new Error("toast");
          }
          if (process.env.RV_TOAST_HANGS === "1") {
            return new Promise(() => {});
          }
          if (
            process.env.RV_TOAST_LEGACY_CLIENT === "1" &&
            !(input && typeof input === "object" && "body" in input)
          ) {
            return {
              error: { name: "BadRequest", data: { message: "Expected object, got undefined" } },
            };
          }
          toasts.push(input);
        },
        async publish(input) {
          if (process.env.RV_TOAST_THROWS === "1") {
            throw new Error("toast");
          }
          toasts.push(input);
        },
      },
    },
  };
  if (confirmYes) {
    ctx.ask = async () => true;
    ctx.ui = {
      hasUI,
      async confirm() {
        if (!hasUI) {
          return false;
        }
        return true;
      },
    };
  }
  if (process.env.RV_SESSION_MESSAGES) {
    const messages = JSON.parse(process.env.RV_SESSION_MESSAGES);
    ctx.client.session = {
      async messages() {
        return messages;
      },
    };
  }
  if (process.env.RV_PERMISSION_REPLY) {
    installOfficialPermission(ctx, process.env.RV_PERMISSION_REPLY);
  }
  if (process.env.RV_TUI_PLUGIN) {
    await loadTuiAskCompanion(ctx, process.env.RV_TUI_PLUGIN, process.env.RV_TUI_CLICK);
  }
  const plugin = await mod.RvGuard(ctx);
  const keys = Object.keys(plugin);
  ctx.pluginEvent = plugin.event;
  const unexpected = keys.filter(
    (name) => name !== "tool.execute.before" && name !== "shell.env" && name !== "event"
  );
  if (!keys.includes("tool.execute.before") || unexpected.length > 0) {
    process.stdout.write(JSON.stringify({ error: "unexpected hooks", keys }));
    process.exit(2);
  }
  const steps = Array.isArray(event.steps) ? event.steps : [event];
  try {
    for (const step of steps) {
      await runOpenCodeStep(plugin, step, { confirmYes, resolutionAllow, hasUI });
    }
    process.stdout.write(
      JSON.stringify({
        threw: null,
        toasts,
        permissionCreates: ctx.permissionCreates ?? 0,
        permissionGets: ctx.permissionGets ?? 0,
        permissionReply204: ctx.permissionReply204 ?? null,
        tuiDialogTitle: ctx.tuiDialogTitle ?? null,
        tuiPaintSource: ctx.tuiPaintSource ?? null,
      })
    );
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        threw: error instanceof Error ? error.message : String(error),
        toasts,
        permissionCreates: ctx.permissionCreates ?? 0,
        permissionGets: ctx.permissionGets ?? 0,
        permissionReply204: ctx.permissionReply204 ?? null,
        tuiDialogTitle: ctx.tuiDialogTitle ?? null,
        tuiPaintSource: ctx.tuiPaintSource ?? null,
      })
    );
  }
  process.exit(0);
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
      officialKeymap.handleCount = (officialKeymap.handleCount ?? 0) + 1;
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

function createOfficialTuiEventBus() {
  const handlers = [];
  return {
    on(type, handler) {
      const wrapped = (payload) => {
        if (payload && payload.type === type) {
          handler(payload);
        }
      };
      handlers.push(wrapped);
      return () => {
        const index = handlers.indexOf(wrapped);
        if (index >= 0) {
          handlers.splice(index, 1);
        }
      };
    },
    emit(payload) {
      for (const handler of [...handlers]) {
        handler(payload);
      }
    },
  };
}

function paintHostPermissionPrompt(ctx, request) {
  resetOfficialPermissionPrompt();
  const prompt = officialPermissionPrompt(request, (input) => {
    const client = globalThis.__rvTuiClient;
    const fn = client && client.permission && client.permission.reply;
    if (typeof fn === "function") {
      return fn(input);
    }
  });
  ctx.tuiDialogTitle = prompt.title;
  ctx.tuiPainted = () => prompt;
  ctx.tuiPaintSource = "sync.permission";
}

function installFakeTuiSdk(root, bus, ctx) {
  const pkg = join(root, "node_modules", "@opencode-ai", "tui");
  mkdirSync(join(pkg, "context"), { recursive: true });
  writeFileSync(
    join(pkg, "package.json"),
    JSON.stringify({
      name: "@opencode-ai/tui",
      type: "module",
      exports: {
        "./context/sdk": "./context/sdk.js",
        "./context/sync": "./context/sync.js",
      },
    }),
  );
  writeFileSync(
    join(pkg, "context", "sdk.js"),
    `export function useSDK() {
  return {
    directory: "/tmp",
    event: {
      emit(_type, event) {
        const payload = event && event.payload ? event.payload : event;
        if (typeof globalThis.__rvEmitTuiPayload === "function") {
          globalThis.__rvEmitTuiPayload(payload);
        }
      },
    },
    get client() {
      return globalThis.__rvTuiClient;
    },
  };
}
`,
  );
  writeFileSync(
    join(pkg, "context", "sync.js"),
    `export function useSync() {
  return {
    set(key, sessionID, value) {
      if (key === "permission" && Array.isArray(value) && value[0]) {
        if (typeof globalThis.__rvSyncPermission === "function") {
          globalThis.__rvSyncPermission(value[0]);
        }
      }
    },
    data: { permission: {} },
  };
}
`,
  );
  const v2Reply = ctx.client && ctx.client.session && ctx.client.session.permission
    && ctx.client.session.permission.reply;
  // Live PermissionPrompt Return uses useSDK().client, not api.client.
  // Unshimmed V1 reply does not resolve the V2 pending store.
  globalThis.__rvTuiClient = {
    session: ctx.client.session,
    permission: {
      async reply() {},
    },
  };
  if (ctx.client.permission) {
    ctx.client.permission.reply = async () => {
      ctx.apiClientReplyHit = true;
    };
  }
  globalThis.__rvEmitTuiPayload = (payload) => bus.emit(payload);
  globalThis.__rvSyncPermission = (request) => paintHostPermissionPrompt(ctx, request);
}

function installOfficialTuiSync(ctx, bus) {
  const asked = ["permission", "asked"].join(".");
  bus.on(asked, (payload) => {
    const request = payload && payload.properties;
    ctx.tuiV1Asked = true;
    if (process.env.RV_TUI_AUTO === "1") {
      const client = globalThis.__rvTuiClient;
      const fn = client && client.permission && client.permission.reply;
      if (typeof fn === "function" && request && request.id) {
        void fn({ reply: "once", requestID: request.id, directory: "/tmp" });
      }
    }
  });
}

async function loadTuiAskCompanion(ctx, pluginPath, click) {
  const { pathToFileURL: toURL } = await import("node:url");
  const tuiMod = await import(toURL(pluginPath).href);
  const bus = createOfficialTuiEventBus();
  const keymap = officialKeymap();
  officialKeymap.handleCount = 0;
  resetOfficialDialogConfirm();
  let painted = null;
  const dialog = {
    size: "medium",
    setSize(size) {
      this.size = size;
    },
    replace(input, onClose) {
      const element = typeof input === "function" ? input() : input;
      this.replaced = element;
      this.onClose = onClose;
      ctx.usedCustomDialogConfirm = officialDialogConfirm.last != null;
      painted = {
        title: element && element.title,
        message: element && element.message,
        key() {
          // Custom DialogConfirm is not the live winner.
        },
      };
    },
    clear() {
      if (typeof this.onClose === "function") {
        this.onClose();
      }
    },
  };
  function DialogConfirm(props) {
    return officialDialogConfirm(props, dialog);
  }
  installOfficialTuiSync(ctx, bus);
  const injectHostSdk = process.env.RV_TUI_INJECT_SDK === "1";
  let hostHooks;
  if (injectHostSdk) {
    // Live 1.18.18 layout: tui.tsx resolves @opencode-ai/tui next to the
    // Ask package. plugins/rv-guard-tui.js cannot. The TUI entry must pass
    // host useSDK into plugin.server — planting a fake next to the js file
    // hides the a3a68bd asked-but-unpainted FAIL.
    const askDir = join(dirname(pluginPath), "rv-guard-tui-ask");
    installFakeTuiSdk(askDir, bus, ctx);
    const { useSDK } = await import(
      pathToFileURL(join(askDir, "node_modules", "@opencode-ai", "tui", "context", "sdk.js")).href
    );
    const { useSync } = await import(
      pathToFileURL(join(askDir, "node_modules", "@opencode-ai", "tui", "context", "sync.js")).href
    );
    hostHooks = { useSDK, useSync };
  }
  const api = {
    keymap,
    event: {
      on(type, handler) {
        return bus.on(type, handler);
      },
    },
    ui: { dialog, DialogConfirm },
    client: ctx.client,
    slots: {
      register(plugin) {
        if (plugin && plugin.slots && typeof plugin.slots.app === "function") {
          plugin.slots.app();
        }
        return () => {};
      },
    },
  };
  if (typeof tuiMod.default?.server === "function") {
    if (hostHooks) {
      await tuiMod.default.server(api, {}, { client: { name: "opencode-tui" } }, hostHooks);
    } else {
      await tuiMod.default.server(api);
    }
  }
  ctx.tuiEmit = (payload) => bus.emit(payload);
  ctx.tuiClick = click;
  if (typeof ctx.tuiPainted !== "function") {
    ctx.tuiPainted = () => painted;
  }
  ctx.tuiKeymap = keymap;
}

function installOfficialPermission(ctx, reply) {
  const fetchOnly = reply.startsWith("fetch-");
  const injectClick = reply.startsWith("tui-inject-sdk-")
    ? reply.slice("tui-inject-sdk-".length)
    : undefined;
  const tuiClick = reply.startsWith("tui-click-")
    ? reply.slice("tui-click-".length)
    : injectClick;
  const effectReply = fetchOnly
    ? reply.slice("fetch-".length)
    : tuiClick
      ? "ask"
      : reply;
  const requestID = "per_test";
  const subscribeMode = process.env.RV_PERMISSION_SUBSCRIBE ?? "ok";
  ctx.permissionCreates = 0;
  ctx.permissionGets = 0;
  ctx.permissionReply204 = null;
  ctx.permissionStarted = Date.now();
  const recordCreate = () => {
    ctx.permissionCreates = (ctx.permissionCreates ?? 0) + 1;
  };
  const lateMs = Number(process.env.RV_PERMISSION_LATE_MS ?? 0);
  const official204 =
    effectReply === "once-204" ||
    effectReply === "once-204-pending" ||
    effectReply === "once-204-404" ||
    effectReply === "reject-204";
  const confirmReply =
    effectReply === "reject-204"
      ? "reject"
      : official204
        ? "once"
        : effectReply === "once" || effectReply === "always" || effectReply === "reject"
          ? effectReply
          : undefined;
  const getAfter204 = effectReply === "once-204-pending" ? "pending" : "404";
  const pendingBody = {
    data: {
      id: requestID,
      sessionID: "ses_1",
      action: "external_directory",
      resources: ["/rv-ask"],
    },
  };
  const deliverOfficialConfirm = (replyValue) => {
    ctx.permissionReply204 = replyValue;
    if (typeof ctx.pluginEvent !== "function") {
      return;
    }
    // Official 1.18.18 Plugin.listen: { event: { id, type, properties: event.data } }
    void ctx.pluginEvent({
      event: {
        id: "evt_test",
        type: "permission.v2.replied",
        properties: {
          sessionID: "ses_1",
          requestID,
          reply: replyValue,
        },
      },
    });
  };
  const scheduleOfficialConfirm = (replyValue) => {
    setTimeout(() => {
      deliverOfficialConfirm(replyValue);
    }, lateMs > 0 ? lateMs : 25);
  };
  const session = ctx.client.session ?? {};
  if (!fetchOnly) {
    session.permission = {
      async create(input) {
        recordCreate();
        if (effectReply === "allow") {
          return { data: { id: requestID, effect: "allow" } };
        }
        if (effectReply === "deny") {
          return { data: { id: requestID, effect: "deny" } };
        }
        if (official204 && confirmReply) {
          scheduleOfficialConfirm(confirmReply);
        }
        if (tuiClick || process.env.RV_TUI_PAINT === "0" || process.env.RV_TUI_AUTO === "1") {
          const sessionID =
            (input && input.sessionID) ||
            (input && input.path && input.path.sessionID) ||
            "ses_1";
          if (typeof ctx.tuiEmit === "function") {
            ctx.tuiEmit({
              type: "permission.v2.asked",
              properties: {
                id: requestID,
                sessionID,
                action: (input && input.action) || "external_directory",
                resources: (input && input.resources) || ["/rv-ask"],
                metadata: (input && input.metadata) || { rv: true },
              },
            });
          }
          const prompt = typeof ctx.tuiPainted === "function" ? ctx.tuiPainted() : undefined;
          if (prompt && typeof prompt.key === "function") {
            if (tuiClick === "once") {
              prompt.key("return");
            } else if (tuiClick === "reject") {
              prompt.key("left");
              prompt.key("return");
            }
          }
        }
        return { data: { id: requestID, effect: "ask" } };
      },
      async reply(input) {
        const replyValue = input && typeof input.reply === "string" ? input.reply : undefined;
        if (replyValue) {
          deliverOfficialConfirm(replyValue);
        }
      },
    };
  }
  ctx.client.session = session;
  ctx.client.permission = {
    async reply(input) {
      const replyValue = input && typeof input.reply === "string" ? input.reply : undefined;
      if (replyValue) {
        deliverOfficialConfirm(replyValue);
      }
    },
  };
  if (subscribeMode === "throw") {
    ctx.client.event = {
      async subscribe() {
        throw new Error("subscribe");
      },
    };
  } else if (subscribeMode !== "missing") {
    ctx.client.event = {
      async subscribe() {
        return {
          stream: (async function* () {
            if (effectReply === "once" || effectReply === "always" || effectReply === "reject") {
              yield {
                type: "permission.v2.replied",
                properties: {
                  sessionID: "ses_1",
                  requestID,
                  reply: effectReply,
                },
              };
            }
          })(),
        };
      },
    };
  }
  ctx.serverUrl = new URL("http://127.0.0.1:4096/");
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const href = String(url);
    const method = init && typeof init.method === "string" ? init.method.toUpperCase() : "GET";
    if (href.includes(`/permission/${requestID}/reply`) && method === "POST") {
      let body = {};
      try {
        body = init && init.body ? JSON.parse(String(init.body)) : {};
      } catch {
        body = {};
      }
      const replyValue = typeof body.reply === "string" ? body.reply : confirmReply;
      deliverOfficialConfirm(replyValue ?? "once");
      return { ok: true, status: 204, async json() { return undefined; } };
    }
    if (href.includes("/api/session/") && href.includes("/permission") && method === "POST") {
      recordCreate();
      if (effectReply === "allow") {
        return {
          ok: true,
          async json() {
            return { data: { id: requestID, effect: "allow" } };
          },
        };
      }
      if (effectReply === "deny") {
        return {
          ok: true,
          async json() {
            return { data: { id: requestID, effect: "deny" } };
          },
        };
      }
      if (official204 && confirmReply) {
        scheduleOfficialConfirm(confirmReply);
      }
      return {
        ok: true,
        async json() {
          return { data: { id: requestID, effect: "ask" } };
        },
      };
    }
    if (
      href.includes("/api/session/") &&
      href.includes(`/permission/${requestID}`) &&
      method === "GET"
    ) {
      ctx.permissionGets = (ctx.permissionGets ?? 0) + 1;
      if (effectReply === "absent") {
        return { ok: false, status: 404, async json() { return { _tag: "PermissionNotFoundError" }; } };
      }
      if (official204) {
        if (ctx.permissionReply204 && getAfter204 === "404") {
          return { ok: false, status: 404, async json() { return { _tag: "PermissionNotFoundError" }; } };
        }
        return { ok: true, async json() { return pendingBody; } };
      }
      return { ok: true, async json() { return pendingBody; } };
    }
    if (typeof previousFetch === "function") {
      return previousFetch(url, init);
    }
    throw new Error(`unexpected fetch ${href}`);
  };
}

async function runOpenCodeStep(plugin, event, flags) {
  const hookName = event.hook === "shell.env" ? "shell.env" : "tool.execute.before";
  if (hookName === "shell.env") {
    const fn = plugin["shell.env"];
    if (typeof fn !== "function") {
      return;
    }
    const input = {};
    if (typeof event.cwd === "string") {
      input.cwd = event.cwd;
    }
    if (typeof event.sessionID === "string") {
      input.sessionID = event.sessionID;
    }
    if (typeof event.callID === "string") {
      input.callID = event.callID;
    }
    if (typeof event.command === "string") {
      input.command = event.command;
    }
    if (flags.confirmYes && flags.hasUI) {
      input.ask = async () => true;
    }
    const output = { env: event.env ?? {} };
    if (event.args) {
      output.args = event.args;
    }
    if (flags.resolutionAllow) {
      output.onResolution = async () => ({ status: "allow-once" });
    }
    await fn(input, output);
    return;
  }

  const input = { tool: event.tool };
  if (typeof event.cwd === "string") {
    input.cwd = event.cwd;
  }
  if (typeof event.sessionID === "string") {
    input.sessionID = event.sessionID;
  }
  if (typeof event.callID === "string") {
    input.callID = event.callID;
  }
  if (flags.confirmYes && flags.hasUI) {
    input.ask = async () => true;
  }
  const output = { args: event.args ?? {} };
  if (flags.resolutionAllow) {
    output.onResolution = async () => ({ status: "allow-once" });
  }
  await plugin["tool.execute.before"](input, output);
}

process.stdout.write(JSON.stringify({ error: "unknown host" }));
process.exit(2);
