// Official 1.18.18 paint is Tool.Context ctx.ask → Permission.ask
// (shell.ts) → V1 asked store → PermissionPrompt. Plugin create
// publishes V2 asked only. A plugin cannot call ctx.ask. A plugin
// store write or synthetic V1 event is not official create. This
// companion stays a no-op so leftover custom dialog installs are
// overwritten without inventing paint.
export default {
  id: "rv-guard-tui",
  server: async () => ({}),
};
