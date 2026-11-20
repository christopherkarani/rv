/** Only same-site relative paths, so `?next=` cannot become an open redirect. */
export function safeNext(value: string | null | undefined, fallback = "/") {
  if (!value || !value.startsWith("/") || value.startsWith("//") || value.startsWith("/\\")) return fallback
  try {
    const url = new URL(value, "http://local.invalid")
    if (url.origin !== "http://local.invalid") return fallback
    return url.pathname + url.search
  } catch {
    return fallback
  }
}
