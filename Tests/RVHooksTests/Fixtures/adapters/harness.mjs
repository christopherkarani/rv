import { pathToFileURL } from "node:url";
import { officialDialogConfirm, resetOfficialDialogConfirm } from "./opencode-11818-dialog-confirm.mjs";

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

async function loadTuiAskCompanion(ctx, pluginPath, click) {
  const { pathToFileURL: toURL } = await import("node:url");
  const tuiMod = await import(toURL(pluginPath).href);
  const handlers = new Map();
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
      painted = officialDialogConfirm.last
        ? officialDialogConfirm.last
        : {
            title: element && element.title,
            message: element && element.message,
            get focus() {
              return (element && (element.focus ?? element.active)) || "confirm";
            },
            key() {
              // Official DialogConfirm useBindings did not paint. registerLayer loses.
            },
          };
      ctx.tuiDialogTitle = painted.title;
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
  const api = {
    keymap,
    event: {
      on(type, handler) {
        handlers.set(type, handler);
        return () => handlers.delete(type);
      },
    },
    ui: { dialog, DialogConfirm },
    client: ctx.client,
  };
  if (typeof tuiMod.default?.server === "function") {
    await tuiMod.default.server(api);
  }
  ctx.tuiAsked = handlers.get("permission.v2.asked");
  ctx.tuiClick = click;
  ctx.tuiPainted = () => painted;
  ctx.tuiKeymap = keymap;
}

function installOfficialPermission(ctx, reply) {
  const fetchOnly = reply.startsWith("fetch-");
  const tuiClick = reply.startsWith("tui-click-") ? reply.slice("tui-click-".length) : undefined;
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
        if (tuiClick && typeof ctx.tuiAsked === "function") {
          const sessionID =
            (input && input.sessionID) ||
            (input && input.path && input.path.sessionID) ||
            "ses_1";
          const asked = ctx.tuiAsked({
            type: "permission.v2.asked",
            properties: {
              id: requestID,
              sessionID,
              metadata: (input && input.metadata) || { rv: true },
            },
          });
          const clickPainted = async () => {
            for (let i = 0; i < 40; i++) {
              const painted = typeof ctx.tuiPainted === "function" ? ctx.tuiPainted() : null;
              if (painted && typeof painted.key === "function") {
                if (tuiClick === "once") {
                  painted.key("return");
                } else if (tuiClick === "reject") {
                  painted.key("left");
                  painted.key("return");
                }
                return;
              }
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
          };
          void clickPainted();
          void asked;
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
