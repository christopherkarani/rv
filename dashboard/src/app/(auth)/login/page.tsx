import Link from "next/link";
import { redirect } from "next/navigation";
import { AuthFrame } from "@/components/auth/auth-frame";
import { LoginForm, SsoButton } from "@/components/auth/forms";
import { currentUser, userCount } from "@/lib/server/auth";
import { boot } from "@/lib/server/boot";
import { ssoSettings } from "@/lib/server/sso";
import { SSO_ERRORS } from "@/lib/sso-policy";
import { safeNext } from "@/lib/safe-next";

export const dynamic = "force-dynamic";
export const metadata = { title: "Sign in" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string; local?: string }> }) {
  await boot();
  const noUsers = userCount() === 0;
  if (noUsers && !ssoSettings) redirect("/setup");
  if (await currentUser()) redirect("/");
  const { next, error, local } = await searchParams;
  const nextPath = safeNext(next ?? "/");
  const ssoError = error ? SSO_ERRORS[error] ?? SSO_ERRORS["sso-failed"] : undefined;
  // With SSO enforced, the password form is the local admins' break-glass door (?local=1).
  const showPassword = !ssoSettings?.enforce || local === "1";
  return (
    <AuthFrame title="Sign in" subtitle="Your fleet's agent activity, blocks and audit integrity.">
      <div className="grid gap-5">
        {ssoError && (
          <p role="alert" className="rounded-md border border-status-critical/30 bg-status-critical/10 px-3 py-2 text-sm">{ssoError}</p>
        )}
        {ssoSettings && <SsoButton name={ssoSettings.name} next={nextPath} />}
        {ssoSettings && showPassword && (
          <div className="flex items-center gap-3 text-xs text-muted-foreground">
            <span className="h-px flex-1 bg-border" />{ssoSettings.enforce ? "local admin" : "or with a password"}<span className="h-px flex-1 bg-border" />
          </div>
        )}
        {showPassword && <LoginForm next={nextPath} />}
        {ssoSettings?.enforce && !showPassword && (
          <p className="text-xs text-muted-foreground">Local admin? <Link className="underline underline-offset-4" href={`/login?local=1&next=${encodeURIComponent(nextPath)}`}>Use a password</Link></p>
        )}
        {noUsers && (
          <p className="text-xs text-muted-foreground">No accounts yet. The first person to sign in with {ssoSettings?.name} becomes an admin, or <Link className="underline underline-offset-4" href="/setup">create a local admin</Link>.</p>
        )}
      </div>
    </AuthFrame>
  );
}
