// Official OpenCode 1.18.18 `packages/tui/src/routes/session/permission.tsx`.
// Host PermissionPrompt mounts from the V1 asked store filled by
// Tool.Context ctx.ask → Permission.ask (shell.ts / webfetch /
// external-directory). Return calls `sdk.client.permission.reply` →
// Permission.reply publishes `permission.replied`. Not DialogConfirm.
// Plugin session.permission.create is V2 and does not paint. This
// fixture is Return shape only — not live proof a plugin can call ctx.ask.

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
        // Live PermissionPrompt Return omits sessionID. The TUI companion
        // must recover it from the official asked row.
        void replyFn({
          reply,
          requestID: request && request.id,
          directory: request && request.directory,
        });
      }
    },
  };
}

officialPermissionPrompt.usedBindings = false;

export function resetOfficialPermissionPrompt() {
  officialPermissionPrompt.usedBindings = false;
}
