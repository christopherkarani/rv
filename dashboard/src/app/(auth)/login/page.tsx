import { redirect } from "next/navigation";
import { AuthFrame } from "@/components/auth/auth-frame";
import { LoginForm } from "@/components/auth/forms";
import { currentUser, userCount } from "@/lib/server/auth";
import { boot } from "@/lib/server/boot";

export const dynamic = "force-dynamic";
export const metadata = { title: "Sign in" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  await boot();
  if (userCount() === 0) redirect("/setup");
  if (await currentUser()) redirect("/");
  const { next } = await searchParams;
  return (
    <AuthFrame title="Sign in" subtitle="Your fleet's agent activity, blocks and audit integrity.">
      <LoginForm next={next} />
    </AuthFrame>
  );
}
