import type { DiagramLayout, Point, Rect } from './types'

export const TRAVEL_DURATION = 2000 // ms per dot, end-to-end

export type Dot = {
  id: string
  version: string
  startTime: number  // ms — when the dot begins moving
}

// Build the waypoint path for a dot heading to a specific version using
// the CURRENT layout. Called per-frame so paths stay accurate when boxes reposition.
// Path goes through each box so the inside-box clip logic hides the dot naturally.
// Returns null if the version isn't currently in the layout.
export function buildDotPath(layout: DiagramLayout, version: string): Point[] | null {
  const { clientRect, cloudRect, versionNodes } = layout
  const node = versionNodes.find((n) => n.key === version)
  if (!node) return null

  return [
    { x: clientRect.x + clientRect.w, y: clientRect.y + clientRect.h / 2 },
    { x: cloudRect.x,                 y: cloudRect.y  + cloudRect.h / 2 },
    { x: cloudRect.x + cloudRect.w,   y: cloudRect.y  + cloudRect.h / 2 },
    { x: node.rect.x,                 y: node.rect.y  + node.rect.h / 2 },
  ]
}

export function insideRect(x: number, y: number, r: Rect): boolean {
  return x > r.x && x < r.x + r.w && y > r.y && y < r.y + r.h
}

// Interpolate position along a polyline at progress t ∈ [0, 1].
export function positionOnPath(path: Point[], t: number): Point {
  const clamped = Math.max(0, Math.min(1, t))

  const lengths: number[] = [0]
  for (let i = 1; i < path.length; i++) {
    const dx = path[i].x - path[i - 1].x
    const dy = path[i].y - path[i - 1].y
    lengths.push(lengths[i - 1] + Math.sqrt(dx * dx + dy * dy))
  }
  const total = lengths[lengths.length - 1]
  const target = clamped * total

  for (let i = 1; i < path.length; i++) {
    if (target <= lengths[i] || i === path.length - 1) {
      const segLen = lengths[i] - lengths[i - 1]
      const segT = segLen > 0 ? (target - lengths[i - 1]) / segLen : 1
      return {
        x: path[i - 1].x + (path[i].x - path[i - 1].x) * segT,
        y: path[i - 1].y + (path[i].y - path[i - 1].y) * segT,
      }
    }
  }
  return path[path.length - 1]
}
