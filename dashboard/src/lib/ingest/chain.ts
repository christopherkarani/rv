/**
 * Off-machine check of rv's unkeyed audit hash chain. Each `audit.jsonl`
 * event carries `prev` (SHA-256 of the line before it) and `chainHead` (its
 * own line's SHA-256). Forwarded in order, each event's `prev` must equal the
 * head of the chained event before it. A mismatch means a line was edited,
 * removed, inserted or reordered on the machine — or forwarding skipped
 * events (a reset cursor), which an operator should also see.
 */
export interface ChainState {
  head: string | null;
}

export interface ChainStep {
  /** Set when this event does not follow the previous head. */
  broken: { expected: string; got: string | null } | null;
  /** True for the first chained event the console sees from a device. */
  anchored: boolean;
  head: string | null;
}

export function advanceChain(state: ChainState, event: { prev: string | null; chainHead: string | null }): ChainStep {
  if (!event.chainHead) return { broken: null, anchored: false, head: state.head };
  if (!state.head) return { broken: null, anchored: true, head: event.chainHead };
  if (event.prev !== state.head) {
    return { broken: { expected: state.head, got: event.prev }, anchored: false, head: event.chainHead };
  }
  return { broken: null, anchored: false, head: event.chainHead };
}

export type ChainVerdict = "intact" | "broken" | "unchained" | "behind";

/**
 * A device's integrity verdict. `behind` means the machine's last `rv report`
 * names a head the console never received: events are waiting to be
 * forwarded, or the tail was cut after the report. `reportHeadKnown` is null
 * when there is no report head to compare.
 */
export function chainVerdict(d: {
  chainEvents: number;
  chainBreaks: number;
  reportHeadKnown: boolean | null;
  reportChainIntact: boolean | null;
}): ChainVerdict {
  if (d.chainBreaks > 0 || d.reportChainIntact === false) return "broken";
  if (d.chainEvents === 0) return "unchained";
  if (d.reportHeadKnown === false) return "behind";
  return "intact";
}
