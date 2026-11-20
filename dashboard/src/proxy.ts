import { NextResponse, type NextRequest } from "next/server"
import { createServerClient } from "@supabase/ssr"

// Refreshes the Supabase session cookie on every page request and sends
// signed-out visitors to /login. Machine endpoints (/api/v1) and the cron
// route authenticate themselves and are excluded by the matcher.

const PUBLIC_PATHS = ["/login", "/auth/"]

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request })
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
  if (!url || !key) return response

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        for (const { name, value } of list) request.cookies.set(name, value)
        response = NextResponse.next({ request })
        for (const { name, value, options } of list) response.cookies.set(name, value, options)
      },
    },
  })

  // Validates the JWT (and refreshes it when needed). Do not put code
  // between createServerClient and this call.
  const { data } = await supabase.auth.getClaims()
  const signedIn = Boolean(data?.claims?.sub)
  const path = request.nextUrl.pathname
  const isPublic = PUBLIC_PATHS.some((p) => path === p || path.startsWith(p))

  if (!signedIn && !isPublic) {
    const login = request.nextUrl.clone()
    login.pathname = "/login"
    login.search = path === "/" ? "" : `?next=${encodeURIComponent(path + request.nextUrl.search)}`
    return NextResponse.redirect(login)
  }
  if (signedIn && path === "/login") {
    const home = request.nextUrl.clone()
    home.pathname = "/"
    home.search = ""
    return NextResponse.redirect(home)
  }
  return response
}

export const config = {
  matcher: ["/((?!api/v1|api/cron|_next/static|_next/image|favicon.ico|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
}
