// Official OpenCode 1.18.18 `packages/tui/src/routes/session/permission.tsx`.
// Host PermissionPrompt `useBindings` own left / right / return.
// Return calls `sdk.client.permission.reply` → Permission.reply publishes
// `permission.v2.replied`. That is the live winner. Not DialogConfirm.

export function officialPermissionPrompt(request, replyFn) {
  const keys = ["once", "always", "reject"];
  const store = { selected: "once" };
  return {
    title: "Permission required",
    get focus() {
      return store.selected;
    },
    key(name) {
      officialPermissionPrompt.usedBindings = true;
      if (name === "left") {
        const idx = keys.indexOf(store.selected);
        store.selected = keys[(idx - 1 + keys.length) % keys.length];
        return;
      }
      if (name === "right") {
        const idx = keys.indexOf(store.selected);
        store.selected = keys[(idx + 1) % keys.length];
        return;
      }
      if (name !== "return") {
        return;
      }
      const reply = store.selected;
      if (typeof replyFn === "function") {
        void replyFn({
          reply,
          requestID: request && request.id,
          sessionID: request && request.sessionID,
        });
      }
    },
  };
}

officialPermissionPrompt.usedBindings = false;

export function resetOfficialPermissionPrompt() {
  officialPermissionPrompt.usedBindings = false;
}
