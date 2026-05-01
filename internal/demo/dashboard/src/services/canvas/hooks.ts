import { useCallback, useEffect, useRef, useState } from 'react'
import type { DependencyList, RefObject } from 'react'
import type { DrawFn } from './draw'

export function useCanvas(
  drawFn: DrawFn,
  deps: DependencyList,
): RefObject<HTMLCanvasElement | null> {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const dpr = window.devicePixelRatio
    const { width, height } = canvas.getBoundingClientRect()

    if (canvas.width !== width * dpr || canvas.height !== height * dpr) {
      canvas.width = width * dpr
      canvas.height = height * dpr
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, width, height)
    drawFn(ctx)
  }, deps)

  return ref
}

export function useAnimationLoop(
  callback: (dt: number) => void,
  active: boolean,
): void {
  const callbackRef = useRef(callback)
  callbackRef.current = callback

  useEffect(() => {
    if (!active) return

    let rafId: number
    let last: number | null = null

    const tick = (now: number) => {
      const dt = last !== null ? (now - last) / 1000 : 0
      last = now
      callbackRef.current(dt)
      rafId = requestAnimationFrame(tick)
    }

    rafId = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(rafId)
  }, [active])
}

type Machine<TState extends string> = {
  initial: TState
  states: Record<TState, { on?: Partial<Record<string, TState>> }>
}

type SendEvent<TCtx> =
  | string
  | { type: string; ctx?: TCtx | ((prev: TCtx) => TCtx) }

export function useStateMachine<TState extends string, TCtx>(
  machine: Machine<TState>,
  initialCtx: TCtx,
) {
  const machineRef = useRef(machine)
  machineRef.current = machine

  const [state, setState] = useState<TState>(machine.initial)
  const [ctx, setCtx] = useState<TCtx>(initialCtx)

  const send = useCallback((event: SendEvent<TCtx>) => {
    const type = typeof event === 'string' ? event : event.type
    const ctxUpdate = typeof event === 'string' ? undefined : event.ctx

    setState((prev) => {
      const next = machineRef.current.states[prev].on?.[type]
      return next ?? prev
    })

    if (ctxUpdate !== undefined) {
      setCtx(typeof ctxUpdate === 'function'
        ? ctxUpdate
        : () => ctxUpdate,
      )
    }
  }, [])

  return [state, ctx, send] as const
}
