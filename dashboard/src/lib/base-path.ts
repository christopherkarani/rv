/**
 * The path the console is served under, such as "/console" when rykanv.com
 * proxies rykanv.com/console/* to it. Empty when it owns its host.
 *
 * Set RV_CONSOLE_BASE_PATH at build time (next.config.ts validates it and
 * passes it here). Next adds it to <Link>, router pushes, redirect() and
 * /_next assets by itself; raw fetches, <a href>, <img src>, cookie paths
 * and absolute URLs go through withBase.
 */
export const BASE_PATH = process.env.NEXT_PUBLIC_RV_BASE_PATH ?? "";

export const withBase = (path: string) => `${BASE_PATH}${path}`;
