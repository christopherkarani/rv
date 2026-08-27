const V2_ASKED = "permission.v2.asked";

function v1AskedName() {
  return ["permission", "asked"].join(".");
}

function text(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function adaptV2Asked(event) {
  const props = event && typeof event === "object" ? (event.properties ?? event.data ?? event) : undefined;
  if (!props || typeof props !== "object") {
    return undefined;
  }
  const id = text(props.id);
  const sessionID = text(props.sessionID);
  if (!id || !sessionID) {
    return undefined;
  }
  const source = props.source;
  const tool =
    source && source.type === "tool" && text(source.messageID) && text(source.callID)
      ? { messageID: source.messageID, callID: source.callID }
      : undefined;
  return {
    type: v1AskedName(),
    properties: {
      id,
      sessionID,
      permission: typeof props.action === "string" ? props.action : "external_directory",
      patterns: Array.isArray(props.resources) ? props.resources : ["/rv-ask"],
      always: Array.isArray(props.save) ? props.save : [],
      metadata: props.metadata && typeof props.metadata === "object" ? props.metadata : {},
      tool,
    },
  };
}

function attachReplyShim(client, v2Ids) {
  const permission = client && client.permission;
  if (!permission || typeof permission.reply !== "function") {
    return;
  }
  const original = permission.reply.bind(permission);
  permission.reply = async (input) => {
    const id = text(input && input.requestID);
    const sessionID = text(input && input.sessionID) ?? (id ? v2Ids.get(id) : undefined);
    const v2 = client.session && client.session.permission && client.session.permission.reply;
    if (id && sessionID && v2Ids.has(id) && typeof v2 === "function") {
      return await v2({
        reply: input && input.reply,
        requestID: id,
        sessionID,
        directory: input && input.directory,
        workspace: input && input.workspace,
        path: { sessionID, requestID: id },
      });
    }
    return await original(input);
  };
}

export function attachOfficialPermissionAskedBridge(api, writeAsked, client) {
  if (!api || typeof writeAsked !== "function") {
    return;
  }
  const on = api.event && api.event.on;
  if (typeof on !== "function") {
    return;
  }
  const v2Ids = new Map();
  attachReplyShim(client, v2Ids);
  on(V2_ASKED, (event) => {
    const adapted = adaptV2Asked(event);
    if (!adapted) {
      return;
    }
    v2Ids.set(adapted.properties.id, adapted.properties.sessionID);
    writeAsked(adapted);
  });
}

export default {
  id: "rv-guard-tui",
  server: async (api, _options, _meta, hooks) => {
    if (!api || !api.event || typeof api.event.on !== "function") {
      return {};
    }
    if (!api.slots || typeof api.slots.register !== "function") {
      return {};
    }
    let useSDK = hooks && typeof hooks.useSDK === "function" ? hooks.useSDK : undefined;
    let useSync = hooks && typeof hooks.useSync === "function" ? hooks.useSync : undefined;
    if (typeof useSDK !== "function") {
      try {
        ({ useSDK } = await import("@opencode-ai/tui/context/sdk"));
      } catch {
        return {};
      }
    }
    if (typeof useSDK !== "function") {
      return {};
    }
    if (typeof useSync !== "function") {
      try {
        ({ useSync } = await import("@opencode-ai/tui/context/sync"));
      } catch {
        useSync = undefined;
      }
    }
    let attached = false;
    api.slots.register({
      slots: {
        app() {
          const sdk = useSDK();
          const sync = typeof useSync === "function" ? useSync() : undefined;
          if (attached) {
            return null;
          }
          if (!sdk || !sdk.client) {
            return null;
          }
          attached = true;
          attachOfficialPermissionAskedBridge(
            api,
            (adapted) => {
              if (
                !sync ||
                typeof sync.set !== "function" ||
                !adapted ||
                adapted.type !== v1AskedName() ||
                !adapted.properties ||
                !adapted.properties.sessionID
              ) {
                return;
              }
              sync.set("permission", adapted.properties.sessionID, [adapted.properties]);
            },
            sdk.client,
          );
          return null;
        },
      },
    });
    return {};
  },
};
