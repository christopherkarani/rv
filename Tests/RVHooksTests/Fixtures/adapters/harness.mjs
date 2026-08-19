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
  const ctx = { ui: {} };
  const result = await registered[0].fn(event, ctx);
  let rendererIsComponent = false;
  let rendererReturnedString = false;
  let lines = null;
  if (typeof renderer === "function") {
    const theme = {
      fg(_name, text) {
        return text;
      },
      bold(text) {
        return text;
      },
    };
    const payload = messages[0]?.message ?? {
      customType: rendererType,
      content: "Blocked.",
      details: {
        variant: "block",
        title: "RV",
        summary: "Blocked.",
        preview: "git status",
      },
    };
    const rendered = renderer(payload, {}, theme);
    rendererReturnedString = typeof rendered === "string";
    rendererIsComponent =
      rendered != null &&
      typeof rendered === "object" &&
      typeof rendered.render === "function";
    if (rendererIsComponent) {
      lines = rendered.render(80);
    }
  }
  process.stdout.write(
    JSON.stringify({
      result: result ?? null,
      rendererType,
      messages,
      rendererIsComponent,
      rendererReturnedString,
      lines,
    })
  );
  process.exit(0);
}

if (host === "opencode") {
  const toasts = [];
  const ctx = {
    client: {
      tui: {
        async showToast(input) {
          if (process.env.RV_TOAST_THROWS === "1") {
            throw new Error("toast");
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
  const plugin = await mod.RvGuard(ctx);
  const keys = Object.keys(plugin);
  if (keys.length !== 1 || keys[0] !== "tool.execute.before") {
    process.stdout.write(JSON.stringify({ error: "unexpected hooks", keys }));
    process.exit(2);
  }
  try {
    await plugin["tool.execute.before"](
      { tool: event.tool },
      { args: event.args ?? {} }
    );
    process.stdout.write(JSON.stringify({ threw: null, toasts }));
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        threw: error instanceof Error ? error.message : String(error),
        toasts,
      })
    );
  }
  process.exit(0);
}

process.stdout.write(JSON.stringify({ error: "unknown host" }));
process.exit(2);
