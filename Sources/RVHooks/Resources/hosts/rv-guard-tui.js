// Official 1.18.18 TUI mounts host PermissionPrompt only from
// the V1 asked store. Plugin create publishes V2 asked only.
// There is no official plugin create that fills that store.
// A plugin store write or synthetic V1 event is not official
// create. This companion stays a no-op so leftover custom
// dialog installs are overwritten without inventing paint.
export default {
  id: "rv-guard-tui",
  server: async () => ({}),
};
