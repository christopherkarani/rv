import { PageHeader } from "@/components/console/page-header";
import { EventExplorer } from "@/components/console/event-explorer";
import { eventFacets, searchEvents } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";

export const metadata = { title: "Activity" };

export default async function ActivityPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const range = parseRange(sp.range);
  const result = searchEvents({
    q: sp.q?.slice(0, 200), kind: sp.kind, decision: sp.decision, device: sp.device, host: sp.host, range, limit: 100,
  });
  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="Activity"
        description="Every rv.audit.v1 event your machines forwarded: hook denies, observe-mode would-be blocks, overrides, MCP calls, secret use, rule changes and owner actions."
      />
      <EventExplorer initialRows={result.rows} total={result.total} facets={eventFacets()} />
    </>
  );
}
