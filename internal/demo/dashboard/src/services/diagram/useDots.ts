import { useEffect, useRef } from "react";
import { POLL_INTERVAL } from "../api";
import type { VersionedExecution } from "../api";
import { TRAVEL_DURATION, type Dot } from "./dots";

const DOT_SPREAD_JITTER_MS = 600;
const DOT_EXPIRY_BUFFER_MS = 500;

export function useDots(executions: VersionedExecution[]): React.RefObject<Dot[]> {
  const dotsRef = useRef<Dot[]>([]);
  const scheduledIds = useRef<Set<string>>(new Set());

  useEffect(() => {
    const now = Date.now();

    const unseenExecutions = executions.filter((e) => !scheduledIds.current.has(e.id));
    if (unseenExecutions.length === 0) return;

    // Group by batch (executions from the same poll share receivedAt)
    const executionsByBatch = new Map<number, VersionedExecution[]>();
    for (const execution of unseenExecutions) {
      const batch = executionsByBatch.get(execution.receivedAt) ?? [];
      batch.push(execution);
      executionsByBatch.set(execution.receivedAt, batch);
    }

    const newDots: Dot[] = [];
    for (const [receivedAt, batch] of executionsByBatch) {
      batch.forEach((execution, index) => {
        scheduledIds.current.add(execution.id);
        newDots.push({
          id: execution.id,
          version: execution.version,
          // Spread evenly across the poll interval + small random jitter
          // so the flow looks organic rather than perfectly uniform.
          startTime: receivedAt + (index / batch.length) * POLL_INTERVAL + (Math.random() - 0.5) * DOT_SPREAD_JITTER_MS,
        });
      });
    }

    // Path is no longer stored here — it's computed per-frame from current layout
    // so dots stay accurate when version boxes reposition after a new version appears.

    const expiryCutoff = now - TRAVEL_DURATION - DOT_EXPIRY_BUFFER_MS;
    dotsRef.current = [...dotsRef.current.filter((dot) => dot.startTime > expiryCutoff), ...newDots];
  }, [executions]);

  return dotsRef;
}
