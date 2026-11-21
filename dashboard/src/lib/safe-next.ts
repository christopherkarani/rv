/**
 * Where to go after sign-in: a same-origin path only. Rejects `//host` and
 * `/\host` (browsers read both as another origin), whitespace and backslashes.
 */
export function safeNext(next: string): string {
  return /^\/(?![/\\])[^\s\\]*$/.test(next) ? next : "/";
}
