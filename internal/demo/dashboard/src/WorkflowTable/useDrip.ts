import { useCallback, useEffect, useRef, useState } from "react";
import type { VersionedExecution, RetainedVersionInfo } from "../services/api";
import type { VersionStatus } from "../services/api";
import { POLL_INTERVAL } from "../services/api";

export type DisplayedRow = VersionedExecution & { displayStatus: VersionStatus };

const MAX_ROWS = 80;
const DRIP_BUDGET = POLL_INTERVAL * 0.72;
const DRIP_GAP_MIN = 150;
const DRIP_GAP_MAX = 1200;
const DRIP_JITTER_LOW = 0.75;
const DRIP_JITTER_HIGH = 0.5;

function usePendingQueue(executions: VersionedExecution[]) {
  const pendingRef = useRef<VersionedExecution[]>([]);
  const seenRef = useRef<Set<string>>(new Set());
  const baseGapRef = useRef(300);

  useEffect(() => {
    const newOnes = executions.filter((ex) => !seenRef.current.has(ex.id));
    if (newOnes.length === 0) return;

    // Mark seen before queuing so re-renders don't re-enqueue the same items
    newOnes.forEach((ex) => seenRef.current.add(ex.id));

    // Newest-first so the drip shows the latest execution at the top of the table
    pendingRef.current = [...newOnes.reverse(), ...pendingRef.current];

    // Spread the whole pending batch across the poll interval, clamped to readable bounds
    const count = pendingRef.current.length;
    baseGapRef.current = Math.min(Math.max(DRIP_BUDGET / count, DRIP_GAP_MIN), DRIP_GAP_MAX);
  }, [executions]);

  return { pendingRef, baseGapRef };
}

export function useDrip(executions: VersionedExecution[], versions: Record<string, RetainedVersionInfo>) {
  const [displayed, setDisplayed] = useState<DisplayedRow[]>([]);
  const [paused, setPaused] = useState(false);

  const { pendingRef, baseGapRef } = usePendingQueue(executions);

  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pausedRef = useRef(false);
  const versionsRef = useRef(versions);

  useEffect(() => {
    versionsRef.current = versions;
  }, [versions]);

  const startDrip = useCallback(() => {
    // Don't start a second drip loop if one is already running
    if (timerRef.current !== null) return;

    const tick = () => {
      if (pausedRef.current) {
        timerRef.current = null;
        return;
      }

      const next = pendingRef.current.shift();
      if (!next) {
        timerRef.current = null;
        return;
      }

      // Stamp the version's current status so the row color is historically accurate
      const displayStatus = versionsRef.current[next.version]?.status ?? "draining";
      setDisplayed((prev) => [{ ...next, displayStatus }, ...prev].slice(0, MAX_ROWS));

      // Jitter the gap so the drip feels organic rather than mechanical
      const gap = baseGapRef.current * (DRIP_JITTER_LOW + Math.random() * DRIP_JITTER_HIGH);
      timerRef.current = setTimeout(tick, gap);
    };

    tick();
  }, [pendingRef, baseGapRef]);

  useEffect(() => {
    startDrip();
  }, [executions, startDrip]);

  useEffect(
    () => () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current);
    },
    [],
  );

  const togglePause = useCallback(() => {
    const next = !pausedRef.current;

    pausedRef.current = next;
    setPaused(next);

    if (!next) startDrip();
  }, [startDrip]);

  return { displayed, paused, togglePause };
}
