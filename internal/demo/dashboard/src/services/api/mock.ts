import type { ApiResponse, VersionInfo } from "./getExecutions";

export const CYCLE_DURATION = 60_000; // ms per version transition
const NUM_VERSIONS = 10;
const EXECUTIONS_PER_SECOND = 10;

let demoStartTime = Date.now();

export function resetDemo(): void {
  demoStartTime = Date.now();
}

export function getDemoStartTime(): number {
  return demoStartTime;
}

// Phases within a single version-to-version cycle (as fraction of CYCLE_DURATION):
//   [0.00, 0.10)  A — only "from" is active
//   [0.10, 0.25)  B — "to" ramping at 20%, from still active at 80%
//   [0.25, 0.45)  C — to ramping at 50%, from still active at 50%
//   [0.45, 0.65)  D — to ramping at 80%, from still active at 20%
//   [0.65, 0.82)  E — to becomes active at 100%, from draining (running → 0)
//   [0.82, 1.00)  F — from fully drained (inactive), to stable
//
// Only one version is ever "active" at a time. The new version is "ramping"
// until the old one stops accepting starts, at which point it flips to "active".
function computeVersions(elapsed: number): Record<string, VersionInfo> {
  const cycleIndex = Math.floor(elapsed / CYCLE_DURATION) % NUM_VERSIONS;
  const t = (elapsed % CYCLE_DURATION) / CYCLE_DURATION;

  const fromNum = cycleIndex + 1;
  // After v10, wrap back to v1: (9+1)%10+1 = 1 ✓
  const toNum = ((cycleIndex + 1) % NUM_VERSIONS) + 1;
  const from = `v${fromNum}`;
  const to = `v${toNum}`;

  if (t < 0.1) {
    return { [from]: { status: "active", running: 5, ramping: 100 } };
  }
  if (t < 0.25) {
    return {
      [from]: { status: "active", running: 5, ramping: 80 },
      [to]: { status: "ramping", running: 1, ramping: 20 },
    };
  }
  if (t < 0.45) {
    return {
      [from]: { status: "active", running: 4, ramping: 50 },
      [to]: { status: "ramping", running: 4, ramping: 50 },
    };
  }
  if (t < 0.65) {
    return {
      [from]: { status: "active", running: 2, ramping: 20 },
      [to]: { status: "ramping", running: 6, ramping: 80 },
    };
  }
  if (t < 0.82) {
    const p = (t - 0.65) / 0.17;
    return {
      [from]: { status: "draining", running: Math.max(0, Math.round(2 * (1 - p))), ramping: 0 },
      [to]: { status: "active", running: 7, ramping: 100 },
    };
  }
  return {
    [from]: { status: "inactive", running: 0, ramping: 0 },
    [to]: { status: "active", running: 5, ramping: 100 },
  };
}

export async function mockFetch(since: number): Promise<ApiResponse> {
  await new Promise<void>((r) => setTimeout(r, 50 + Math.random() * 100));

  const now = Date.now();
  const versions = computeVersions(now - demoStartTime);

  const windowSecs = Math.max(0, (now - since) / 1000);
  const count = Math.round(EXECUTIONS_PER_SECOND * windowSecs);

  // Route new starts only to active/ramping versions (draining/inactive get no new starts)
  const routedKeys = Object.keys(versions).filter(
    (k) => (versions[k].status === "active" || versions[k].status === "ramping") && versions[k].ramping > 0,
  );
  const totalRamping = routedKeys.reduce((s, k) => s + versions[k].ramping, 0);

  const executions = Array.from({ length: count }, (_, i) => {
    let rand = Math.random() * totalRamping;
    let chosen = routedKeys[0] ?? Object.keys(versions)[0];
    for (const k of routedKeys) {
      rand -= versions[k].ramping;
      if (rand <= 0) {
        chosen = k;
        break;
      }
    }
    return {
      id: `${now}-${i}-${Math.random().toString(36).slice(2, 9)}`,
      version: chosen,
    };
  });

  return { executions, versions };
}
