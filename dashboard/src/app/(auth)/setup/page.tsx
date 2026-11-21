import { redirect } from "next/navigation";
import { AuthFrame } from "@/components/auth/auth-frame";
import { SetupForm } from "@/components/auth/forms";
import { userCount } from "@/lib/server/auth";
import { boot } from "@/lib/server/boot";

export const dynamic = "force-dynamic";
export const metadata = { title: "Set up" };

export default async function SetupPage() {
  await boot();
  if (userCount() > 0) redirect("/login");
  return (
    <AuthFrame title="Set up rv Console" subtitle="Create the first admin. You can invite your team and connect machines next.">
      <SetupForm />
    </AuthFrame>
  );
}
