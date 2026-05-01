export type DrawFn = (ctx: CanvasRenderingContext2D) => void

export type Point = { x: number; y: number }

export type Style = {
  fill?: string
  stroke?: string
  lineWidth?: number
  lineDash?: number[]
  font?: string
  textAlign?: CanvasTextAlign
  textBaseline?: CanvasTextBaseline
  alpha?: number
}

function applyStyle(ctx: CanvasRenderingContext2D, style: Style) {
  if (style.fill !== undefined) ctx.fillStyle = style.fill
  if (style.stroke !== undefined) ctx.strokeStyle = style.stroke
  if (style.lineWidth !== undefined) ctx.lineWidth = style.lineWidth
  if (style.lineDash !== undefined) ctx.setLineDash(style.lineDash)
  if (style.font !== undefined) ctx.font = style.font
  if (style.textAlign !== undefined) ctx.textAlign = style.textAlign
  if (style.textBaseline !== undefined) ctx.textBaseline = style.textBaseline
  if (style.alpha !== undefined) ctx.globalAlpha *= style.alpha
}

// --- Math utils ---

export const lerp = (a: number, b: number, t: number): number => a + (b - a) * t

// --- Composition ---

export const compose = (...fns: DrawFn[]): DrawFn =>
  (ctx) => fns.forEach((fn) => fn(ctx))

export const when = (condition: boolean, fn: DrawFn): DrawFn =>
  condition ? fn : () => undefined

// --- Transforms (each saves/restores ctx state) ---

export const translate = (dx: number, dy: number, fn: DrawFn): DrawFn =>
  (ctx) => {
    ctx.save()
    ctx.translate(dx, dy)
    fn(ctx)
    ctx.restore()
  }

export const scale = (sx: number, sy: number, fn: DrawFn): DrawFn =>
  (ctx) => {
    ctx.save()
    ctx.scale(sx, sy)
    fn(ctx)
    ctx.restore()
  }

export const rotate = (angle: number, fn: DrawFn): DrawFn =>
  (ctx) => {
    ctx.save()
    ctx.rotate(angle)
    fn(ctx)
    ctx.restore()
  }

export const withAlpha = (alpha: number, fn: DrawFn): DrawFn =>
  (ctx) => {
    ctx.save()
    ctx.globalAlpha *= alpha
    fn(ctx)
    ctx.restore()
  }

export const withStyle = (style: Style, fn: DrawFn): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)
    fn(ctx)
    ctx.restore()
  }

// --- Primitives ---

export const rect = (
  x: number,
  y: number,
  w: number,
  h: number,
  style: Style = {},
): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)
    if (style.fill !== undefined) ctx.fillRect(x, y, w, h)
    if (style.stroke !== undefined) ctx.strokeRect(x, y, w, h)
    ctx.restore()
  }

export const circle = (
  x: number,
  y: number,
  r: number,
  style: Style = {},
): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)
    ctx.beginPath()
    ctx.arc(x, y, r, 0, Math.PI * 2)
    if (style.fill !== undefined) ctx.fill()
    if (style.stroke !== undefined) ctx.stroke()
    ctx.restore()
  }

export const line = (from: Point, to: Point, style: Style = {}): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)
    ctx.beginPath()
    ctx.moveTo(from.x, from.y)
    ctx.lineTo(to.x, to.y)
    ctx.stroke()
    ctx.restore()
  }

export const arrow = (
  from: Point,
  to: Point,
  style: Style = {},
  headLen = 10,
): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)

    const angle = Math.atan2(to.y - from.y, to.x - from.x)

    ctx.beginPath()
    ctx.moveTo(from.x, from.y)
    ctx.lineTo(to.x, to.y)
    ctx.stroke()

    ctx.beginPath()
    ctx.moveTo(to.x, to.y)
    ctx.lineTo(
      to.x - headLen * Math.cos(angle - Math.PI / 6),
      to.y - headLen * Math.sin(angle - Math.PI / 6),
    )
    ctx.lineTo(
      to.x - headLen * Math.cos(angle + Math.PI / 6),
      to.y - headLen * Math.sin(angle + Math.PI / 6),
    )
    ctx.closePath()
    ctx.fill()

    ctx.restore()
  }

export const label = (
  text: string,
  x: number,
  y: number,
  style: Style = {},
): DrawFn =>
  (ctx) => {
    ctx.save()
    applyStyle(ctx, style)
    if (style.fill !== undefined) ctx.fillText(text, x, y)
    if (style.stroke !== undefined) ctx.strokeText(text, x, y)
    ctx.restore()
  }
