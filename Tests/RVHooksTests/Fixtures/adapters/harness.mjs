import { pathToFileURL } from "node:url";

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
  const plugin = await mod.RvGuard(ctx);
  const keys = Object.keys(plugin);
  const unexpected = keys.filter(
    (name) => name !== "tool.execute.before" && name !== "shell.env"
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
      })
    );
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        threw: error instanceof Error ? error.message : String(error),
        toasts,
        permissionCreates: ctx.permissionCreates ?? 0,
        permissionGets: ctx.permissionGets ?? 0,
      })
    );
  }
  process.exit(0);
}

function installOfficialPermission(ctx, reply) {
  const fetchOnly = reply.startsWith("fetch-");
  const effectReply = fetchOnly ? reply.slice("fetch-".length) : reply;
  const requestID = "per_test";
  const subscribeMode = process.env.RV_PERMISSION_SUBSCRIBE ?? "ok";
  ctx.permissionCreates = 0;
  ctx.permissionGets = 0;
  ctx.permissionStarted = Date.now();
  const recordCreate = () => {
    ctx.permissionCreates = (ctx.permissionCreates ?? 0) + 1;
  };
  const lateMs = Number(process.env.RV_PERMISSION_LATE_MS ?? 0);
  const pollReply =
    effectReply === "miss-then-once" || effectReply === "late-once"
      ? "once"
      : effectReply === "miss-then-reject"
        ? "reject"
        : effectReply;
  const session = ctx.client.session ?? {};
  if (!fetchOnly) {
    session.permission = {
      async create() {
        recordCreate();
        if (effectReply === "allow") {
          return { data: { id: requestID, effect: "allow" } };
        }
        if (effectReply === "deny") {
          return { data: { id: requestID, effect: "deny" } };
        }
        return { data: { id: requestID, effect: "ask" } };
      },
    };
  }
  ctx.client.session = session;
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
        return { ok: false, status: 404, async json() { return {}; } };
      }
      if (effectReply === "miss-then-once" || effectReply === "miss-then-reject") {
        if (ctx.permissionGets === 1) {
          return { ok: false, status: 404, async json() { return {}; } };
        }
        return {
          ok: true,
          async json() {
            return { data: { id: requestID, reply: pollReply } };
          },
        };
      }
      if (effectReply === "late-once") {
        if (Date.now() - ctx.permissionStarted < lateMs) {
          return {
            ok: true,
            async json() {
              return { data: { id: requestID, effect: "ask" } };
            },
          };
        }
        return {
          ok: true,
          async json() {
            return { data: { id: requestID, reply: "once" } };
          },
        };
      }
      if (effectReply === "once" || effectReply === "always" || effectReply === "reject") {
        return {
          ok: true,
          async json() {
            return { data: { id: requestID, reply: effectReply } };
          },
        };
      }
      return {
        ok: true,
        async json() {
          return { data: { id: requestID, effect: "ask" } };
        },
      };
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
