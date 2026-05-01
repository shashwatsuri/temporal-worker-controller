import type { VersionStatus } from '../api'

export type DisplayState = 'entering' | 'visible' | 'exiting'

export type Rect  = { x: number; y: number; w: number; h: number }
export type Point = { x: number; y: number }

export type VersionNode = {
  key: string
  status: VersionStatus
  ramping: number
  running: number
  total: number
  displayState: DisplayState
  progress: number
  rect: Rect
}

export type DiagramArrow = {
  from: Point
  to: Point
  label: string  // e.g. "80%" — empty when there is only one destination
  alpha?: number // fades with the target version node during enter/exit
}

export type DiagramLayout = {
  canvasW: number
  canvasH: number
  clientRect: Rect
  cloudRect: Rect
  versionNodes: VersionNode[]
  arrows: DiagramArrow[]
}
