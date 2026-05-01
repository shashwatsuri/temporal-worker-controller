import { useEffect, useRef } from "react";
import type { VersionStatus } from "../api";
import type { RetainedVersionInfo } from "../api";
import type { DiagramArrow, DiagramLayout, DisplayState, Point, Rect, VersionNode } from "./types";

// --- Layout constants (pixels) ---

export const BOX_W = 144;
export const BOX_H = 68;
export const BOX_GAP = 24; // vertical gap between stacked version boxes
export const COL_GAP = 88; // horizontal gap between columns (arrow space)

const ENTER_DURATION = 450; // ms to fade in
const EXIT_DURATION = 350; // ms to fade out

// --- Internal state ---

type Entry = {
  key: string;
  status: VersionStatus;
  ramping: number;
  running: number;
  total: number;
  addedAt: number;
  enterTime: number;
  exitTime?: number;
};

const easeOut = (t: number) => 1 - (1 - t) ** 2;

const STATUS_ORDER: Record<string, number> = {
  inactive: 0,
  draining: 1,
  ramping: 2,
  active: 3,
};

// --- Layout computation (pure, called per-frame) ---

function computeLayout(entries: Entry[], canvasW: number, canvasH: number, now: number): DiagramLayout {
  const midY = canvasH / 2;

  const cloudRect: Rect = {
    x: (canvasW - BOX_W) / 2,
    y: midY - BOX_H / 2,
    w: BOX_W,
    h: BOX_H,
  };

  const clientRect: Rect = {
    x: cloudRect.x - COL_GAP - BOX_W,
    y: midY - BOX_H / 2,
    w: BOX_W,
    h: BOX_H,
  };

  const n = entries.length;
  const totalH = n * BOX_H + Math.max(0, n - 1) * BOX_GAP;
  const versionX = cloudRect.x + BOX_W + COL_GAP;

  const versionNodes: VersionNode[] = entries.map((e, i) => {
    let displayState: DisplayState;
    let progress: number;

    if (e.exitTime !== undefined) {
      displayState = "exiting";
      progress = Math.max(0, 1 - easeOut((now - e.exitTime) / EXIT_DURATION));
    } else {
      const enterElapsed = now - e.enterTime;
      if (enterElapsed < ENTER_DURATION) {
        displayState = "entering";
        progress = easeOut(enterElapsed / ENTER_DURATION);
      } else {
        displayState = "visible";
        progress = 1;
      }
    }

    return {
      key: e.key,
      status: e.status,
      ramping: e.ramping,
      running: e.running,
      total: e.total,
      displayState,
      progress,
      rect: {
        x: versionX,
        y: midY - totalH / 2 + i * (BOX_H + BOX_GAP),
        w: BOX_W,
        h: BOX_H,
      },
    };
  });

  const cloudExit: Point = {
    x: cloudRect.x + cloudRect.w,
    y: cloudRect.y + cloudRect.h / 2,
  };

  // Arrows only for non-exiting nodes that have active routing
  const routed = versionNodes.filter((n) => n.ramping > 0 && n.displayState !== "exiting");
  const arrows: DiagramArrow[] = routed.map((node) => ({
    from: cloudExit,
    to: { x: node.rect.x, y: node.rect.y + node.rect.h / 2 },
    label: "",
    alpha: node.progress,
  }));

  return { canvasW, canvasH, clientRect, cloudRect, versionNodes, arrows };
}

// --- Hook ---
//
// Returns a tick function called each animation frame. The tick prunes
// completed exit animations and returns a fresh layout with progress values
// derived from the current timestamp — no React state updates at 60fps.

export function useDiagram(
  versions: Record<string, RetainedVersionInfo>,
  canvasW: number,
  canvasH: number,
): (now: number) => DiagramLayout {
  const entriesRef = useRef<Entry[]>([]);

  useEffect(() => {
    const now = Date.now();
    const currentKeys = new Set(Object.keys(versions));

    const next: Entry[] = entriesRef.current.map((e) => {
      // Start exiting if version disappeared and not already exiting
      if (!currentKeys.has(e.key) && e.exitTime === undefined) {
        return { ...e, exitTime: now };
      }
      // Update live data for existing versions
      if (currentKeys.has(e.key)) {
        const info = versions[e.key];
        return { ...e, status: info.status, ramping: info.ramping, running: info.running, total: info.total };
      }
      return e;
    });

    // Append newly seen versions
    const seen = new Set(next.map((e) => e.key));
    for (const [key, info] of Object.entries(versions)) {
      if (!seen.has(key)) {
        next.push({
          key,
          status: info.status,
          ramping: info.ramping,
          running: info.running,
          total: info.total,
          addedAt: now,
          enterTime: now,
        });
      }
    }

    entriesRef.current = next.sort((a, b) => a.addedAt - b.addedAt || STATUS_ORDER[a.status] - STATUS_ORDER[b.status]);
  }, [versions]);

  // canvasW/canvasH close over the latest render values; safe because
  // useAnimationLoop reads this function via a callbackRef, not as a dep.
  return (now: number) => {
    // Prune entries whose exit animation has fully completed
    entriesRef.current = entriesRef.current.filter((e) => e.exitTime === undefined || now - e.exitTime < EXIT_DURATION);
    return computeLayout(entriesRef.current, canvasW, canvasH, now);
  };
}
