import { pathToFileURL } from "node:url";

const adapterPath = process.argv[2];
const event = JSON.parse(process.argv[3] ?? "{}");

const def = (await import(pathToFileURL(adapterPath).href)).default;
if (!def || typeof def.register !== "function") {
  process.stdout.write(JSON.stringify({ error: "missing register" }));
  process.exit(2);
}

const registered = [];
const gatewayCalls = [];
const api = {
  on(name, fn, opts) {
    registered.push({ name, fn, opts });
  },
  runtime: {
    gateway: {
      async isAvailable() {
        return process.env.RV_GATEWAY_AVAILABLE !== "0";
      },
      async request(method, params) {
        gatewayCalls.push({ method, params });
        if (process.env.RV_GATEWAY_THROW === "1") {
          throw new Error("gateway");
        }
        if (method === "plugin.approval.request") {
          if (process.env.RV_GATEWAY_NO_ROUTE === "1") {
            return { decision: null };
          }
          return { id: "plugin:test-id" };
        }
        if (method === "plugin.approval.waitDecision") {
          if (process.env.RV_GATEWAY_TIMEOUT === "1") {
            return { decision: "timeout" };
          }
          const decision = process.env.RV_GATEWAY_DECISION;
          if (typeof decision === "string" && decision.length > 0) {
            return { id: params && params.id, decision };
          }
          return { id: params && params.id, decision: null };
        }
        throw new Error(`unexpected ${method}`);
      },
    },
  },
};

def.register(api);
if (registered.length !== 1 || registered[0].name !== "before_tool_call") {
  process.stdout.write(
    JSON.stringify({
      error: "unexpected events",
      events: registered.map((row) => row.name),
    }),
  );
  process.exit(2);
}

const ctx = {
  sessionId: event.sessionId,
  sessionKey: event.sessionKey,
  agentId: event.agentId,
  toolKind: event.ctxToolKind,
  requester: event.requester,
  turnSourceChannel: event.turnSourceChannel,
  turnSourceTo: event.turnSourceTo,
  turnSourceAccountId: event.turnSourceAccountId,
};
if (process.env.RV_ABORT === "1") {
  ctx.abortSignal = { aborted: true };
}
const result = await registered[0].fn(event, ctx);
process.stdout.write(
  JSON.stringify({
    result: result ?? null,
    gatewayCalls,
    opts: registered[0].opts ?? null,
  }),
);
process.exit(0);
