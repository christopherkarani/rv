import { pathToFileURL } from "node:url";

const host = process.argv[2];
const adapterPath = process.argv[3];
const event = JSON.parse(process.argv[4] ?? "{}");

const mod = await import(pathToFileURL(adapterPath).href);

if (host === "pi") {
  const factory = mod.default;
  const registered = [];
  const pi = {
    on(name, fn) {
      registered.push({ name, fn });
    },
    registerMessageRenderer() {
      throw new Error("registerMessageRenderer");
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
  const result = await registered[0].fn(event);
  process.stdout.write(JSON.stringify({ result: result ?? null }));
  process.exit(0);
}

if (host === "opencode") {
  const plugin = await mod.RvGuard();
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
    process.stdout.write(JSON.stringify({ threw: null }));
  } catch (error) {
    process.stdout.write(
      JSON.stringify({ threw: error instanceof Error ? error.message : String(error) })
    );
  }
  process.exit(0);
}

process.stdout.write(JSON.stringify({ error: "unknown host" }));
process.exit(2);
