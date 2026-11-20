// Would-be blocks per observing machine per day, rounded to one decimal so
// the label always matches the number shown.
export function readiness(rate: number) {
  if (rate <= 0.7) return { tone: "success" as const, label: "Ready to enforce", note: "0.7 or fewer would-be blocks per machine per day." }
  if (rate <= 1.0) return { tone: "warning" as const, label: "Review first", note: "0.8 to 1.0 per machine per day. Check the top rules first." }
  return { tone: "error" as const, label: "Not ready", note: "Over 1.0 per machine per day. Enforcing now would interrupt work." }
}

