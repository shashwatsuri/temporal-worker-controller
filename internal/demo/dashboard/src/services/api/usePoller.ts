import { useCallback, useEffect, useRef, useState } from "react";
import { mockFetch, getDemoStartTime } from "./mock";
import { getExecutions } from "./getExecutions";
import { env } from "../../env";
import type { ApiResponse } from "./getExecutions";

export type Batch = {
  response: ApiResponse;
  receivedAt: number;
};

export const POLL_INTERVAL = 10_000;

const fetchFn = env.VITE_LOCAL_DEMO_MODE ? mockFetch : getExecutions;

export function usePoller(interval = POLL_INTERVAL): {
  lastBatch: Batch | null;
  triggerPoll: () => void;
  resetSince: () => void;
} {
  const sinceRef = useRef<number | null>(null);
  const [lastBatch, setLastBatch] = useState<Batch | null>(null);

  const poll = useCallback(async () => {
    if (sinceRef.current === null) {
      sinceRef.current = env.VITE_LOCAL_DEMO_MODE ? getDemoStartTime() : Date.now();
    }
    const since = sinceRef.current;
    const response = await fetchFn(since);
    const receivedAt = Date.now();
    sinceRef.current = receivedAt;
    setLastBatch({ response, receivedAt });
  }, []);

  const resetSince = useCallback(() => {
    sinceRef.current = Date.now();
  }, []);

  useEffect(() => {
    poll();
    const id = setInterval(poll, interval);
    return () => clearInterval(id);
  }, [poll, interval]);

  return { lastBatch, triggerPoll: poll, resetSince };
}
