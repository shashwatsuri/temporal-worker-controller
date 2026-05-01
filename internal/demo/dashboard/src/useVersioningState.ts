import { useCallback, useEffect, useReducer } from 'react'
import { resetDemo, usePoller } from './services/api'
import type { Batch, Execution, VersionInfo, VersionedExecution, RetainedVersionInfo } from './services/api'

export type { VersionedExecution, RetainedVersionInfo }

type State = {
  executions: VersionedExecution[]
  versions: Record<string, RetainedVersionInfo>
  lastPolledAt: number | null
}

type Action =
  | { kind: 'batch'; payload: Batch }
  | { kind: 'reset' }

const MAX_VERSIONS = 5

const initial: State = { executions: [], versions: {}, lastPolledAt: null }

// --- Reducer helpers ---

function countByVersion(executions: Execution[]): Record<string, number> {
  const totals: Record<string, number> = {}
  for (const e of executions) {
    totals[e.version] = (totals[e.version] ?? 0) + 1
  }
  return totals
}

function refreshVersions(
  known: Record<string, RetainedVersionInfo>,
  apiVersions: Record<string, VersionInfo>,
  incomingTotals: Record<string, number>,
  now: number,
): Record<string, RetainedVersionInfo> {
  const next: Record<string, RetainedVersionInfo> = {}

  // Carry forward known versions, refreshing from API or stamping droppedAt
  for (const [v, info] of Object.entries(known)) {
    next[v] = v in apiVersions
      ? { ...apiVersions[v], total: info.total + (incomingTotals[v] ?? 0) }
      : { ...info, droppedAt: info.droppedAt ?? now }
  }

  // Admit new versions — active/ramping always; draining/inactive only under the cap
  // (prevents re-adding previously evicted noise versions on every poll)
  for (const [v, info] of Object.entries(apiVersions)) {
    if (v in next) continue
    if (info.status === 'active' || info.status === 'ramping') {
      next[v] = { ...info, total: incomingTotals[v] ?? 0 }
    } else if (Object.keys(next).length < MAX_VERSIONS) {
      next[v] = { ...info, total: incomingTotals[v] ?? 0 }
    }
  }

  return next
}

function evictExcess(versions: Record<string, RetainedVersionInfo>): Set<string> {
  const excess = Object.keys(versions).length - MAX_VERSIONS
  if (excess <= 0) return new Set()

  const evictPriority = (i: RetainedVersionInfo) =>
    i.status === 'inactive' ? 0 : i.status === 'draining' ? 1 : 2

  const toEvict = Object.entries(versions)
    .filter(([, i]) => i.status === 'inactive' || i.status === 'draining')
    .sort(([, a], [, b]) => evictPriority(a) - evictPriority(b) || (a.droppedAt ?? 0) - (b.droppedAt ?? 0))
    .slice(0, excess)
    .map(([v]) => v)

  return new Set(toEvict)
}

function omit<T>(record: Record<string, T>, keys: Set<string>): Record<string, T> {
  return Object.fromEntries(Object.entries(record).filter(([k]) => !keys.has(k)))
}

// --- Reducer ---

function reducer(state: State, action: Action): State {
  if (action.kind === 'reset') return initial

  const { payload } = action
  const now = payload.receivedAt
  const incomingTotals = countByVersion(payload.response.executions)

  const next = refreshVersions(state.versions, payload.response.versions, incomingTotals, now)
  const evicted = evictExcess(next)
  const versions = evicted.size > 0 ? omit(next, evicted) : next

  const executions = [
    ...state.executions.filter((e) => !evicted.has(e.version)),
    ...payload.response.executions
      .filter((e) => !evicted.has(e.version))
      .map((e) => ({ ...e, receivedAt: now })),
  ]

  return { executions, versions, lastPolledAt: now }
}

// --- Hook ---

export function useVersioningState() {
  const [state, dispatch] = useReducer(reducer, initial)
  const { lastBatch, triggerPoll, resetSince } = usePoller()

  useEffect(() => {
    if (lastBatch) dispatch({ kind: 'batch', payload: lastBatch })
  }, [lastBatch])

  const reset = useCallback(() => {
    resetDemo()
    resetSince()
    dispatch({ kind: 'reset' })
    triggerPoll()
  }, [resetSince, triggerPoll])

  return { ...state, reset }
}
