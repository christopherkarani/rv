"use client"

import { Bar, BarChart, CartesianGrid, XAxis, YAxis } from "recharts"
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"

const config = {
  denied: { label: "Denied", color: "var(--chart-1)" },
  observed: { label: "Would-be (observe)", color: "var(--chart-2)" },
} satisfies ChartConfig

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const label = (iso: string) => `${MONTHS[Number(iso.slice(5, 7)) - 1]} ${Number(iso.slice(8))}`

export function ActivityChart({ data }: { data: { date: string; denied: number; observed: number }[] }) {
  return (
    <ChartContainer config={config} className="aspect-auto h-64 w-full">
      <BarChart data={data} margin={{ left: 0, right: 8, top: 8 }}>
        <CartesianGrid vertical={false} strokeDasharray="3 3" />
        <XAxis dataKey="date" tickLine={false} axisLine={false} tickMargin={8} minTickGap={24} tickFormatter={label} />
        <YAxis tickLine={false} axisLine={false} width={36} allowDecimals={false} />
        <ChartTooltip cursor={{ fill: "var(--muted)", opacity: 0.5 }} content={<ChartTooltipContent labelFormatter={(v) => label(String(v))} />} />
        <ChartLegend content={<ChartLegendContent />} />
        <Bar dataKey="denied" stackId="a" fill="var(--color-denied)" radius={[0, 0, 2, 2]} />
        <Bar dataKey="observed" stackId="a" fill="var(--color-observed)" radius={[2, 2, 0, 0]} />
      </BarChart>
    </ChartContainer>
  )
}
