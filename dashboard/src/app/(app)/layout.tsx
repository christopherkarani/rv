import { cookies } from "next/headers";
import { AppShell } from "@/components/shell/app-shell";
import { requireUser } from "@/lib/server/auth";
import { boot } from "@/lib/server/boot";
import { db } from "@/lib/server/db";
import { statusSnapshot } from "@/lib/server/queries";
import pkg from "../../../package.json";

export const dynamic = "force-dynamic";

export default async function ConsoleLayout({ children }: { children: React.ReactNode }) {
  await boot();
  const user = await requireUser();
  const devices = db().prepare("SELECT id, hostname FROM devices ORDER BY hostname").all() as { id: string; hostname: string }[];
  const org = db().prepare("SELECT organization FROM devices WHERE organization IS NOT NULL GROUP BY organization ORDER BY COUNT(*) DESC LIMIT 1").get() as { organization: string } | undefined;
  return (
    <AppShell
      user={{ name: user.name, email: user.email, role: user.role }}
      organization={org?.organization ?? null}
      initialStatus={statusSnapshot()}
      devices={devices.map((d) => ({ id: d.id, hostname: d.hostname }))}
      version={pkg.version}
      initialCollapsed={(await cookies()).get("rvc_sidebar")?.value === "1"}
    >
      {children}
    </AppShell>
  );
}
