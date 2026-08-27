// Official OpenCode 1.18.18 `packages/tui/src/ui/dialog-confirm.tsx`.
// Host `useBindings` own left / right / return. Plugin `registerLayer` loses.
// Return reads the painted `active` store and calls `props.onConfirm?.()` /
// `props.onCancel?.()`, then `dialog.clear()`. Same source that paints focus.
// Tests must fire those keys here. Do not invent `painted.onConfirm()`.

export function officialDialogConfirm(props, dialog) {
  const store = { active: "confirm" };
  const painted = {
    title: props && props.title,
    message: props && props.message,
    get focus() {
      return store.active;
    },
    key(name) {
      officialDialogConfirm.usedBindings = true;
      if (name === "left" || name === "right") {
        store.active = store.active === "confirm" ? "cancel" : "confirm";
        return;
      }
      if (name !== "return") {
        return;
      }
      if (store.active === "confirm" && typeof (props && props.onConfirm) === "function") {
        props.onConfirm();
      }
      if (store.active === "cancel" && typeof (props && props.onCancel) === "function") {
        props.onCancel();
      }
      if (dialog && typeof dialog.clear === "function") {
        dialog.clear();
      }
    },
  };
  officialDialogConfirm.last = painted;
  return painted;
}

officialDialogConfirm.last = undefined;
officialDialogConfirm.usedBindings = false;

export function resetOfficialDialogConfirm() {
  officialDialogConfirm.last = undefined;
  officialDialogConfirm.usedBindings = false;
}

export function keyThroughOfficialDialogConfirm(element) {
  return {
    title: element && element.title,
    message: element && element.message,
    get focus() {
      if (officialDialogConfirm.last) {
        return officialDialogConfirm.last.focus;
      }
      return (element && (element.focus ?? element.active)) || "confirm";
    },
    key(name) {
      if (officialDialogConfirm.last && typeof officialDialogConfirm.last.key === "function") {
        officialDialogConfirm.last.key(name);
        return true;
      }
      return false;
    },
  };
}
