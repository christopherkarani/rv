import { NextResponse, type NextRequest } from "next/server";

/**
 * A fast gate in front of the UI: no session cookie, no page. The cookie's
 * signature and the user are verified server-side on every request
 * (`requireUser`), so this is a convenience redirect, not the boundary.
 */
export function proxy(request: NextRequest) {
  if (!request.cookies.has("rvc_session")) {
    const url = request.nextUrl.clone();
    const next = request.nextUrl.pathname + request.nextUrl.search;
    url.pathname = "/login";
    url.search = next && next !== "/" ? `?next=${encodeURIComponent(next)}` : "";
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  // Everything except sign-in pages and routes, APIs (they check auth themselves), health, and static files.
  matcher: ["/((?!login|setup|api/auth|api/health|api/v1|_next|icon.svg|favicon.ico).*)"],
};
