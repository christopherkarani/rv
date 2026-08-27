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
  if (typeof dialog.setSize === "function") {
    dialog.setSize("medium");
  }
  return await new Promise((resolve) => {
    let settled = false;
    const finish = (allowed) => {
      if (settled) {
        return;
      }
      settled = true;
      if (typeof unbind === "function") {
        unbind();
      }
      if (typeof dialog.clear === "function") {
        dialog.clear();
      }
      resolve(allowed);
    };
    const unbind = bindOfficialDialogKeys(api, {
      onConfirm: () => finish(true),
      onCancel: () => finish(false),
    });
    dialog.replace(
      () =>
        DialogConfirm({
          title: "RV · Ask",
          message,
          get onConfirm() {
            return () => finish(true);
          },
          get onCancel() {
            return () => finish(false);
          },
        }),
      () => {
        if (typeof unbind === "function") {
          unbind();
        }
      },
    );
  });
}

function bindOfficialDialogKeys(api, handlers) {
  const keymap = api && api.keymap;
  if (!keymap || typeof keymap.registerLayer !== "function") {
    return undefined;
  }
  let active = "confirm";
  const toggle = () => {
    active = active === "confirm" ? "cancel" : "confirm";
  };
  const submit = () => {
    if (active === "confirm") {
      handlers.onConfirm();
    }
    if (active === "cancel") {
      handlers.onCancel();
    }
  };
  return keymap.registerLayer({
    priority: 1000,
    commands: [
      {
        name: "dialog.confirm.submit",
        title: "Confirm dialog selection",
        category: "Dialog",
        run: submit,
      },
      {
        name: "dialog.confirm.toggle",
        title: "Toggle dialog option",
        category: "Dialog",
        run: toggle,
      },
    ],
    bindings: [
      {
        key: "return",
        cmd: "dialog.confirm.submit",
        desc: "Confirm dialog selection",
        group: "Dialog",
      },
      {
        key: "left",
        cmd: "dialog.confirm.toggle",
        desc: "Previous dialog option",
        group: "Dialog",
      },
      {
        key: "right",
        cmd: "dialog.confirm.toggle",
        desc: "Next dialog option",
        group: "Dialog",
      },
    ],
  });
}

async function replyOfficial(api, sessionID, requestID, reply) {
  const client = api && api.client;
  const fn =
    (client && client.permission && client.permission.reply) ||
    (client && client.v2 && client.v2.permission && client.v2.permission.reply) ||
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
