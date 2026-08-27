export default {
  id: "rv-guard-tui",
  server: async (api) => {
    const asked = "permission.v2.asked";
    if (api && api.event && typeof api.event.on === "function") {
      api.event.on(asked, (event) => confirmOfficial(api, event));
    }
    return {};
  },
};

async function confirmOfficial(api, event) {
  const props = event && (event.properties ?? event.data ?? event);
  if (!props || typeof props !== "object") {
    return;
  }
  const metadata = props.metadata && typeof props.metadata === "object" ? props.metadata : {};
  if (metadata.rv !== true) {
    return;
  }
  const sessionID = stringValue(props.sessionID);
  const requestID = stringValue(props.id);
  if (!sessionID || !requestID) {
    return;
  }
  const message =
    typeof metadata.reason === "string" && metadata.reason.length > 0
      ? metadata.reason
      : "Allow this command once?";
  const allowed = await showConfirm(api, message);
  if (allowed === undefined) {
    return;
  }
  await replyOfficial(api, sessionID, requestID, allowed ? "once" : "reject");
}

function stringValue(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

async function showConfirm(api, message) {
  const ui = api && api.ui;
  const dialog = ui && ui.dialog;
  const DialogConfirm = ui && ui.DialogConfirm;
  if (!dialog || typeof dialog.replace !== "function" || typeof DialogConfirm !== "function") {
    return undefined;
  }
  const createComponent = await officialCreateComponent(ui);
  if (typeof createComponent !== "function") {
    return undefined;
  }
  if (typeof dialog.setSize === "function") {
    dialog.setSize("medium");
  }
  return await new Promise((resolve) => {
    dialog.replace(() =>
      createComponent(DialogConfirm, {
        title: "RV · Ask",
        message,
        onConfirm: () => resolve(true),
        onCancel: () => resolve(false),
      }),
    );
  });
}

async function officialCreateComponent(ui) {
  if (ui && typeof ui.createComponent === "function") {
    return ui.createComponent;
  }
  try {
    const solid = await import("solid-js");
    if (solid && typeof solid.createComponent === "function") {
      return solid.createComponent;
    }
  } catch {
    // Server process has no Solid runtime. Leave the ask pending.
  }
  return undefined;
}

async function replyOfficial(api, sessionID, requestID, reply) {
  const client = api && api.client;
  const fn =
    (client &&
      client.session &&
      client.session.permission &&
      client.session.permission.reply) ||
    (client &&
      client.v2 &&
      client.v2.session &&
      client.v2.session.permission &&
      client.v2.session.permission.reply);
  if (typeof fn === "function") {
    await fn({
      sessionID,
      requestID,
      reply,
      path: { sessionID, requestID, id: sessionID },
    });
  }
}
